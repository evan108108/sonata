import Foundation

/// The user's choices for one sidecar, as set in Settings → Sidecars.
///
/// Deliberately separate from `Sidecar`: that type is immutable registration
/// config authored in code, this one is mutable preference authored by a human.
/// They meet at boot, where the registering call site reads a config out of
/// `SidecarConfigStore` and folds it into the `Sidecar` it constructs.
///
/// Only `tier`, `subscriptionCapPct` and `rotationThreshold` have counterparts
/// on `Sidecar` today — the framework carries those three. The rest are knobs a
/// sidecar interprets for itself when it builds a per-request agent prompt, and
/// travel in the event payload rather than the registration.
struct SidecarUserConfig: Codable, Sendable, Equatable {

    /// Model the sidecar's judge step runs on.
    enum JudgeModel: String, Codable, Sendable, CaseIterable {
        case haiku
        case sonnet

        var label: String {
            switch self {
            case .haiku:  return "Haiku"
            case .sonnet: return "Sonnet"
            }
        }
    }

    /// How much of the requesting session's recent turn the sidecar is handed.
    enum ContextDepth: String, Codable, Sendable, CaseIterable {
        case lastPrompt
        case plusAssistantHead
        case full

        var label: String {
            switch self {
            case .lastPrompt:        return "Last user prompt"
            case .plusAssistantHead: return "+2K chars of assistant"
            case .full:              return "Full turn"
            }
        }
    }

    /// How `mem_recall` weights recency. Passed through to the endpoint as
    /// the `recencyMode` query parameter. `recent` (48h half-life) favors
    /// memories tied to the current work window; `linear` (30-day gentle
    /// decay) is closer to "topically match everything and let ranking
    /// sort it out."
    ///
    /// In-process memory sidecar consumes this. Other sidecars can ignore
    /// it — knobs on `SidecarUserConfig` are read a la carte by whichever
    /// sidecar's implementation cares.
    enum RecencyMode: String, Codable, Sendable, CaseIterable {
        case linear
        case recent

        var label: String {
            switch self {
            case .linear: return "Linear (30-day decay)"
            case .recent: return "Recent (48h half-life)"
            }
        }
    }

    /// Trigger identifiers. These strings cross into event payloads and SKILL.md
    /// prompts, so they are named once here rather than spelled inline.
    enum Trigger {
        static let stopHook = "stop_hook"
        static let submitRefine = "submit_refine"

        /// Every trigger the settings panel offers, in display order.
        static let all = [stopHook, submitRefine]

        static func label(_ trigger: String) -> String {
            switch trigger {
            case stopHook:     return "Stop hook"
            case submitRefine: return "Submit refine"
            default:           return trigger
            }
        }
    }

    /// Defaults for the knobs the framework does not carry. The three it does
    /// (`tier`, `subscriptionCapPct`, `rotationThreshold`) intentionally read
    /// from `Sidecar.Defaults` instead, so there is exactly one copy of each
    /// number in the codebase.
    enum Defaults {
        static let judgeModel: JudgeModel = .haiku
        static let contextDepth: ContextDepth = .plusAssistantHead
        static let topK = 10
        static let dedupWindow = 20
        static let triggers: Set<String> = [Trigger.stopHook]

        /// Two knobs that only the in-process memory sidecar reads today.
        /// Adding them to the settings panel lets the user tune "signal vs.
        /// noise" without a code change: `.recent` + a 0.6 floor produced
        /// noticeably better hits than the raw ranking in dry-run tests
        /// (2026-07-22).
        static let recencyMode: RecencyMode = .recent
        /// `mem_recall._rankScore` floor. Below this, don't inject a hint —
        /// the reader has to consider every hint even if they dismiss most,
        /// so a low bar burns their attention. 0.6 was where the dry-run
        /// signal-to-noise crossed over.
        static let minRankScore = 0.6
    }

