import Foundation

/// Spawns a subprocess and collects its output without pinning a Swift
/// cooperative thread.
///
/// `Process.waitUntilExit()` and `FileHandle.readDataToEndOfFile()` are blocking
/// syscalls. Swift's cooperative pool holds roughly one thread per core, and
/// Sonata's HTTP server is served from that same pool, so a blocking wait inside
/// an `async` function removes one of a handful of threads for the child's entire
/// lifetime. Starve enough of them and NIO can no longer schedule the
/// continuation behind `channelActive`; the async writer Hummingbird allocated
/// for that connection is released without `finish()`, and
/// `NIOAsyncWriter.InternalClass.deinit` fires its `preconditionFailure` — a
/// SIGTRAP on a NIO event-loop thread that reads like an upstream async-channel
/// race but is really pool exhaustion on our side (SCT-4).
///
/// The blocking work is handed to a GCD global queue, which is built for
/// blocking I/O and does not share the cooperative pool. Same reasoning as
/// `PluginManager.tailPluginPipe` and `SchedulerActor.runShellCommand`; this is
/// the reusable form for the plain "run it and read stdout" case.
///
/// Callers that need a timeout, streaming output, or a shell parse should use
/// `SchedulerActor.runShellCommand` instead — this helper deliberately has no
/// timeout and is meant for short, trusted, bounded-output system binaries
/// (`ps`, `pgrep`, `tar`, `gzip`, `sqlite3`).
enum OffPoolProcess {
    struct Outcome: Sendable {
        let status: Int32
        let stdout: Data

        var text: String { String(data: stdout, encoding: .utf8) ?? "" }
    }

    /// Run `executable` with `arguments`, capturing stdout. stderr is discarded.
    /// Returns `nil` only when the process could not be spawned at all; a child
    /// that ran and failed comes back as an `Outcome` with a non-zero `status`.
    static func run(_ executable: String, _ arguments: [String]) async -> Outcome? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Drain to EOF *before* waiting. A child that outgrows the 64KB
                // pipe buffer blocks on write until someone reads, so the
                // wait-then-read order deadlocks on large output. EOF arrives
                // when the child closes its write end, so the wait below returns
                // promptly once the read completes.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                continuation.resume(
                    returning: Outcome(status: proc.terminationStatus, stdout: data)
                )
            }
        }
    }
}
