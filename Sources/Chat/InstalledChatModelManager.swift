import Foundation
import GRDB
import Logging

/// Manages the lifecycle of user-installed local chat models (Phase F.3).
///
/// At boot, reads `installedChatModels` rows from the DB and hydrates
/// `LocalChatModelRegistry.userInstalled` so the worker / session pickers see
/// the installed models alongside the hardcoded ones.
///
/// On `install(...)`, constructs an ephemeral `ManagedBinary` spec for the
/// user's HuggingFace URL (or any other direct GGUF URL), runs it through
/// `BinaryProvisioner` to download + cache, then registers the model.
///
/// On `uninstall(...)`, stops any running llama-server process for that model,
/// deletes the on-disk GGUF, drops the DB row, and refreshes the registry.
actor InstalledChatModelManager {
    static let shared = InstalledChatModelManager()

    private let logger: Logger
    private var dbPool: DatabasePool?

    init() {
        var log = Logger(label: "sonata.installedchatmodels")
        log.logLevel = .info
        self.logger = log
    }

    enum InstallError: Error, CustomStringConvertible {
        case noDBPool
        case modelNameInUse(String)
        case modelNameInvalid(String)
        case downloadFailed
        case rowNotFound(String)

        var description: String {
            switch self {
            case .noDBPool:
                return "InstalledChatModelManager: bootstrap(dbPool:) was never called"
            case .modelNameInUse(let n):
                return "model name '\(n)' is already in the registry"
            case .modelNameInvalid(let n):
                return "model name '\(n)' is invalid — use lowercase letters, digits, hyphens"
            case .downloadFailed:
                return "GGUF download failed (network error, bad URL, or checksum mismatch — check Sonata.log)"
            case .rowNotFound(let id):
                return "no installed model with id \(id)"
            }
        }
    }

    enum InstallStatus: Sendable {
        case downloading
        case installed
        case failed(String)
    }

    /// Wire up the DB pool and hydrate the registry from the installed-models
    /// table. Called once at app boot from `SonataApp`'s launch sequence.
    func bootstrap(dbPool: DatabasePool) {
        self.dbPool = dbPool
        let rows = InstalledChatModelsStore.loadAll(dbPool: dbPool)
        let specs = rows.compactMap { Self.specFromRow($0) }
        LocalChatModelRegistry.replaceUserInstalled(specs)
        if !specs.isEmpty {
            logger.info("hydrated \(specs.count) user-installed chat model(s)")
        }
    }

    /// Install a new model. Validates the modelName, picks a monotonic port,
    /// inserts a placeholder DB row (so the UI can list it as "Downloading"),
    /// runs the provisioner, persists the on-disk path, and refreshes the
    /// registry. On failure the placeholder row is removed so retry works.
    @discardableResult
    func install(
        modelName: String,
        displayName: String,
        sourceURL: URL,
        sha256: String? = nil,
        onStatus: (@Sendable (InstallStatus) -> Void)? = nil
    ) async throws -> String {
        guard let dbPool else { throw InstallError.noDBPool }
        guard Self.isValidModelName(modelName) else {
            throw InstallError.modelNameInvalid(modelName)
        }
        if LocalChatModelRegistry.spec(for: modelName) != nil {
            throw InstallError.modelNameInUse(modelName)
        }

        let id = UUID().uuidString.lowercased()
        // Floor port one past the hardcoded entries so user-installed models
        // never collide with the built-in Llama 3.1 8B even if no user rows
        // exist yet.
        let floor = LocalChatModelRegistry.basePort + LocalChatModelRegistry.hardcoded.count
        let port = InstalledChatModelsStore.nextAvailablePort(dbPool: dbPool, floor: floor)

        do {
            try InstalledChatModelsStore.insert(
                dbPool: dbPool, id: id, modelName: modelName, displayName: displayName,
                sourceURL: sourceURL.absoluteString, sha256: sha256, port: port,
                ggufPath: nil
            )
        } catch {
            logger.error("install: insert placeholder row failed: \(error)")
            throw InstallError.downloadFailed
        }

        onStatus?(.downloading)
        let spec = Self.ephemeralBinary(id: id, modelName: modelName,
                                        sourceURL: sourceURL, sha256: sha256)
        guard let path = await BinaryProvisioner.shared.provision(spec) else {
            InstalledChatModelsStore.delete(dbPool: dbPool, id: id)
            onStatus?(.failed("download failed"))
            throw InstallError.downloadFailed
        }
        InstalledChatModelsStore.setGGUFPath(dbPool: dbPool, id: id, ggufPath: path)
        refreshRegistry()
        onStatus?(.installed)
        logger.info("installed \(modelName) on port \(port), GGUF at \(path)")
        return id
    }

    /// Remove an installed model: shut down its server, delete the GGUF,
    /// drop the DB row, and refresh the registry. Idempotent — silently
    /// no-ops if the id is unknown.
    func uninstall(id: String) async throws {
        guard let dbPool else { throw InstallError.noDBPool }
        let rows = InstalledChatModelsStore.loadAll(dbPool: dbPool)
        guard let row = rows.first(where: { $0.id == id }) else {
            return
        }
        await ChatServerManager.shared.shutdown(modelName: row.modelName)
        if let path = row.ggufPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        InstalledChatModelsStore.delete(dbPool: dbPool, id: id)
        refreshRegistry()
        logger.info("uninstalled \(row.modelName) (port \(row.port))")
    }

    /// All installed model rows, fresh from the DB. UI table reads this.
    func listInstalled() -> [InstalledChatModel] {
        guard let dbPool else { return [] }
        return InstalledChatModelsStore.loadAll(dbPool: dbPool)
    }

    // MARK: - Internals

    /// Re-hydrate `LocalChatModelRegistry.userInstalled` from the current DB
    /// state. Called after install/uninstall so subsequent picker reads see
    /// the new shape.
    private func refreshRegistry() {
        guard let dbPool else { return }
        let rows = InstalledChatModelsStore.loadAll(dbPool: dbPool)
        let specs = rows.compactMap { Self.specFromRow($0) }
        LocalChatModelRegistry.replaceUserInstalled(specs)
    }

    /// Promote a DB row to a registry Spec. Returns nil for rows that haven't
    /// completed their download yet (ggufPath == nil) — we don't want spawn-
    /// sites trying to redirect to a model whose GGUF doesn't exist on disk.
    private static func specFromRow(_ row: InstalledChatModel) -> LocalChatModelRegistry.Spec? {
        guard let path = row.ggufPath,
              let url = URL(string: row.sourceURL) else { return nil }
        _ = path  // the binary spec needs only enough info to re-resolve; provisioner
                  // hits its cache by name-version naming
        let binary = ephemeralBinary(id: row.id, modelName: row.modelName,
                                     sourceURL: url, sha256: row.sha256)
        return LocalChatModelRegistry.Spec(
            modelName: row.modelName,
            displayName: row.displayName,
            binary: binary,
            port: row.port
        )
    }

    /// Build a `ManagedBinary` spec for a user-installed model. The provisioner
    /// caches by `<name>-<version>`; we use the install row's id as the version
    /// so two installs of the same modelName (theoretically impossible due to
    /// the uniqueness check, but defensive) wouldn't collide on disk.
    private static func ephemeralBinary(
        id: String, modelName: String, sourceURL: URL, sha256: String?
    ) -> ManagedBinary {
        let source = ManagedBinary.Source(url: sourceURL, sha256: sha256, packaging: .rawBinary)
        return ManagedBinary(
            name: modelName,
            version: "user-\(id.prefix(8))",
            systemPaths: [],
            sources: [.arm64: source, .x86_64: source]
        )
    }

    /// modelName goes into the `--model` CLI arg and the `local/<name>` UI
    /// prefix, so keep it shell-safe and URL-segment-safe: lowercase ASCII,
    /// digits, hyphen, dot. No spaces, no slashes.
    private static func isValidModelName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
