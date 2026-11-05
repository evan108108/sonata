import Foundation

/// A shell job piped into `tail` records tail's exit code, not the command's.
///
/// The scheduler runs a job with `/bin/zsh -c <command>` and stores the
/// process exit status as lastExitCode. Without `pipefail`, a pipeline's status
/// is its LAST stage's, and `tail` exits 0. So a command that crashes or exits
/// non-zero still records lastExitCode 0. (2026-11-05: scout-machine-drift-report
/// wrote exit 3 / MEASUREMENT_FAILED to its own state file while its row read 0.)
/// The rows that already prefix `set -o pipefail; ` record the real status.
/// scheduler_create warns and never rejects: a job may deliberately ignore its
/// exit code.
enum TailPipeSemantics {

    /// Matches a pipe into tail (`| tail`, `|tail`) but not `|| tail`.
    private static let tailPipe = try! NSRegularExpression(pattern: #"(^|[^|])\|\s*tail\b"#)

    /// The `warnings` entry for a scheduled job command. nil when the command
    /// does not pipe into tail, or already mentions pipefail.
    static func scheduledJobWarning(command: String) -> String? {
        guard !command.contains("pipefail") else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        guard tailPipe.firstMatch(in: command, range: range) != nil else { return nil }
        return "command pipes into tail without pipefail: lastExitCode will be tail's (always 0), not the command's. "
            + "Prefix it with `set -o pipefail; ` to record the command's own exit code."
    }
}
