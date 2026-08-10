import SwiftUI
import Combine

// Wire shape the view speaks in. Mirrors WatcherResponse from
// WatcherActions.swift (transport-only; the swift-server type stays
// authoritative and this is the client-side decode).
struct Watcher: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let pattern: String
    let recursive: Bool
    let trigger: String
    let prompt: String
    let enabled: Bool
    let cooldownMs: Int64
    let retryCount: Int
    let sizeThreshold: Int64?
    let lastError: String?
    let consecutiveFailures: Int
    let lastFiredAt: Int64?
    let createdAt: Int64
    let updatedAt: Int64
}

struct WatcherEvent: Codable, Identifiable, Equatable {
    let id: String
    let watcherId: String
    let path: String
    let eventType: String
    let firedAt: Int64
    let taskId: String?
    let status: String
    let error: String?
}

struct WatcherTestResult: Codable {
    let ok: Bool
    let taskId: String?
    let status: String
    let error: String?
}

/// Draft used by the add/edit sheet. Nullable id — nil means "new".
struct WatcherDraft {
    var id: String
    var name: String
    var path: String
    var pattern: String
    var recursive: Bool
    var trigger: String
    var prompt: String
    var enabled: Bool
    var cooldownMs: Int64
    var retryCount: Int

    static let empty = WatcherDraft(
        id: "", name: "", path: "", pattern: "*",
        recursive: false, trigger: "file_added",
        prompt: "", enabled: true, cooldownMs: 5000, retryCount: 2
    )
}

@MainActor
final class WatchersViewModel: ObservableObject {
    @Published var watchers: [Watcher] = []
    @Published var selection: String?
    @Published var events: [WatcherEvent] = []
    @Published var lastError: String?
    @Published var isLoading = false
    @Published var lastTestResult: WatcherTestResult?

    private var eventsPollTimer: AnyCancellable?

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/watcher/list")!
            let (data, _) = try await URLSession.shared.data(from: url)
            self.watchers = try JSONDecoder().decode([Watcher].self, from: data)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.lastError = nil
            // Preserve selection if it still exists, else pick the first.
            if let sel = selection, watchers.contains(where: { $0.id == sel }) {
                // still valid
            } else {
                selection = watchers.first?.id
            }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func fetchEvents(watcherId: String) async {
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/watcher/events?id=\(watcherId)&limit=100")!
            let (data, _) = try await URLSession.shared.data(from: url)
            self.events = try JSONDecoder().decode([WatcherEvent].self, from: data)
        } catch {
            self.events = []
        }
    }

    func startEventPolling(watcherId: String) {
        stopEventPolling()
        eventsPollTimer = Timer.publish(every: 4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.fetchEvents(watcherId: watcherId) }
            }
    }

    func stopEventPolling() {
        eventsPollTimer?.cancel()
        eventsPollTimer = nil
    }

    func upsert(_ draft: WatcherDraft) async -> Bool {
        var body: [String: Any] = [
            "name": draft.name,
            "path": draft.path,
            "pattern": draft.pattern.isEmpty ? "*" : draft.pattern,
            "recursive": draft.recursive,
            "trigger": draft.trigger,
            "prompt": draft.prompt,
            "enabled": draft.enabled,
            "cooldownMs": Int(draft.cooldownMs),
            "retryCount": draft.retryCount,
        ]
        if !draft.id.isEmpty {
            body["id"] = draft.id
        }
        let ok = await postJSON(path: "/api/watcher/create", body: body)
        if ok {
            await fetch()
        }
        return ok
    }

    func setEnabled(id: String, enabled: Bool) async {
        _ = await postJSON(path: "/api/watcher/\(enabled ? "enable" : "disable")", body: ["id": id])
        await fetch()
    }

    func delete(id: String) async {
        let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/watcher/delete?id=\(id)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: request)
        if selection == id { selection = nil }
        await fetch()
    }

    func testFire(id: String, path: String) async {
        lastTestResult = nil
        do {
            let url = URL(string: "http://127.0.0.1:\(sonataPort)/api/watcher/test")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "path": path])
            let (data, _) = try await URLSession.shared.data(for: request)
            self.lastTestResult = try? JSONDecoder().decode(WatcherTestResult.self, from: data)
            await fetchEvents(watcherId: id)
        } catch {
            self.lastTestResult = WatcherTestResult(
                ok: false, taskId: nil, status: "errored", error: error.localizedDescription
            )
        }
    }

    // MARK: - Templates

    struct Template: Identifiable {
        let id: String
        let name: String
        let icon: String
        let description: String
        let draft: WatcherDraft
    }

    static let templates: [Template] = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            Template(
                id: "meeting-logger",
                name: "Meeting transcript logger",
                icon: "text.bubble",
                description: "New .md files in ~/Documents/meetings run /meeting.",
                draft: WatcherDraft(
                    id: "meeting-logger",
                    name: "Meeting transcript logger",
                    path: "\(home)/Documents/meetings",
                    pattern: "*.md",
                    recursive: false,
                    trigger: "file_added",
                    prompt: "/meeting",
                    enabled: true,
                    cooldownMs: 5000,
                    retryCount: 2
                )
            ),
            Template(
                id: "screenshot-ocr",
                name: "Screenshot OCR",
                icon: "camera.viewfinder",
                description: "New Screenshot*.png on ~/Desktop → OCR + memory-store the extracted text.",
                draft: WatcherDraft(
                    id: "screenshot-ocr",
                    name: "Screenshot OCR",
                    path: "\(home)/Desktop",
                    pattern: "Screenshot*.png",
                    recursive: false,
                    trigger: "file_added",
                    prompt: "OCR the image at {{path}} and store the extracted text as a memory tagged 'screenshot' with the file path as source.",
                    enabled: true,
                    cooldownMs: 5000,
                    retryCount: 2
                )
            ),
            Template(
                id: "downloads-categorizer",
                name: "Downloads categorizer",
                icon: "arrow.down.doc",
                description: "New files in ~/Downloads get an LLM-suggested destination folder.",
                draft: WatcherDraft(
                    id: "downloads-categorizer",
                    name: "Downloads categorizer",
                    path: "\(home)/Downloads",
                    pattern: "*",
                    recursive: false,
                    trigger: "file_added",
                    prompt: "Look at the file at {{path}} and suggest where it should be filed. Move it if the suggestion is unambiguous.",
                    enabled: true,
                    cooldownMs: 8000,
                    retryCount: 1
                )
            ),
            Template(
                id: "inbox-to-tasks",
                name: "Inbox.txt to tasks",
                icon: "tray.and.arrow.down",
                description: "Appending to ~/inbox.txt creates a Sona task from the new line.",
                draft: WatcherDraft(
                    id: "inbox-to-tasks",
                    name: "Inbox.txt to tasks",
                    path: "\(home)/inbox.txt",
                    pattern: "inbox.txt",
                    recursive: false,
                    trigger: "file_modified",
                    prompt: "Read the last line of {{path}} and create a Sona task from it.",
                    enabled: true,
                    cooldownMs: 3000,
                    retryCount: 2
                )
            ),
        ]
    }()

    func installTemplate(_ tpl: Template) async -> Bool {
        return await upsert(tpl.draft)
    }

    // MARK: - HTTP helpers

    private func postJSON(path: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(sonataPort)\(path)") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                self.lastError = String(data: data, encoding: .utf8)
                return false
            }
            return true
        } catch {
            self.lastError = error.localizedDescription
            return false
        }
    }
}
