// Derives a stable UNIQUE key from an enqueue call's (type, payload) so a
// second attempt to insert the same logical work item collides on the
// partial UNIQUE index (idx_workerEvents_idempotencyKey) and gets skipped
// via ON CONFLICT DO NOTHING.
//
// Producers that don't have a natural id (alerts, smoke tests, ad-hoc
// enqueues) return nil — those inserts remain unguarded, which matches
// pre-v28 behavior. The partial index is "WHERE idempotencyKey IS NOT
// NULL" so a NULL key never collides.
//
// Day-bucket on `task` events: a nightly recurring task legitimately fires
// once per day with the same task_id. Bucketing to yyyy-mm-dd lets the
// same taskId enqueue once per calendar day but blocks the same-second
// double-fire that motivated this (see memory e0bbeae1, p48 incident,
// failure_mode 52a4503c).
//
// Producers that fire the same task_id more than once per day intentionally
// (multi-cycle workflows) must include an explicit `dispatch_cycle` field
// in the payload; extend the switch below when the first such producer
// appears — plan doc §"What this doesn't fix".

import Foundation

enum WorkerEventIdempotency {

    /// Derive the idempotency key for a workerEvent insert. `payload` is
    /// the parsed JSON payload dictionary. Returns nil when no stable
    /// identity is derivable — callers should insert without a key in
    /// that case.
    static func key(type: String, payload: [String: Any], now: Date = Date()) -> String? {
        switch type {
        case "task":
            guard let taskId = payload["task_id"] as? String, !taskId.isEmpty else { return nil }
            if let cycle = payload["dispatch_cycle"] as? String, !cycle.isEmpty {
                return "task:\(taskId):\(cycle)"
            }
            return "task:\(taskId):\(dayBucket(now))"
        case "email":
            let emailId = (payload["email_id"] as? String)
                ?? (payload["message_id"] as? String)
            guard let id = emailId, !id.isEmpty else { return nil }
            return "email:\(id)"
        case "sonar_dm":
            guard let id = payload["message_id"] as? String, !id.isEmpty else { return nil }
            return "sonar_dm:\(id)"
        case "pr_review":
            guard let runId = payload["run_id"] as? String, !runId.isEmpty else { return nil }
            return "pr_review:\(runId)"
        default:
            return nil
        }
    }

    /// Convenience overload: parse a JSON string payload and derive the key.
    static func key(type: String, payloadJSON: String, now: Date = Date()) -> String? {
        guard let data = payloadJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return key(type: type, payload: dict, now: now)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayBucket(_ date: Date) -> String {
        return dayFormatter.string(from: date)
    }
}