    /// Bounds for the numeric knobs. Enforced by `normalized()` rather than by
    /// the controls alone, because this file is also hand-editable on disk.
    enum Bounds {
        static let subscriptionCapPct = 1...100
        static let topK = 1...50
        static let dedupWindow = 1...200
        /// Below ~50% a sidecar would rotate constantly; above ~95% it risks
        /// filling its window before the 30s monitor tick notices.
        static let rotationThreshold = 50...95
        /// Score is `_rankScore` from `mem_recall`, roughly 0.0-1.0 (uncapped
        /// on the top end but rarely above 1 for well-tuned queries). Anything
        /// below ~0.5 is mostly noise; anything above ~0.8 is a strong hit.
        static let minRankScore = 0.0...1.0
    }

    /// Discrete choices the panel offers for rotation threshold, from the
    /// design spec. Free-form values from a hand-edited file still load — they
    /// are only clamped to `Bounds.rotationThreshold`.
    static let rotationThresholdChoices = [50, 70, 80, 90]

    /// `.off` means "user turned this sidecar off". There is no separate
    /// enabled flag: `SidecarLifecycle` already skips `.off` sidecars when
    /// spawning and monitoring, and a second boolean over the same state would
    /// only be something to keep in sync.
    var tier: SidecarBudgetTier
    var subscriptionCapPct: Int
    var judgeModel: JudgeModel
    var contextDepth: ContextDepth
    var topK: Int
    var triggers: Set<String>
    var dedupWindow: Int
    var rotationThreshold: Int
    var recencyMode: RecencyMode
    var minRankScore: Double

    var isEnabled: Bool { tier != .off }

    static let `default` = SidecarUserConfig(
        tier: Sidecar.Defaults.budgetTier,
        subscriptionCapPct: Sidecar.Defaults.subscriptionCapPct,
        judgeModel: Defaults.judgeModel,
        contextDepth: Defaults.contextDepth,
        topK: Defaults.topK,
        triggers: Defaults.triggers,
        dedupWindow: Defaults.dedupWindow,
        rotationThreshold: Sidecar.Defaults.rotationThreshold,
        recencyMode: Defaults.recencyMode,
        minRankScore: Defaults.minRankScore
    )

    /// The config a sidecar starts life with: the shared defaults, overlaid
    /// with whatever its own registration declared. A sidecar registered at
    /// `.low` with a 5% cap should show as low/5% the first time the user opens
    /// Settings, not as the generic standard/20%.
    static func seeded(from sidecar: Sidecar) -> SidecarUserConfig {
        var config = SidecarUserConfig.default
        config.tier = sidecar.budgetTier
        config.subscriptionCapPct = sidecar.subscriptionCapPct
        config.rotationThreshold = sidecar.rotationThreshold
        if !sidecar.triggers.isEmpty {
            config.triggers = sidecar.triggers
        }
        return config.normalized()
    }

