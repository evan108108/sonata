import SwiftUI
import Foundation

struct SupervisorConfig: Equatable {
    var dayIntervalSec: Int
    var nightIntervalSec: Int
    var nightStartHour: Int
    var nightEndHour: Int
    var enabled: Bool
    var currentMode: String     // "day" | "night" | "disabled"
    var currentIntervalSec: Int
    var updatedAt: Date
}

@MainActor
class SupervisorConfigViewModel: ObservableObject {
    @Published var config: SupervisorConfig?
    @Published var error: String?
    @Published var isLoading = false
    @Published var isSaving = false

    private var baseURL: String { "http://127.0.0.1:\(sonataPort)" }

    func fetch() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let url = URL(string: "\(baseURL)/api/supervisor/config") else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(ConfigJSON.self, from: data)
            config = SupervisorConfig(
                dayIntervalSec: decoded.dayIntervalSec,
                nightIntervalSec: decoded.nightIntervalSec,
                nightStartHour: decoded.nightStartHour,
                nightEndHour: decoded.nightEndHour,
                enabled: decoded.enabled,
                currentMode: decoded.currentMode,
                currentIntervalSec: decoded.currentIntervalSec,
                updatedAt: Date(timeIntervalSince1970: Double(decoded.updatedAt) / 1000)
            )
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save(
        dayIntervalSec: Int,
        nightIntervalSec: Int,
        nightStartHour: Int,
        nightEndHour: Int,
        enabled: Bool
    ) async -> Bool {
        isSaving = true
        defer { isSaving = false }

        let body: [String: Any] = [
            "dayIntervalSec": dayIntervalSec,
            "nightIntervalSec": nightIntervalSec,
            "nightStartHour": nightStartHour,
            "nightEndHour": nightEndHour,
            "enabled": enabled,
        ]

        guard let url = URL(string: "\(baseURL)/api/supervisor/config") else {
            error = "Invalid URL"
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status < 300 {
                if let decoded = try? JSONDecoder().decode(ConfigJSON.self, from: data) {
                    config = SupervisorConfig(
                        dayIntervalSec: decoded.dayIntervalSec,
                        nightIntervalSec: decoded.nightIntervalSec,
                        nightStartHour: decoded.nightStartHour,
                        nightEndHour: decoded.nightEndHour,
                        enabled: decoded.enabled,
                        currentMode: decoded.currentMode,
                        currentIntervalSec: decoded.currentIntervalSec,
                        updatedAt: Date(timeIntervalSince1970: Double(decoded.updatedAt) / 1000)
                    )
                }
                error = nil
                return true
            }
            error = "Save failed: HTTP \(status)"
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

private struct ConfigJSON: Decodable {
    let dayIntervalSec: Int
    let nightIntervalSec: Int
    let nightStartHour: Int
    let nightEndHour: Int
    let enabled: Bool
    let updatedAt: Int64
    let currentMode: String
    let currentIntervalSec: Int
}
