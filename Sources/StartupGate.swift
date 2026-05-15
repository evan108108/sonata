import Foundation
import SwiftUI
import AppKit
import GRDB

// MARK: - StartupGate
//
// Full-window loader that hard-gates the underlying UI until Sonata's
// backend services are ready (HTTP server, plugins, worker pool, supervisor).
// See Studio card `app-wide-startup-loader-hard-gate-ui-until-everything-is-a9fcb1ab`
// for the design rationale: views that load via `.task { await load() }`
// silently fail when their backend isn't ready, so a single launch-time
// gate eliminates the whole class of races.
//
// Bypass: Skip button OR Escape key. Both immediately expose the underlying UI.

enum CheckStatus: Equatable {
    case pending
    case running
    case ready
    case failed(String)

    var symbol: String {
        switch self {
        case .pending: return "○"
        case .running: return "◌"
        case .ready:   return "●"
        case .failed:  return "×"
        }
    }
}

struct ReadinessCheck: Identifiable, Equatable {
    let id: String
    var label: String
    var status: CheckStatus
    var detail: String?
}

@MainActor
final class StartupReadiness: ObservableObject {
    @Published var checks: [ReadinessCheck] = [
        ReadinessCheck(id: "http",       label: "HTTP server",  status: .pending),
        ReadinessCheck(id: "plugins",    label: "Plugins",      status: .pending),
        ReadinessCheck(id: "workers",    label: "Worker pool",  status: .pending),
        ReadinessCheck(id: "supervisor", label: "Supervisor",   status: .pending),
    ]

    private var started = false

    var ready: Bool { checks.allSatisfy { $0.status == .ready } }

    /// 0...1 — fraction of checks that are ready. Failed checks count as
    /// "done" so the bar doesn't stall when something errors out (the user
    /// still has to Skip past the red line to dismiss the gate).
    var progress: Double {
        guard !checks.isEmpty else { return 0 }
        let done = checks.filter {
            if case .ready = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        }.count
        return Double(done) / Double(checks.count)
    }

    func start(dbPool: DatabasePool, port: Int) {
        guard !started else { return }
        started = true

        Task { await self.runHTTP(port: port) }
        Task { await self.runPlugins(port: port) }
        Task { await self.runWorkers(dbPool: dbPool) }
        Task { await self.runSupervisor(dbPool: dbPool) }
    }

    private func update(_ id: String, _ status: CheckStatus, detail: String? = nil, label: String? = nil) {
        guard let idx = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[idx].status = status
        checks[idx].detail = detail
        if let label { checks[idx].label = label }
    }

    // MARK: HTTP server — hit /api/ping until 200 or hard timeout
    private func runHTTP(port: Int) async {
        update("http", .running)
        let deadline = Date().addingTimeInterval(15)
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/ping") else {
            update("http", .failed("bad url")); return
        }
        while Date() < deadline {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    update("http", .ready); return
                }
            } catch {
                // keep trying
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        update("http", .failed("did not respond in 15s"))
    }

    // MARK: Plugins — list, then per-enabled-plugin /health probe
    private func runPlugins(port: Int) async {
        update("plugins", .running)

        // Wait briefly for HTTP server to be up first.
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/api/plugins") else {
            update("plugins", .failed("bad url")); return
        }
        var plugins: [(name: String, status: String)] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: listURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    plugins = arr.compactMap { row in
                        guard let name = row["name"] as? String,
                              let status = row["status"] as? String else { return nil }
                        // Only gate on plugins the user has opted into.
                        let enabled = ["enabled", "starting", "running"].contains(status)
                        return enabled ? (name, status) : nil
                    }
                    break
                }
            } catch {
                // keep trying
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if plugins.isEmpty {
            update("plugins", .ready, detail: "none enabled"); return
        }

        update("plugins", .running, detail: "0/\(plugins.count)", label: "Plugins")

        // Probe each plugin's /health endpoint. Hard cap per plugin at 30s.
        let pluginDeadline = Date().addingTimeInterval(30)
        var ready = 0
        var failures: [String] = []
        for plugin in plugins {
            guard let healthURL = URL(string: "http://127.0.0.1:\(port)/api/plugins/\(plugin.name)/health") else {
                failures.append("\(plugin.name): bad url")
                continue
            }
            var ok = false
            while Date() < pluginDeadline {
                do {
                    let (_, response) = try await URLSession.shared.data(from: healthURL)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        ok = true; break
                    }
                } catch {
                    // keep trying
                }
                // Re-check status — if the DB flipped this plugin to 'failed',
                // stop polling and surface that.
                if let row = try? await fetchPluginStatus(name: plugin.name, port: port),
                   row == "failed" {
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            if ok {
                ready += 1
                update("plugins", .running, detail: "\(ready)/\(plugins.count)")
            } else {
                failures.append(plugin.name)
            }
        }

        if failures.isEmpty {
            update("plugins", .ready, detail: "\(plugins.count)/\(plugins.count)")
        } else {
            update("plugins", .failed("failed: \(failures.joined(separator: ", "))"), detail: "\(ready)/\(plugins.count)")
        }
    }

    private func fetchPluginStatus(name: String, port: Int) async throws -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/plugins") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr.first(where: { ($0["name"] as? String) == name })?["status"] as? String
    }

    // MARK: Workers — count fresh heartbeats vs defaultWorkerCount
    private func runWorkers(dbPool: DatabasePool) async {
        update("workers", .running)
        let target = WorkerManager.defaultWorkerCount
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 30_000
            let count: Int = (try? await dbPool.read { db in
                try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM workers WHERE lastHeartbeat >= ? AND status != 'offline'",
                    arguments: [cutoff]) ?? 0
            }) ?? 0
            if count >= target {
                update("workers", .ready, detail: "\(count)/\(target)")
                return
            }
            update("workers", .running, detail: "\(count)/\(target)")
            try? await Task.sleep(for: .milliseconds(400))
        }
        // Final read for the error message.
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 30_000
        let final: Int = (try? await dbPool.read { db in
            try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM workers WHERE lastHeartbeat >= ? AND status != 'offline'",
                arguments: [cutoff]) ?? 0
        }) ?? 0
        update("workers", .failed("only \(final)/\(target) workers heartbeating"))
    }

    // MARK: Supervisor — supervisorState row exists with fresh heartbeat
    private func runSupervisor(dbPool: DatabasePool) async {
        update("supervisor", .running)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 30_000
            let fresh: Bool = (try? await dbPool.read { db in
                try Bool.fetchOne(db, sql:
                    "SELECT COUNT(*) > 0 FROM supervisorState WHERE lastHeartbeat >= ?",
                    arguments: [cutoff]) ?? false
            }) ?? false
            if fresh {
                update("supervisor", .ready); return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        update("supervisor", .failed("no fresh heartbeat in 20s"))
    }
}

