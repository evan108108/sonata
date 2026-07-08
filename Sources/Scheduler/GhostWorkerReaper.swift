import Foundation
import GRDB
import Logging

/// Reap orphaned worker claude processes.
///
/// A "ghost" is a running `claude ... --mcp-config .../mcp-cfg/worker-<id>.json`
/// process whose `<id>` has NO corresponding row in the `workers` table.
/// Two known root causes:
///   1. Sonata restart while workers were alive — the fresh Sonata has no
///      in-memory reference to the prior claude processes, and they were
///      never SIGTERM'd because Sonata's shutdown path doesn't reap them.
///   2. UI Remove race with worker auto-restart — `removeWorker` captures
///      `worker.coordinator?.terminalView?.process?.shellPid` once at the
///      top of the method; if the coordinator recently auto-restarted the
///      underlying claude (processTerminated → view.startProcess), the
///      captured shellPid may be the OLD dead pid, so SIGTERM lands on
///      nothing, the liveness check `kill(deadPid, 0)` returns -1, and the
///      SIGKILL branch is skipped. Meanwhile the CURRENT claude keeps
///      running, still holding its MCP SSE stream and burning tokens.
///
/// Detection uses `pgrep -a -f mcp-cfg/worker-*.json` — the mcp-config path
/// is unique per workerId and invariant across auto-restarts, so it always
/// finds the current pid regardless of Sonata's in-memory state. The
/// `minAgeSeconds` guard avoids racing freshly-spawned workers that haven't
/// completed their initial `worker_register` handshake yet.
enum GhostWorkerReaper {

    /// Minimum process age before a matching pid without a DB row is
    /// considered a ghost. Spawn → register handshake typically completes
    /// in a few seconds; 30s is generous.
    static let minAgeSeconds: TimeInterval = 30

    /// Wait between SIGTERM and the survival check that triggers SIGKILL.
    /// Short — the goal here isn't a graceful shutdown (the process is
    /// unowned and idle to Sonata by definition), it's to give the OS
    /// time to reap after the signal lands.
    static let sigtermGrace: TimeInterval = 3.0

    struct DetectedProcess: Sendable {
        let pid: pid_t
        let workerId: String
        let ageSeconds: TimeInterval
        /// Process state character from `ps -o stat`. `Z` = zombie
        /// (terminated but not waitpid'd), `S`/`R`/`I` = alive. Zombies
        /// are FILTERED OUT of the enumeration returned to callers —
        /// they can't receive signals (already dead) and would cause
        /// the reaper to log SIGTERM every tick without progress.
        let stat: Character
    }

