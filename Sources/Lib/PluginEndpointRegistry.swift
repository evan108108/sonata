import Foundation
import os

/// Where each running plugin can be reached, by plugin name.
///
/// A dynamic-port plugin (manifest `port_policy: "dynamic"`) binds whichever
/// port in its range is free, so callers can't assume the manifest port.
/// PluginManager publishes the bound base URL once the plugin is healthy and
/// removes it on disable. A crash keeps the last-known URL: the restart
/// usually lands on the same (sticky) port, and a stale answer is no worse
/// than the hardcoded one it replaces.
enum PluginEndpointRegistry {
    private static let endpoints = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// e.g. "http://127.0.0.1:4001", or nil if the plugin hasn't come up.
    static func baseURL(_ name: String) -> String? {
        endpoints.withLock { $0[name] }
    }

    static func publish(_ name: String, baseURL: String) {
        endpoints.withLock { $0[name] = baseURL }
    }

    static func remove(_ name: String) {
        _ = endpoints.withLock { $0.removeValue(forKey: name) }
    }
}