// MARK: - Gate view

struct StartupGate<Content: View>: View {
    let dbPool: DatabasePool
    let port: Int
    @ViewBuilder let content: () -> Content

    @StateObject private var readiness = StartupReadiness()
    @State private var skipped = false
    @State private var keyMonitor: Any?

    var body: some View {
        ZStack {
            content()
                .disabled(!readiness.ready && !skipped)
                .allowsHitTesting(readiness.ready || skipped)

            if !readiness.ready && !skipped {
                StartupGateOverlay(readiness: readiness, onSkip: dismiss)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: readiness.ready)
        .animation(.easeOut(duration: 0.25), value: skipped)
        .task {
            readiness.start(dbPool: dbPool, port: port)
        }
        .onAppear {
            // Capture Escape across the entire window. `.onKeyPress` would
            // require the overlay to be focused; a local key monitor is more
            // robust for a transient launch screen.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    if !readiness.ready && !skipped {
                        dismiss()
                        return nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private func dismiss() {
        skipped = true
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Overlay UI (placeholder visual; flame shader lands in commit #2)

private struct StartupGateOverlay: View {
    @ObservedObject var readiness: StartupReadiness
    let onSkip: () -> Void

    var body: some View {
        ZStack {
            // Warm background — vertical gradient from deep ember to candle-glow.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.08, green: 0.04, blue: 0.02), location: 0),
                    .init(color: Color(red: 0.14, green: 0.06, blue: 0.03), location: 0.55),
                    .init(color: Color(red: 0.22, green: 0.09, blue: 0.04), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                Text("Sonata")
                    .font(.system(size: 84, weight: .light, design: .serif))
                    .italic()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0,  green: 0.82, blue: 0.55),
                                Color(red: 1.0,  green: 0.55, blue: 0.20),
                                Color(red: 0.95, green: 0.35, blue: 0.10),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .shadow(color: Color(red: 1.0, green: 0.45, blue: 0.10).opacity(0.55), radius: 22, y: 6)
                    .shadow(color: Color(red: 1.0, green: 0.65, blue: 0.20).opacity(0.35), radius: 4)

                Text("Starting up…")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(red: 0.95, green: 0.78, blue: 0.55).opacity(0.75))

                // Warm horizon-line progress bar.
                EmberProgressBar(progress: readiness.progress)
                    .frame(width: 360, height: 4)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(readiness.checks) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(.top, 8)
                .frame(minWidth: 360, alignment: .leading)

                Spacer()

                Button(action: onSkip) {
                    Text("Skip  ⎋")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.45))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 48)
        }
    }
}

private struct CheckRow: View {
    let check: ReadinessCheck

    var body: some View {
        HStack(spacing: 10) {
            Text(check.status.symbol)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 12, alignment: .center)

            Text(check.label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)

            if let detail = check.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(color.opacity(0.6))
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: check.status)
    }

    private var color: Color {
        switch check.status {
        case .pending: return Color(red: 0.95, green: 0.78, blue: 0.55).opacity(0.35)
        case .running: return Color(red: 1.0,  green: 0.82, blue: 0.55)
        case .ready:   return Color(red: 1.0,  green: 0.55, blue: 0.20)
        case .failed:  return Color(red: 0.95, green: 0.30, blue: 0.20)
        }
    }
}

private struct EmberProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(Color(red: 0.18, green: 0.08, blue: 0.04))

                // Fill — warm horizon line.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.35, blue: 0.10),
                                Color(red: 1.0,  green: 0.65, blue: 0.20),
                                Color(red: 1.0,  green: 0.85, blue: 0.55),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(2, geo.size.width * progress))
                    .shadow(color: Color(red: 1.0, green: 0.55, blue: 0.20).opacity(0.7), radius: 6)
                    .animation(.easeOut(duration: 0.35), value: progress)
            }
        }
    }
}
