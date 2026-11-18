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
/// Output is drained by a dispatch read source, off the cooperative pool, so a
/// child that outgrows the 64KB pipe buffer never blocks on write.
///
/// Completion is keyed on the child's EXIT, not on EOF. EOF only arrives once
/// every holder of the pipe's write end has closed it, and that need not be the
/// child: a process forked elsewhere in Sonata while this pipe was open can
/// inherit the write end. On 11/18 a worker forked two seconds into
/// HealthMonitor's first cycle did exactly that, and the old
/// `readDataToEndOfFile` waited on GhostWorkerReaper's pgrep pipe for as long as
/// the worker lived (memory c3cf3c8d). So once the child exits, the read gets
/// `drainGrace` to reach EOF; after that, whatever is already buffered in the
/// pipe is read without blocking and the result is returned.
///
/// The child's own runtime is still unbounded: this helper is for short,
/// trusted, bounded-output system binaries (`ps`, `pgrep`, `tar`, `gzip`,
/// `sqlite3`). Callers that need a runtime timeout, streaming output, or a shell
/// parse should use `SchedulerActor.runShellCommand` instead.
enum OffPoolProcess {
    struct Outcome: Sendable {
        let status: Int32
        let stdout: Data

        var text: String { String(data: stdout, encoding: .utf8) ?? "" }
    }

    /// How long a read may wait for EOF after the child has exited. A child
    /// that exited normally delivers EOF within microseconds; only a pipe whose
    /// write end leaked into another process waits out the full grace.
    static let defaultDrainGrace: TimeInterval = 2

    /// Run `executable` with `arguments`, capturing stdout. stderr is discarded.
    /// Returns `nil` only when the process could not be spawned at all; a child
    /// that ran and failed comes back as an `Outcome` with a non-zero `status`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        drainGrace: TimeInterval = defaultDrainGrace
    ) async -> Outcome? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments

                let pipe = Pipe()
                // Foundation's Pipe lacks FD_CLOEXEC. Flag both ends so a fork
                // elsewhere in Sonata skips them; the spawn's dup2 onto the
                // child's stdout clears the flag on that copy only.
                for fd in [pipe.fileHandleForReading.fileDescriptor, pipe.fileHandleForWriting.fileDescriptor] {
                    let flags = fcntl(fd, F_GETFD)
                    if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
                }
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice

                let collector = Collector(drainGrace: drainGrace) { outcome in
                    continuation.resume(returning: outcome)
                }
                proc.terminationHandler = { finished in
                    collector.exited(status: finished.terminationStatus)
                }

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Read from a private non-blocking copy of the read end, owned by
                // a dispatch source whose cancel handler is the only closer. The
                // source can't run an event after cancel, so nothing reads a
                // closed descriptor.
                let readFd = fcntl(pipe.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
                try? pipe.fileHandleForReading.close()
                guard readFd >= 0 else {
                    collector.start(source: nil, fd: -1)
                    return
                }
                let flags = fcntl(readFd, F_GETFL)
                if flags >= 0 { _ = fcntl(readFd, F_SETFL, flags | O_NONBLOCK) }
                let source = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: collector.queue)
                source.setEventHandler { collector.drain() }
                source.setCancelHandler { collector.sourceCancelled() }
                collector.start(source: source, fd: readFd)
            }
        }
    }

    /// Joins the two completion signals (read finished, child exited) and
    /// resumes exactly once. Every field is touched only on `queue`.
    private final class Collector: @unchecked Sendable {
        let queue = DispatchQueue(label: "OffPoolProcess.read", qos: .utility)
        private let drainGrace: TimeInterval
        private let resume: (Outcome) -> Void
        private var source: DispatchSourceRead?
        private var fd: Int32 = -1
        private var data = Data()
        private var readDone = false
        private var cancelRequested = false
        private var exitStatus: Int32?
        private var delivered = false

        init(drainGrace: TimeInterval, resume: @escaping (Outcome) -> Void) {
            self.drainGrace = drainGrace
            self.resume = resume
        }

        /// Called once after spawn. `source == nil` means the read end could
        /// not be set up: the result carries no output but still waits for exit.
        func start(source: DispatchSourceRead?, fd: Int32) {
            queue.async { [self] in
                self.fd = fd
                self.source = source
                if let source {
                    source.resume()
                } else {
                    readDone = true
                    deliverIfReady()
                }
            }
        }

        /// Event handler: read everything buffered; at EOF stop the source.
        func drain() {
            if readAvailable() { stopReading() }
        }

        /// Termination handler (any thread).
        func exited(status: Int32) {
            queue.async { [self] in
                exitStatus = status
                deliverIfReady()
            }
            // A leaked write end means EOF may never come: stop waiting for it.
            queue.asyncAfter(deadline: .now() + drainGrace) { [self] in stopReading() }
        }

        /// Cancel handler: take whatever is still buffered, then close the
        /// only copy of the read end. No event handler runs after this.
        func sourceCancelled() {
            _ = readAvailable()
            close(fd)
            fd = -1
            readDone = true
            deliverIfReady()
        }

        private func stopReading() {
            guard !cancelRequested, let source else { return }
            cancelRequested = true
            source.cancel()
        }

        private func deliverIfReady() {
            guard !delivered, readDone, let status = exitStatus else { return }
            delivered = true
            resume(Outcome(status: status, stdout: data))
        }

        /// Non-blocking read until nothing is buffered. Returns true on EOF.
        private func readAvailable() -> Bool {
            guard fd >= 0 else { return true }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    data.append(contentsOf: buffer[0..<n])
                } else if n == 0 {
                    return true
                } else {
                    // EAGAIN: drained for now. Anything else: the pipe is unusable.
                    return errno != EAGAIN && errno != EINTR
                }
            }
        }
    }
}