    /// Clamp numerics into range and drop triggers the current tier can't run.
    ///
    /// Applied on every read and every write, so neither a stale file nor a
    /// hand edit can put the panel — or a spawned sidecar — into a state the
    /// controls themselves would refuse to produce. Per the design spec,
    /// submit-refine is a High-tier-only trigger.
    func normalized() -> SidecarUserConfig {
        var copy = self
        copy.subscriptionCapPct = Self.clamp(subscriptionCapPct, to: Bounds.subscriptionCapPct)
        copy.topK = Self.clamp(topK, to: Bounds.topK)
        copy.dedupWindow = Self.clamp(dedupWindow, to: Bounds.dedupWindow)
        copy.rotationThreshold = Self.clamp(rotationThreshold, to: Bounds.rotationThreshold)
        copy.minRankScore = Self.clampDouble(minRankScore, to: Bounds.minRankScore)
        if tier != .high {
            copy.triggers.remove(Trigger.submitRefine)
        }
        return copy
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func clampDouble(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Persists per-sidecar user config across launches.
///
/// Shape mirrors `SidecarRegistry` / `WhatHappenedRegistry` — lock-guarded
/// `final class` plus `static let shared` — for the same reason: the settings
/// panel and the boot-time registration path both read this synchronously, and
/// an actor would push an `await` into both.
///
/// Backed by a JSON file under the instance's data directory rather than
/// UserDefaults, deliberately. `SonataInstance.dataDirectory` honours
/// `$SONATA_DATA_DIR` and UserDefaults does not, so a secondary instance
/// sharing defaults with the primary would inherit its sidecar tiers and start
/// spawning budget-consuming sessions — the failure mode `SonataInstance`
/// exists to prevent. A file also stays inspectable, which matters for config
/// that spends money.
///
/// **Lifecycle:** call `load()` once at boot, before sidecars are registered.
/// Reads before that see defaults, which would silently discard the user's
/// tier choice at exactly the moment it matters.
final class SidecarConfigStore: @unchecked Sendable {
    static let shared = SidecarConfigStore()

    /// `<dataDir>/config/sidecars.json`.
    static var defaultPath: String {
        "\(SonataInstance.dataDirectory)/config/sidecars.json"
    }

    private let path: String
    private var configsByName: [String: SidecarUserConfig] = [:]
    private var loaded = false
    private let lock = NSLock()

    /// `path` is injectable so tests can point at a scratch file instead of the
    /// user's real config.
    init(path: String = SidecarConfigStore.defaultPath) {
        self.path = path
    }

    /// Whether `load()` has run. The settings panel surfaces this: a panel
    /// showing defaults because nothing was loaded looks identical to one
    /// showing genuine defaults, and only one of those is correct.
    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loaded
    }

    // MARK: - Read

    /// Stored config for `name`, or `SidecarUserConfig.default` when the user
    /// has never touched this sidecar.
    ///
    /// Prefer `config(for: Sidecar)` where a `Sidecar` is in hand — it seeds
    /// unset entries from the registration instead of the generic defaults.
    func config(forName name: String) -> SidecarUserConfig {
        lock.lock()
        defer { lock.unlock() }
        return (configsByName[name] ?? .default).normalized()
    }

    func config(for sidecar: Sidecar) -> SidecarUserConfig {
        lock.lock()
        defer { lock.unlock() }
        if let stored = configsByName[sidecar.name] {
            return stored.normalized()
        }
        return .seeded(from: sidecar)
    }

    /// Every config the user has explicitly set. Sidecars still on their
    /// defaults are absent — this is the stored file, not the effective state.
    func allStored() -> [String: SidecarUserConfig] {
        lock.lock()
        defer { lock.unlock() }
        return configsByName
    }

    // MARK: - Write

    /// Store `config` for `name` and persist. Throws only on a write failure;
    /// the in-memory value is updated either way, so a read-only disk degrades
    /// to "settings don't survive relaunch" rather than "settings don't apply".
    func setConfig(_ config: SidecarUserConfig, forName name: String) throws {
        lock.lock()
        configsByName[name] = config.normalized()
        let snapshot = configsByName
        lock.unlock()
        try write(snapshot)
    }

    /// Drop a sidecar's overrides, returning it to registration defaults.
    func clearConfig(forName name: String) throws {
        lock.lock()
        configsByName.removeValue(forKey: name)
        let snapshot = configsByName
        lock.unlock()
        try write(snapshot)
    }

    // MARK: - Persistence

    /// Read the config file into memory. Call once at boot.
    ///
    /// A missing file is the normal first-launch state and loads as empty. A
    /// *corrupt* file throws: silently resetting a user's sidecar budgets to
    /// defaults because one byte got mangled is worse than a visible error.
    /// The in-memory state is left untouched on a throw.
    func load() throws {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            lock.lock()
            loaded = true
            lock.unlock()
            return
        }

        let decoded = try JSONDecoder().decode([String: SidecarUserConfig].self, from: data)
        lock.lock()
        configsByName = decoded.mapValues { $0.normalized() }
        loaded = true
        lock.unlock()
    }

    private func write(_ configs: [String: SidecarUserConfig]) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configs)
        // Atomic: a crash mid-write would otherwise leave the truncated file
        // that `load()` refuses to decode.
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Drop all state without touching disk. Tests only.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        configsByName.removeAll()
        loaded = false
    }
}
