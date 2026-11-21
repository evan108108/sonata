import Foundation
import Darwin

/// What HealthMonitor's watchdog found when it looked at a stall, and what a
/// human should do about it.
///
/// Why (2026-11-21): the monitor sat in step 'check:workerPool' from 14:12Z,
/// and the watchdog emailed "stuck 10m in check:workerPool" every 10 minutes.
/// The real cause was a macOS keychain dialog: WebKit read its WebCrypto master
/// key on the main thread, the ad-hoc deploy's new cdhash wasn't on the key's
/// ACL, and the main thread waited on SecurityAgent (learning ef3f2a45). Only a
/// person at the Mac can answer that dialog, and the alert never said so.
struct StallDiagnosis: Sendable, Equatable {
    enum Cause: String, Sendable {
        /// The main thread answered; the stuck step waits on something else.
        case notMainThread
        /// The main thread did not answer, and no keychain dialog explains it.
        case mainThreadBlocked
        /// The main thread did not answer and a keychain dialog is up for Sonata.
        case keychainDialog
    }

    let cause: Cause
    /// Start time of the newest SecurityAgent process that started after
    /// Sonata launched (SecurityAgent draws keychain dialogs).
    let securityAgentSince: Date?
    /// The keychain frame `sample` found on Sonata's stacks, when it found one.
    let sampleEvidence: String?

    static let notMainThread = StallDiagnosis(cause: .notMainThread, securityAgentSince: nil, sampleEvidence: nil)

    /// One line for the alert email and the supervisor: what is on screen and
    /// what the human does. Empty for `notMainThread` (the step name is all we know).
    var humanAction: String {
        switch cause {
        case .keychainDialog:
            let since = securityAgentSince.map(Self.describe) ?? "an unknown time"
            return "A macOS keychain dialog from Sonata is waiting on your screen since \(since): enter your login password and click Always Allow. Root fix: fc30d09 on fix/webcrypto-master-key-delegate."
        case .mainThreadBlocked:
            return "Sonata's main thread is blocked and no keychain dialog explains it. Look at the screen for any modal dialog from Sonata; otherwise run `sample <Sonata pid> 1` and read the main thread's stack."
        case .notMainThread:
            return ""
        }
    }

    /// "9:00 AM EST (14:00:56Z)"
    static func describe(_ date: Date) -> String {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "h:mm a zzz"
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "HH:mm:ss'Z'"
        return "\(local.string(from: date)) (\(utc.string(from: date)))"
    }
}

/// Probes that diagnose a stalled HealthMonitor step from outside the stalled
/// loop. None of them touch the main thread or any actor: a stall is exactly
/// when those may not answer.
enum StallDiagnoser {
    /// How long the main thread gets to run a no-op before it counts as blocked.
    static let mainThreadProbeTimeout: TimeInterval = 2
    /// Ceiling on the whole diagnosis, `sample` included, so a wedged probe
    /// can't stop the alert. `sample <pid> 1` takes ~3s on this Mac.
    static let diagnosisTimeout: TimeInterval = 30
    /// The process that draws macOS authorization and keychain dialogs.
    static let securityAgentName = "SecurityAgent"
    /// Stack frames that mean Sonata is waiting on a keychain read. The 11/11 and
    /// 11/21 hangs both sat in getWebCryptoMasterKey → SecItemCopyMatching.
    static let keychainFrames = ["SecItemCopyMatching", "WebCryptoMasterKey", "SecKeychainItemCopyContent"]

    /// The production diagnosis.
    static func diagnose() async -> StallDiagnosis {
        let result = await BoundedAwait.value(within: diagnosisTimeout) {
            await diagnoseUnbounded()
        }
        // Timed out: the probes themselves hung, which only a blocked process does.
        return result ?? StallDiagnosis(cause: .mainThreadBlocked, securityAgentSince: nil, sampleEvidence: nil)
    }

    private static func diagnoseUnbounded() async -> StallDiagnosis {
        if await mainThreadResponds(within: mainThreadProbeTimeout) {
            return .notMainThread
        }
        let launch = processStartTime(pid: getpid()) ?? .distantPast
        let agentSince = newestStart(of: processStartTimes(named: securityAgentName), after: launch)
        let evidence = await sampleKeychainEvidence()
        return classify(mainThreadResponds: false, securityAgentSince: agentSince, sampleEvidence: evidence)
    }

    /// Pure decision, separated so it can be tested without a blocked main thread.
    /// A keychain dialog needs SecurityAgent started after Sonata's launch, or a
    /// keychain frame on Sonata's own stacks; either alone is enough to tell the
    /// human to look at the screen.
    static func classify(mainThreadResponds: Bool, securityAgentSince: Date?, sampleEvidence: String?) -> StallDiagnosis {
        if mainThreadResponds { return .notMainThread }
        if securityAgentSince != nil || sampleEvidence != nil {
            return StallDiagnosis(cause: .keychainDialog, securityAgentSince: securityAgentSince, sampleEvidence: sampleEvidence)
        }
        return StallDiagnosis(cause: .mainThreadBlocked, securityAgentSince: nil, sampleEvidence: nil)
    }

    /// Ask the main queue to run a no-op; false if it hasn't within `timeout`.
    static func mainThreadResponds(within timeout: TimeInterval) async -> Bool {
        let answered = await BoundedAwait.value(within: timeout) {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                DispatchQueue.main.async { cont.resume(returning: true) }
            }
        }
        return answered ?? false
    }

    static func newestStart(of starts: [Date], after launch: Date) -> Date? {
        starts.filter { $0 > launch }.max()
    }

    /// The first keychain frame named in a `sample` report, or nil.
    static func keychainFrame(inSample text: String) -> String? {
        keychainFrames.first { text.contains($0) }
    }

    /// `sample` Sonata's own pid for one second and look for a keychain frame.
    private static func sampleKeychainEvidence() async -> String? {
        guard let out = await OffPoolProcess.run("/usr/bin/sample", ["\(getpid())", "1", "-mayDie"]),
              out.status == 0 else { return nil }
        return keychainFrame(inSample: out.text)
    }

    // MARK: - Process table (sysctl, no subprocess)

    static func processStartTimes(named name: String) -> [Date] {
        allProcesses().filter { $0.name == name }.map(\.start)
    }

    static func processStartTime(pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return startDate(info)
    }

    private static func allProcesses() -> [(name: String, start: Date)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Headroom: processes can appear between the size query and the read.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return procs.prefix(count).map { p in
            var comm = p.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return (name: name, start: startDate(p))
        }
    }

    private static func startDate(_ p: kinfo_proc) -> Date {
        let tv = p.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
