import Foundation

/// Reads and writes secrets via Settings (UserDefaults), with process environment fallback.
/// This bridges the Settings UI (which stores imported .env keys in UserDefaults)
/// with the server routes that need API keys at runtime.
enum SecretStore {
    struct Entry: Codable {
        let name: String
        let value: String
        let description: String
    }

    private static let key = "sonata.secrets"

    private static func loadEntries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }

    private static func saveEntries(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func get(_ name: String) -> String? {
        if let entry = loadEntries().first(where: { $0.name == name }), !entry.value.isEmpty {
            return entry.value
        }
        return ProcessInfo.processInfo.environment[name]
    }

    static func set(name: String, value: String, description: String = "") {
        var entries = loadEntries()
        if let idx = entries.firstIndex(where: { $0.name == name }) {
            entries[idx] = Entry(name: name, value: value, description: description.isEmpty ? entries[idx].description : description)
        } else {
            entries.append(Entry(name: name, value: value, description: description))
        }
        saveEntries(entries)
    }

    static func delete(_ name: String) -> Bool {
        var entries = loadEntries()
        let before = entries.count
        entries.removeAll { $0.name == name }
        if entries.count < before {
            saveEntries(entries)
            return true
        }
        return false
    }

    static func list() -> [(name: String, description: String)] {
        return loadEntries().map { ($0.name, $0.description) }
    }
}
