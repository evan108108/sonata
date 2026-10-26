import Foundation

/// Holds back forkpty spawns until the HTTP listener carries FD_CLOEXEC.
///
/// SwiftTerm's forkpty is a plain fork+exec, so a child forked while the
/// acceptor socket lacks FD_CLOEXEC keeps its own copy of it for life. On
/// 2026-10-25 three restored interactive sessions forked about a second
/// before the old 500ms-delayed sweep ran. When the HTTP watchdog later
/// restarted the server, every rebind hit EADDRINUSE, and :3211 stayed down
/// for the whole fleet until those children were killed (memory 9c94ba95).
///
/// Every forkpty entry point (interactive sessions, workers, the supervisor,
/// sidecars, the inspector) runs its spawn through `afterOpen`. The HTTP
/// server opens the gate from Hummingbird's `onServerRunning`, once it has
/// swept the new listener, and closes it again before a restart rebinds.
/// Foundation `Process` children don't need the gate: on Darwin it spawns
/// with POSIX_SPAWN_CLOEXEC_DEFAULT, which closes every inherited descriptor.
final class ListenerCloexecGate: @unchecked Sendable {
    static let shared = ListenerCloexecGate()

    private let lock = NSLock()
    private var isOpenStorage: Bool
    private var pending: [() -> Void] = []
    /// Where queued spawns run once the gate opens. The spawn sites are
    /// main-thread UI code (SwiftTerm views), so production uses `.main`.
    private let deliveryQueue: DispatchQueue

    init(open: Bool = false, deliveryQueue: DispatchQueue = .main) {
        self.isOpenStorage = open
        self.deliveryQueue = deliveryQueue
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpenStorage
    }

    /// Run `body` now if the gate is open; otherwise queue it to run on the
    /// delivery queue when the gate opens.
    func afterOpen(_ body: @escaping () -> Void) {
        lock.lock()
        if isOpenStorage {
            lock.unlock()
            body()
            return
        }
        pending.append(body)
        lock.unlock()
    }

    /// Open the gate and release queued spawns in arrival order.
    func open(reason: String) {
        lock.lock()
        guard !isOpenStorage else {
            lock.unlock()
            return
        }
        isOpenStorage = true
        let queued = pending
        pending = []
        lock.unlock()
        sonataFileLog("Spawn gate: open (\(reason)); releasing \(queued.count) queued spawn(s)")
        guard !queued.isEmpty else { return }
        deliveryQueue.async {
            queued.forEach { $0() }
        }
    }

    /// Close the gate so new spawns queue until the next `open`.
    func close(reason: String) {
        lock.lock()
        let wasOpen = isOpenStorage
        isOpenStorage = false
        lock.unlock()
        if wasOpen { sonataFileLog("Spawn gate: closed (\(reason))") }
    }
}
