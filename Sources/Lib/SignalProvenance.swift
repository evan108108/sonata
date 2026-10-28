import Foundation
import Darwin

/// Logs who sent SIGTERM/SIGINT to Sonata.
///
/// Sonata is a GUI app: it quits through NSApplication (deploy-local uses an
/// AppleEvent), so a termination signal is either a real shutdown request or
/// a stray. Before this, a stray was invisible: ServiceGroup swallowed it and
/// the HTTP supervisor only saw "runService returned unexpectedly". The
/// SA_SIGINFO handler records the sender's pid, and a reader thread logs it
/// with the sender's executable path.
///
/// The handler replaces the default disposition, so a signal that arrives
/// before SonataApp registers its shutdown sources is logged, not fatal.
/// Darwin's kqueue EVFILT_SIGNAL still sees the delivery, so the
/// DispatchSource shutdown handlers keep working alongside it.
enum SignalProvenance {
    struct Record: Equatable {
        let signo: Int32
        let senderPID: pid_t
        let at: Date
    }

    private static let lock = NSLock()
    private static var installed = false
    private static var last: Record?

    /// Install once, as early as possible. Safe to call again (no-op).
    static func install(signals: [Int32] = [SIGTERM, SIGINT]) {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else {
            sonataFileLog("Signal provenance: pipe() failed (errno \(errno)); not installed")
            return
        }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        signalProvenanceWriteFD = fds[1]
        let readFD = fds[0]

        for signo in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = signalProvenanceHandler
            action.sa_flags = SA_SIGINFO | SA_RESTART
            sigemptyset(&action.sa_mask)
            if sigaction(signo, &action, nil) != 0 {
                sonataFileLog("Signal provenance: sigaction(\(name(of: signo))) failed (errno \(errno))")
            }
        }
        installed = true

        let reader = Thread {
            var buf: [Int32] = [0, 0]
            let size = MemoryLayout<Int32>.size * 2
            while true {
                let n = buf.withUnsafeMutableBytes { read(readFD, $0.baseAddress, size) }
                if n == size {
                    let record = Record(signo: buf[0], senderPID: buf[1], at: Date())
                    lock.lock()
                    last = record
                    lock.unlock()
                    sonataFileLog("Signal: " + describe(record))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
        reader.name = "sonata.signal-provenance"
        reader.start()
    }

    /// The most recent signal recorded since install, if any.
    static func lastRecord() -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    /// "SIGTERM from pid 123 (/path/to/exe)", marking this process as such.
    static func describe(_ record: Record, selfPID: pid_t = getpid()) -> String {
        let sender: String
        if record.senderPID == selfPID {
            sender = "pid \(record.senderPID) (this Sonata)"
        } else {
            sender = "pid \(record.senderPID) (\(executablePath(of: record.senderPID) ?? "exited or unknown"))"
        }
        return "\(name(of: record.signo)) from \(sender)"
    }

    static func name(of signo: Int32) -> String {
        switch signo {
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGHUP: return "SIGHUP"
        default: return "signal \(signo)"
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}

/// Written only by `install`, before any handler is registered.
private var signalProvenanceWriteFD: Int32 = -1

/// Async-signal-safe: one write(2) of 8 bytes (< PIPE_BUF, so atomic).
private func signalProvenanceHandler(
    _ signo: Int32,
    _ info: UnsafeMutablePointer<__siginfo>?,
    _ context: UnsafeMutableRawPointer?
) {
    let saved = errno
    var record: (Int32, Int32) = (signo, info?.pointee.si_pid ?? 0)
    _ = withUnsafeBytes(of: &record) { write(signalProvenanceWriteFD, $0.baseAddress, $0.count) }
    errno = saved
}
