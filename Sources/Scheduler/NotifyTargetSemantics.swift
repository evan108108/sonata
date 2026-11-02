import Foundation

/// What `notifyTarget` (v43) actually does, said where callers will see it.
///
/// A notifyTarget does not alert on failure. When it resolves to a live
/// target at fire time, the scheduler DMs the row's text (the shell command,
/// or the calendar prompt) to that target and does NOT run it. The row runs
/// only when the target is not live. Several rows have been written as if
/// notifyTarget were an alert (2026-10-30: the Scout pull job; 2026-11-02:
/// 19 scout-cloud shell rows that were being DMed instead of run). So the
/// create/update actions return a warning, and the fire-time result says
/// the command was not executed. Neither rejects anything: the supervisor
/// text-nudge rows depend on exactly this behaviour.
enum NotifyTargetSemantics {

    /// What a notify row would have done if it had not been DMed.
    enum Replaced {
        /// A shell command (scheduledJobs, or a calendar event with taskType "shell").
        case shellCommand
        /// A Claude worker prompt (calendar event with taskType "spawn-claude").
        case workerPrompt
    }

    /// The `warnings` entry for a scheduled job row. nil when notifyTarget is
    /// unset or empty (the fire path treats "" as unset too).
    static func scheduledJobWarning(notifyTarget: String?) -> String? {
        guard let target = notifyTarget, !target.isEmpty else { return nil }
        return warning(target: target, replaced: .shellCommand)
    }

    /// The `warnings` entry for a calendar event row. Internal-function events
    /// have no DM body and always execute, so they never warn. Any other task
    /// type DMs: a spawn-claude event with no prompt still DMs its default
    /// "Run scheduled task: <title>" body (SchedulerActor.loadJobs).
    static func calendarEventWarning(notifyTarget: String?, taskType: String?) -> String? {
        guard let target = notifyTarget, !target.isEmpty else { return nil }
        switch taskType {
        case "internal":
            return nil
        case "shell":
            return warning(target: target, replaced: .shellCommand)
        default:
            return warning(target: target, replaced: .workerPrompt)
        }
    }

    static func warning(target: String, replaced: Replaced) -> String {
        switch replaced {
        case .shellCommand:
            return "notifyTarget is set: at fire time this job's command is DMed to \(target) as text and NOT executed. "
                + "For alert-on-failure, leave notifyTarget empty and POST /api/dm/send from inside the command."
        case .workerPrompt:
            return "notifyTarget is set: at fire time this event's prompt is DMed to \(target) as text and NO worker is spawned. "
                + "For alert-on-failure, leave notifyTarget empty and POST /api/dm/send from inside the task."
        }
    }

    /// The run result recorded when the DM went out instead of the run.
    static func notifiedResult(target: String, messageId: String, payload: ScheduledEntry.JobPayload) -> String {
        let notRun: String
        switch payload {
        case .shellCommand: notRun = "command NOT executed"
        case .claude: notRun = "no worker spawned"
        case .internalFunc: notRun = "NOT executed"
        }
        return "notified \(target) (dm \(messageId)); \(notRun)"
    }
}
