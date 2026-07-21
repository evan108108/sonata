import Foundation

/// The reader in force until the real tracker is installed. Answers nil for
/// everything, which renders as no spend indicator at all.
///
/// Exists so display code can depend on `SidecarSpendReader` unconditionally
/// instead of unwrapping an optional tracker at every call site — and so a
/// build with spend tracking disabled shows nothing rather than zeros. Per the
/// protocol, nil means "there is no meaningful bar to draw", never "0 spent".
struct NullSidecarSpendReader: SidecarSpendReader {
    func spendSnapshot(for sidecarName: String) async -> SidecarSpendSnapshot? { nil }
}

/// Holds the process-wide `SidecarSpendReader`.
///
/// Indirection rather than a direct dependency because the concrete tracker is
/// constructed once at boot by the subsystem that owns spend accounting, while
/// the things that read it — the settings panel today, the detail page and
/// throttling later — are SwiftUI views built all over and cannot take it as an
/// init parameter.
///
/// Same lock-guarded `final class` + `static let shared` shape as
/// `SidecarRegistry`: `install` and the reader swap are synchronous, and an
/// actor would push an `await` into boot.
///
/// Conforms to `SidecarSpendReader` itself, so a view can hold the registry and
/// be none the wiser about whether a real tracker has been installed yet.
final class SidecarSpendRegistry: @unchecked Sendable, SidecarSpendReader {
    static let shared = SidecarSpendRegistry()

    private var reader: SidecarSpendReader = NullSidecarSpendReader()
    private let lock = NSLock()

    private init() {}

    /// Install the live reader. Called once at boot by the spend tracker.
    func install(_ reader: SidecarSpendReader) {
        lock.lock()
        defer { lock.unlock() }
        self.reader = reader
    }

    /// The installed reader. Synchronous and separate from `spendSnapshot`
    /// on purpose: it makes holding the lock across an `await` structurally
    /// impossible rather than merely discouraged.
    ///
    /// That matters more than style. `NSLock` must be unlocked by the thread
    /// that locked it and a suspended task can resume on a different one, so
    /// locking across a suspension is a correctness bug — which is why Swift
    /// marks `NSLock.lock()` unavailable from async contexts outright (an error
    /// in Swift 6, not just a warning). Keeping the critical section in a
    /// non-async function satisfies that by construction. It also avoids
    /// holding this lock while the concrete tracker hops to its own actor
    /// executor, which is how lock-ordering deadlocks start.
    private func currentReader() -> SidecarSpendReader {
        lock.lock()
        defer { lock.unlock() }
        return reader
    }

    /// Current-window spend for `sidecarName`, delegated to the installed
    /// reader.
    func spendSnapshot(for sidecarName: String) async -> SidecarSpendSnapshot? {
        await currentReader().spendSnapshot(for: sidecarName)
    }

    /// Restore the null reader. Tests only.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        reader = NullSidecarSpendReader()
    }
}
