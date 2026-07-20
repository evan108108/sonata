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
            // 2026-07-17 (pain #6, Supervisor "workspace lease tokens", DM
            // 928af67c9d5c4d4bb7dd3e0485608f82): keyed on run_id previously —
            // but prstar's dispatcher creates a NEW run_id row for every
            // dispatch, so two events for the same PR+sha produced two
            // different keys and the ON CONFLICT dedup below was a no-op.
            // Supervisor cleanup for concurrent-dual-claim races (PR #446,
            // #427, #444 all recently) traces to exactly this: the underlying
            // artifact fingerprint (owner/repo#pr@sha for a given action)
            // never made it into the key. Re-key on that fingerprint so a
            // second dispatch for the same artifact silently drops. If a
            // legitimate re-dispatch is needed at the same sha AFTER the
            // first completes, prstar's own prstar_review_runs dedup
            // (idx_prstar_runs_dedup on repo_id+pr_number+head_sha+action)
            // already catches that upstream.
            guard let owner = payload["owner"] as? String, !owner.isEmpty,
                  let repo = payload["repo"] as? String, !repo.isEmpty,
                  let headSha = payload["headSha"] as? String, !headSha.isEmpty,
                  let action = payload["action"] as? String, !action.isEmpty
            else { return nil }
            // prNumber arrives as Int most of the time but a JSON re-parse
            // through some plugin surfaces coerces it to String; accept either.
            let prNumberStr: String
            if let n = payload["prNumber"] as? Int { prNumberStr = String(n) }
            else if let s = payload["prNumber"] as? String, !s.isEmpty { prNumberStr = s }
            else { return nil }
            return "pr_review:\(owner)/\(repo)#\(prNumberStr)@\(headSha)@\(action)"
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