    /// Enumerate every claude worker process on the host (both registered
    /// and unregistered — the caller cross-references against the DB).
    /// Zombies (`ps stat` contains `Z`) are excluded — a defunct process
    /// can't be killed, and repeated SIGTERM attempts against it would
    /// pollute the log. Zombie accumulation is a separate concern (Sonata's
    /// child-process lifecycle isn't waitpid'ing on termination — TODO).
    static func enumerateWorkerProcesses() -> [DetectedProcess] {
        // `-a` prints pid + full argv; `-f` matches against argv, not just
        // the executable name. Regex catches any mcp-cfg path fragment.
        guard let output = shell(
            exec: "/usr/bin/pgrep",
            args: ["-a", "-f", "mcp-cfg/worker-.*\\.json"]
        ) else { return [] }

        var result: [DetectedProcess] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]) else { continue }
            let cmd = String(parts[1])
            // Extract the workerId as the pattern `worker-<digits>`. Uses
            // the mcp-cfg fragment so we get exactly one match per pid.
            guard let match = cmd.range(of: #"worker-\d+"#, options: .regularExpression) else { continue }
            let workerId = String(cmd[match])
            let stat = processStat(pid: pid)
            // Skip zombies — signals are no-ops against a terminated process.
            if stat == "Z" { continue }
            let age = processAge(pid: pid)
            result.append(DetectedProcess(pid: pid, workerId: workerId, ageSeconds: age, stat: stat))
        }
        return result
    }

    /// Read the first character of the process state via `ps -o stat`. Common
    /// values: `S` sleeping, `R` running, `I` idle, `Z` zombie/defunct,
    /// `T` stopped. Returns `?` when ps fails.
    static func processStat(pid: pid_t) -> Character {
        guard let output = shell(
            exec: "/bin/ps",
            args: ["-o", "stat=", "-p", "\(pid)"]
        ) else { return "?" }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first ?? "?"
    }

    /// Seconds since process start, via `ps -o etime`.
    /// etime format: `MM:SS`, `HH:MM:SS`, or `DD-HH:MM:SS`.
    static func processAge(pid: pid_t) -> TimeInterval {
        guard let output = shell(
            exec: "/bin/ps",
            args: ["-o", "etime=", "-p", "\(pid)"]
        ) else { return 0 }
        return parseEtime(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Public for tests. `ps -o etime` may return the width-padded form
    /// with leading spaces; caller must trim.
    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0
        var rest = s
        if let dashIdx = s.firstIndex(of: "-") {
            days = Int(s[..<dashIdx]) ?? 0
            rest = String(s[s.index(after: dashIdx)...])
        }
        let parts = rest.split(separator: ":").compactMap { Int($0) }
        let seconds: Int
        switch parts.count {
        case 2: seconds = parts[0] * 60 + parts[1]
        case 3: seconds = parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return 0
        }
        return TimeInterval(days * 86400 + seconds)
    }

    private static func shell(exec: String, args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Reap orphaned processes. Returns the count killed.
    /// `source` is a short tag ("boot", "monitor") included in every log
    /// line so we can distinguish which invocation caught which ghost.
    @discardableResult
    static func reap(dbPool: DatabasePool, logger: Logger, source: String) async -> Int {
        let detected = enumerateWorkerProcesses()
        guard !detected.isEmpty else { return 0 }

        let live: Set<String>
        do {
            live = try Set(await dbPool.read { db in
                try String.fetchAll(db, sql: "SELECT workerId FROM workers")
            })
        } catch {
            logger.warning("GhostWorkerReaper[\(source)]: DB query failed: \(error.localizedDescription)")
            return 0
        }

        let ghosts = detected.filter { !live.contains($0.workerId) && $0.ageSeconds > minAgeSeconds }
        let tooYoung = detected.filter { !live.contains($0.workerId) && $0.ageSeconds <= minAgeSeconds }

        if !tooYoung.isEmpty {
            let list = tooYoung.map { "\($0.workerId)(age=\(Int($0.ageSeconds))s)" }.joined(separator: ", ")
            logger.info("GhostWorkerReaper[\(source)]: skipping \(tooYoung.count) too-young unregistered process(es): \(list)")
        }

        guard !ghosts.isEmpty else {
            logger.debug("GhostWorkerReaper[\(source)]: \(detected.count) process(es), 0 ghost(s)")
            return 0
        }

        let ghostSummary = ghosts.map {
            "\($0.workerId)(pid=\($0.pid),age=\(Int($0.ageSeconds))s)"
        }.joined(separator: ", ")
        logger.warning("GhostWorkerReaper[\(source)]: found \(ghosts.count) ghost process(es) — \(ghostSummary)")

        for ghost in ghosts {
            _ = Foundation.kill(ghost.pid, SIGTERM)
            logger.info("GhostWorkerReaper[\(source)]: SIGTERM → \(ghost.workerId) (pid \(ghost.pid))")
        }

        try? await Task.sleep(nanoseconds: UInt64(sigtermGrace * 1_000_000_000))

        var killed = 0
        var survivors: [DetectedProcess] = []
        for ghost in ghosts {
            // Alive check — kill(pid, 0) returns 0 if process still exists.
            if Foundation.kill(ghost.pid, 0) != 0 {
                killed += 1
                continue
            }
            _ = Foundation.kill(ghost.pid, SIGKILL)
            logger.warning("GhostWorkerReaper[\(source)]: SIGKILL → \(ghost.workerId) (pid \(ghost.pid))")
            // Give the kernel a beat to reap.
            for _ in 0..<10 {
                usleep(200_000)
                if Foundation.kill(ghost.pid, 0) != 0 { break }
            }
            if Foundation.kill(ghost.pid, 0) != 0 { killed += 1 } else { survivors.append(ghost) }
        }

        if !survivors.isEmpty {
            let list = survivors.map { "\($0.workerId)(pid=\($0.pid))" }.joined(separator: ", ")
            logger.error("GhostWorkerReaper[\(source)]: SURVIVED SIGKILL: \(list) — manual `kill -9` may be required")
        }
        logger.info("GhostWorkerReaper[\(source)]: reaped \(killed)/\(ghosts.count) ghost(s)")
        return killed
    }
}
