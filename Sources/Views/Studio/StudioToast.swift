import SwiftUI

/// Lightweight toast client used by the compose surfaces (W6) to surface
/// optimistic-insert rollbacks and image-upload failures. The default
/// implementation is an NSLog passthrough so previews and unit tests run
/// without a mounted renderer; a real top-of-app toast view can replace the
/// env-key value at the SonataApp root when one ships.
struct StudioToastClient: Sendable {
    enum Severity: String, Sendable { case info, warn, error }

    let send: @Sendable (Severity, String, TimeInterval) -> Void

    func show(severity: Severity, text: String, duration: TimeInterval = 5) {
        send(severity, text, duration)
    }
}

private struct StudioToastClientKey: EnvironmentKey {
    static let defaultValue = StudioToastClient { sev, msg, _ in
        NSLog("[Studio.toast] [\(sev.rawValue)] \(msg)")
    }
}

extension EnvironmentValues {
    var studioToast: StudioToastClient {
        get { self[StudioToastClientKey.self] }
        set { self[StudioToastClientKey.self] = newValue }
    }
}
