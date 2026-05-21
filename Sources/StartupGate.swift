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

    /// The gate is "ready" — i.e. dismisses automatically — as soon as every
    /// check has reached a terminal state, whether successful or not. Failed
    /// checks no longer block dismissal: the user shouldn't have to click Skip
    /// past a stuck-plugin row to get into the app. Failures still render
    /// red on the overlay (briefly visible during the dismiss animation),
    /// and the affected nav-rail item gets its own attention badge once the
    /// app is up — see NavRailCounts.failedPluginCount.
    var ready: Bool {
        checks.allSatisfy { check in
            if case .ready = check.status { return true }
            if case .failed = check.status { return true }
            return false
        }
    }

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

    // MARK: Plugins — poll /api/plugins until every enabled plugin is running,
    // then probe one real action per plugin until the response stabilizes.
    //
    // Earlier version probed /api/plugins/<name>/health which doesn't exist
    // (proxy only forwards declared-action paths). The plugin's status column
    // is the source of truth for HTTP-up; per-plugin warmup probes catch the
    // cold-start data window where the HTTP layer responds but action data is
    // racing.
    private func runPlugins(port: Int) async {
        update("plugins", .running)

        guard let listURL = URL(string: "http://127.0.0.1:\(port)/api/plugins") else {
            update("plugins", .failed("bad url")); return
        }

        let deadline = Date().addingTimeInterval(30)
        var lastSnapshot: [(name: String, status: String)] = []

        // Per-plugin clock for how long each has sat in 'starting'. A plugin
        // still 'starting' past this grace window is treated as wedged and
        // gets a one-shot disable→enable recovery — the same fix the failed-
        // path and the manual Plugins-tab toggle use. The grace exceeds
        // PluginManager's 15s health timeout, so a plugin that's merely booting
        // slowly (and will flip to running/failed on its own) is never
        // interrupted. Without this, a wedged 'starting' plugin falls through
        // both the failed-recovery and all-running branches and the loader
        // just spins to its 30s timeout — exactly the reported bug.
        let stuckStartingGrace: TimeInterval = 18
        var firstSeenStarting: [String: Date] = [:]
        var recoveredStarting: Set<String> = []

        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(from: listURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    let snapshot: [(name: String, status: String)] = arr.compactMap { row in
                        guard let name = row["name"] as? String,
                              let status = row["status"] as? String else { return nil }
                        return (name, status)
                    }
                    let gated = snapshot.filter { row in
                        ["enabled", "starting", "running", "failed"].contains(row.status)
                    }
                    if gated.isEmpty {
                        update("plugins", .ready, detail: "none enabled"); return
                    }
                    let runningCount = gated.filter { $0.status == "running" }.count
                    let failedNames = gated.filter { $0.status == "failed" }.map(\.name)
                    if !failedNames.isEmpty {
                        // First-pass recovery: try a disable→enable cycle on
                        // each failed plugin. This mirrors the manual fix
                        // (toggling Disable/Enable in the Plugins tab always
                        // recovers it) without making the user wait. If the
                        // cycle succeeds we re-poll the loop; if it doesn't,
                        // we mark the check failed but the gate still
                        // dismisses thanks to the relaxed `ready` rule.
                        let stillFailed = await recoverStuckPlugins(failedNames, port: port)
                        if stillFailed.isEmpty {
                            // All recovered — fall through to the running-
                            // count check on the next loop iteration.
                            update("plugins", .running,
                                   detail: "recovered \(failedNames.count)")
                            try? await Task.sleep(for: .milliseconds(400))
                            continue
                        }
                        update("plugins",
                               .failed("failed: \(stillFailed.joined(separator: ", "))"),
                               detail: "\(runningCount)/\(gated.count)")
                        return
                    }
                    if runningCount == gated.count {
                        update("plugins", .running, detail: "warming up…")
                        let warmFailures = await warmupPlugins(gated.map(\.name), port: port)
                        if warmFailures.isEmpty {
                            update("plugins", .ready, detail: nil)
                        } else {
                            update("plugins",
                                   .failed("warmup timeout: \(warmFailures.joined(separator: ", "))"),
                                   detail: nil)
                        }
                        return
                    }
                    // Not all running and none failed — the laggards are
                    // 'enabled' or 'starting'. Recover any that have been wedged
                    // in 'starting' past the grace window (one shot each), then
                    // re-poll so the recovered plugin can reach 'running'.
                    let startingNames = gated.filter { $0.status == "starting" }.map(\.name)
                    let stuckStarting = stuckStartingToRecover(
                        startingNames: startingNames,
                        firstSeenStarting: &firstSeenStarting,
                        recoveredStarting: recoveredStarting,
                        now: Date(),
                        grace: stuckStartingGrace
                    )
                    if !stuckStarting.isEmpty {
                        stuckStarting.forEach { recoveredStarting.insert($0) }
                        let stillStuck = await recoverStuckPlugins(stuckStarting, port: port)
                        update("plugins", .running,
                               detail: stillStuck.isEmpty
                                   ? "recovered \(stuckStarting.count)"
                                   : "\(runningCount)/\(gated.count)")
                        try? await Task.sleep(for: .milliseconds(400))
                        continue
                    }
                    update("plugins", .running, detail: "\(runningCount)/\(gated.count)")
                    lastSnapshot = gated
                }
            } catch {
                // keep trying
            }
            try? await Task.sleep(for: .milliseconds(400))
        }

        let runningCount = lastSnapshot.filter { $0.status == "running" }.count
        let stuckNames = lastSnapshot.filter { $0.status != "running" }.map(\.name)
        update("plugins",
               .failed("timeout — stuck: \(stuckNames.joined(separator: ", "))"),
               detail: "\(runningCount)/\(lastSnapshot.count)")
    }

    /// Attempt to recover wedged plugins — either status='failed' or stuck in
    /// status='starting' past the grace window — by hitting the disable +
    /// enable endpoints, then waiting briefly for the status to transition to
    /// 'running'. Returns the names that did NOT reach 'running' after the
    /// attempt. Each plugin gets a single shot; the recovery doesn't loop.
    private func recoverStuckPlugins(_ names: [String], port: Int) async -> [String] {
        var stillFailed: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in names {
                group.addTask {
                    let ok = await Self.toggleDisableEnable(name: name, port: port)
                    return (name, ok)
                }
            }
            for await (name, recovered) in group where !recovered {
                stillFailed.append(name)
            }
        }
        return stillFailed
    }

    private static func toggleDisableEnable(name: String, port: Int) async -> Bool {
        guard let disableURL = URL(string: "http://127.0.0.1:\(port)/api/plugins/\(name)/disable"),
              let enableURL  = URL(string: "http://127.0.0.1:\(port)/api/plugins/\(name)/enable") else {
            return false
        }
        var disableReq = URLRequest(url: disableURL); disableReq.httpMethod = "POST"
        var enableReq  = URLRequest(url: enableURL);  enableReq.httpMethod  = "POST"
        do {
            _ = try await URLSession.shared.data(for: disableReq)
            // Brief pause so the plugin's PID / port cleanup completes before
            // we re-enable. Without it some plugins try to bind their port
            // before the previous process has finished releasing it.
            try? await Task.sleep(for: .milliseconds(400))
            _ = try await URLSession.shared.data(for: enableReq)
        } catch {
            return false
        }
        // Poll the plugin's status row up to 8 seconds for it to return to
        // 'running'. 8s matches the typical sonar Elixir/Erlang boot time
        // plus a small buffer.
        guard let listURL = URL(string: "http://127.0.0.1:\(port)/api/plugins") else {
            return false
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let (data, _) = try? await URLSession.shared.data(from: listURL),
               let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
               let row = arr.first(where: { ($0["name"] as? String) == name }),
               (row["status"] as? String) == "running" {
                return true
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    /// Per-plugin warmup probe — call one real action endpoint and wait until
    /// two consecutive identical 200 responses arrive (~800ms apart). Catches
    /// the cold-start data race where the HTTP layer is up but the plugin's
    /// data path returns null/empty for the first few calls.
    private func warmupPlugins(_ names: [String], port: Int) async -> [String] {
        struct Probe { let method: String; let path: String }
        let probes: [String: Probe] = [
            "sonata-studio": Probe(method: "GET", path: "/storage/default/get"),
            "sonar":         Probe(method: "GET", path: "/identity"),
            "prstar":        Probe(method: "GET", path: "/status"),
        ]
        let perPluginDeadline: TimeInterval = 15
        var failures: [String] = []
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in names {
                guard let probe = probes[name] else { continue }
                let method = probe.method
                let path = probe.path
                group.addTask {
                    let ok = await Self.probePluginUntilStable(
                        name: name, method: method, path: path, port: port,
                        deadline: Date().addingTimeInterval(perPluginDeadline)
                    )
                    return (name, ok)
                }
            }
            for await (name, ok) in group where !ok {
                failures.append(name)
            }
        }
        return failures
    }

    private static func probePluginUntilStable(
        name: String,
        method: String,
        path: String,
        port: Int,
        deadline: Date
    ) async -> Bool {
        let urlString = "http://127.0.0.1:\(port)/api/plugins/\(name)\(path)"
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 5
        var lastBody: Data? = nil
        while Date() < deadline {
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    if let prior = lastBody, prior == data { return true }
                    lastBody = data
                }
            } catch {
                lastBody = nil
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        return false
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
                // detail intentionally nil — "4/2" reads backwards
                update("workers", .ready, detail: nil)
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

// MARK: - Stuck-'starting' detection (pure, testable)

/// Decide which plugins currently in `starting` have been wedged past the
/// grace window and should be toggled this tick. Pure decision logic, factored
/// out of `runPlugins` so it can be unit-tested without standing up HTTP:
///
/// - records a first-seen timestamp for any newly-`starting` plugin (mutates
///   `firstSeenStarting` in place);
/// - returns names that have been `starting` for at least `grace` seconds and
///   have not already been recovered this run (the once-only guard).
func stuckStartingToRecover(
    startingNames: [String],
    firstSeenStarting: inout [String: Date],
    recoveredStarting: Set<String>,
    now: Date,
    grace: TimeInterval
) -> [String] {
    for name in startingNames where firstSeenStarting[name] == nil {
        firstSeenStarting[name] = now
    }
    return startingNames.filter { name in
        guard !recoveredStarting.contains(name),
              let since = firstSeenStarting[name] else { return false }
        return now.timeIntervalSince(since) >= grace
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

    // Flip to true once MetalFlameView.preflight() reports a successful
    // shader compile. We hide the Canvas fallback for the first second so
    // the common case (fast Metal compile, ~100-300ms) shows black → flame
    // directly with no intermediate Canvas flash. If Metal takes longer
    // than `canvasGracePeriod`, the Canvas blobs come up so the user sees
    // *something* warm rather than a mysterious black screen. Whenever
    // Metal arrives — before or after the grace period — it takes over.
    @State private var metalReady = false
    @State private var canvasFallbackVisible = false
    private let canvasGracePeriod: Duration = .seconds(1)

    var body: some View {
        ZStack {
            // Warm background — vertical gradient from deep ember to candle-glow.
            LinearGradient(
                stops: [
                    .init(color: Theme.Color.bgEmberDeep, location: 0),
                    .init(color: Theme.Color.bgEmberMid,  location: 0.55),
                    .init(color: Theme.Color.bgEmberTop,  location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Full-window flame layer. Metal version paints the entire
            // window; Canvas version is the local-blob fallback that lives
            // Three-stage visual:
            //   1. Black-only (just the gradient above) — first ~1s while
            //      Metal compiles. The common-case shader compile lands
            //      inside this window so the user goes black → real flame.
            //   2. Canvas fallback — kicks in only if Metal isn't ready
            //      after `canvasGracePeriod`. So the user never stares at
            //      a featureless screen for long.
            //   3. Metal flame — replaces whichever of the above is
            //      showing as soon as the shader is compiled.
            if metalReady {
                MetalFlameView()
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(spacing: 28) {
                Spacer()

                // Wordmark — gets the Canvas fallback flame behind it only
                // after the grace period (and only if Metal still isn't
                // ready). Otherwise the wordmark sits on plain dark, then
                // the Metal layer takes over the whole background.
                ZStack {
                    if !metalReady && canvasFallbackVisible {
                        FlameAura()
                            .frame(width: 460, height: 200)
                            .transition(.opacity)
                    }

                    FlickeringWordmark(text: "Sonata")
                }

                Text("Starting up…")
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.Color.textOnEmber.opacity(0.75))

                // Warm horizon-line progress bar.
                EmberProgressBar(progress: readiness.progress)
                    .frame(width: 360, height: 4)

                // Skip button — sits in the calm-zone vignette right under
                // the progress bar so it stays legible against the flames.
                Button(action: onSkip) {
                    Text("Skip  ⎋")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.45))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.Color.accentEmber.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(readiness.checks) { check in
                        CheckRow(check: check)
                    }
                }
                .padding(.top, 8)
                .frame(minWidth: 360, alignment: .leading)

                Spacer()

            }
            .padding(.horizontal, 48)
        }
        .task {
            // Compile the Metal shader off the main thread. If it succeeds
            // we promote to the Metal layer; if it fails we stay on the
            // Canvas fallback (graceful degradation — never surfaced).
            let ok = await MetalFlameView.preflight()
            if ok {
                withAnimation(.easeIn(duration: 0.4)) { metalReady = true }
            }
        }
        .task {
            // Canvas fallback grace period — keep the screen black for the
            // first second so the common case (fast Metal compile) goes
            // black → flame directly with no Canvas flash. After 1 s, if
            // Metal still hasn't arrived, the Canvas blobs come up so the
            // user isn't staring at a void.
            try? await Task.sleep(for: canvasGracePeriod)
            if !metalReady {
                withAnimation(.easeIn(duration: 0.3)) { canvasFallbackVisible = true }
            }
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
        case .pending: return Theme.Color.statusPending.opacity(0.35)
        case .running: return Theme.Color.statusRunning
        case .ready:   return Theme.Color.statusReady
        case .failed:  return Theme.Color.statusFailed
        }
    }
}

// MARK: - Flame visual
//
// SwiftUI-native (no Metal) flicker. A TimelineView drives a Canvas that
// composites several radial gradient blobs with additive blending to fake a
// candle/ember glow, plus a handful of rising spark particles. The wordmark
// sits in front with its own time-driven shadow pulse.
//
// Cheap: ~12 draws per frame at 30 fps. No textures, no shaders.

private struct FlameAura: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate

            Canvas { gctx, size in
                let w = size.width
                let h = size.height

                // Background warm wash so the dark page picks up a glow even
                // before the blobs paint. Subtle — most of the warmth comes
                // from the blobs below.
                gctx.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.18), location: 0.0),
                            .init(color: Color(red: 0.95, green: 0.30, blue: 0.10).opacity(0.0), location: 1.0),
                        ]),
                        center: CGPoint(x: w / 2, y: h * 0.62),
                        startRadius: 0,
                        endRadius: max(w, h) * 0.7
                    )
                )

                // Flame blobs — 7 of them, parameterized so each has its own
                // phase, frequency, and color stop. Layered with `.plusLighter`
                // so overlap brightens rather than darkens.
                gctx.blendMode = .plusLighter

                let blobs: [(phaseX: Double, phaseY: Double, freqX: Double, freqY: Double, ampX: Double, ampY: Double, baseY: Double, baseX: Double, radius: Double, color: Color)] = [
                    (0.0,  1.3, 0.42, 0.71, 0.06,  0.04, 0.55, 0.50, 110, Color(red: 1.0,  green: 0.50, blue: 0.15)),
                    (2.1,  0.4, 0.55, 0.93, 0.08,  0.05, 0.58, 0.30, 80,  Color(red: 1.0,  green: 0.70, blue: 0.25)),
                    (3.7,  2.2, 0.39, 0.85, 0.07,  0.05, 0.58, 0.70, 80,  Color(red: 1.0,  green: 0.65, blue: 0.20)),
                    (5.0,  3.5, 0.61, 1.10, 0.04,  0.06, 0.45, 0.40, 60,  Color(red: 1.0,  green: 0.85, blue: 0.40)),
                    (1.5,  4.1, 0.73, 0.65, 0.05,  0.06, 0.42, 0.62, 60,  Color(red: 1.0,  green: 0.80, blue: 0.35)),
                    (6.2,  2.8, 0.31, 1.22, 0.09,  0.03, 0.65, 0.18, 70,  Color(red: 0.95, green: 0.40, blue: 0.12)),
                    (4.6,  5.7, 0.28, 1.05, 0.10,  0.04, 0.65, 0.82, 70,  Color(red: 0.95, green: 0.40, blue: 0.12)),
                ]

                for blob in blobs {
                    let dx = sin(t * blob.freqX + blob.phaseX) * blob.ampX
                    let dy = cos(t * blob.freqY + blob.phaseY) * blob.ampY
                    let cx = (blob.baseX + dx) * w
                    let cy = (blob.baseY + dy) * h
                    let breathing = 0.85 + 0.15 * sin(t * 1.6 + blob.phaseX * 1.7)

                    gctx.fill(
                        Path(ellipseIn: CGRect(
                            x: cx - blob.radius * breathing,
                            y: cy - blob.radius * breathing,
                            width: blob.radius * 2 * breathing,
                            height: blob.radius * 2 * breathing
                        )),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: blob.color.opacity(0.55), location: 0.0),
                                .init(color: blob.color.opacity(0.0),  location: 1.0),
                            ]),
                            center: CGPoint(x: cx, y: cy),
                            startRadius: 0,
                            endRadius: blob.radius * breathing
                        )
                    )
                }

                // Rising sparks — 9 of them, each looping vertically over its
                // own period. Position is deterministic from `t` so the same
                // moment always looks the same (good for screenshots).
                for i in 0..<9 {
                    let period: Double = 3.0 + Double(i % 4) * 0.6
                    let phase: Double = Double(i) * 0.42
                    let progress = ((t + phase).truncatingRemainder(dividingBy: period)) / period
                    let xJitter = sin(t * 1.7 + Double(i) * 2.0) * 0.04
                    let x = (0.12 + Double(i) * 0.094 + xJitter) * w
                    // Sparks start near the bottom of the aura and rise.
                    let y = (0.85 - progress * 0.75) * h
                    let alpha = (1.0 - progress) * (0.4 + 0.6 * sin(progress * .pi))
                    let r = 1.5 + sin(t * 4.0 + Double(i)) * 0.6
                    gctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(Color(red: 1.0, green: 0.78, blue: 0.40).opacity(alpha))
                    )
                }
            }
            .blur(radius: 6) // softens the blob edges into "glow"
            .blendMode(.plusLighter)
        }
    }
}

private struct FlickeringWordmark: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // Two summed sines at incommensurate frequencies produce a
            // non-repeating flicker — feels candle-like rather than periodic.
            let flicker = 0.5 * (sin(t * 4.1) + sin(t * 7.3 + 1.0))
            let glow = 14 + 10 * flicker         // 4...24
            let yOffset = 1.0 + 0.6 * sin(t * 2.0)

            Text(text)
                .font(.system(size: 84, weight: .light, design: .serif))
                .italic()
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Theme.Color.accentCream,
                            Theme.Color.accentOrange,
                            Theme.Color.accentRust,
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                // Shadow tints stay literal — they're flicker-shader internals,
                // mid-stops between accentRust and accentOrange that aren't
                // themselves part of the broader palette.
                .shadow(color: Color(red: 1.0, green: 0.50, blue: 0.15).opacity(0.6), radius: glow, y: yOffset)
                .shadow(color: Color(red: 1.0, green: 0.70, blue: 0.25).opacity(0.4), radius: 3)
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
                    .shadow(color: Theme.Color.accentEmber.opacity(0.7), radius: 6)
                    .animation(.easeOut(duration: 0.35), value: progress)
            }
        }
    }
}
