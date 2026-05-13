// Studio → "Storage settings…" sheet.
//
// Per-room override of the storage backend used by file/image-attach. The
// user picks one of three modes:
//   - Default  → no per-room override; uploads use the user default (or
//                hosted Blossom when no default is configured).
//   - Blossom  → custom Blossom URL for this room.
//   - S3       → BYO S3-compatible bucket (R2, AWS S3, MinIO, Wasabi, B2).
//                Credentials are written to macOS Keychain; the entity
//                attribute only carries Keychain references.
//
// A second "Set as my default" toggle writes the same config to the
// user-wide default (studio:user_profile.default_storage_config) so future
// rooms inherit it without having to set it again.

import SwiftUI

enum StudioStorageMode: String, CaseIterable, Identifiable {
    case useDefault = "default"
    case blossom = "blossom"
    case s3 = "s3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .useDefault: return "Default"
        case .blossom: return "Blossom URL"
        case .s3: return "S3-compatible"
        }
    }
}

/// Inline editor for a single storage config — used both inside the Settings
/// pane (no header, no modal chrome) and wrapped in a sheet for the per-room
/// gear menu. Has no `dismiss()` calls: Save flashes a checkmark and leaves
/// the editor mounted. The sheet wrapper supplies its own Cancel/Done chrome.
struct StudioStorageConfigEditor: View {
    /// Pass nil for "edit the user-wide default"; pass a slug to edit the
    /// per-room override for that room.
    let roomSlug: String?

    /// When true, render an inline title (e.g. when used inside a sheet).
    /// Inline use inside Settings omits it because the surrounding section
    /// already labels the block.
    var showHeader: Bool = false

    @State private var mode: StudioStorageMode = .useDefault
    @State private var blossomURL: String = "https://api.4a4.ai/blossom"

    // S3 fields
    @State private var s3Endpoint: String = ""
    @State private var s3Region: String = "auto"
    @State private var s3Bucket: String = ""
    @State private var s3PathStyle: Bool = true
    @State private var s3AccessKeyId: String = ""
    @State private var s3SecretAccessKey: String = ""

    @State private var setAsDefault: Bool = false

    @State private var testStatus: TestStatus = .idle
    @State private var loading: Bool = true
    @State private var saving: Bool = false
    @State private var savedFlash: Bool = false

    enum TestStatus: Equatable {
        case idle
        case running
        case ok(String)
        case error(String)
    }

    private var isRoomScoped: Bool { roomSlug != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showHeader {
                Text(isRoomScoped
                     ? "Storage settings — room “\(roomSlug ?? "")”"
                     : "Default storage settings")
                    .font(.title2.bold())
            }

            Picker("Backend", selection: $mode) {
                ForEach(StudioStorageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isRoomScoped && mode == .useDefault)
            .frame(maxWidth: 480, alignment: .leading)

            Group {
                switch mode {
                case .useDefault:
                    defaultModeBody
                case .blossom:
                    blossomModeBody
                case .s3:
                    s3ModeBody
                }
            }

            if isRoomScoped, mode != .useDefault {
                Toggle(isOn: $setAsDefault) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also set as my default for new rooms")
                        Text("Future rooms will inherit this storage backend without needing per-room setup.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            testStatusView

            HStack(spacing: 8) {
                Button("Test connection") {
                    Task { await testConnection() }
                }
                .disabled(saving || mode == .useDefault)

                Spacer()

                Button(action: { Task { await save() } }) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else if savedFlash {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || loading)
            }
        }
        .task { await load() }
    }

    // MARK: - Sub-views

    private var defaultModeBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isRoomScoped
                 ? "Uploads from this room use the user-wide default storage backend (or the hosted Blossom server if no default is set)."
                 : "No user-wide default — uploads fall back to the hosted Blossom server at api.4a4.ai/blossom.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isRoomScoped {
                Text("Set the user-wide default in Settings → Studio → Default storage.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var blossomModeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Blossom server URL")
                .font(.subheadline)
            TextField("https://blossom.example.com", text: $blossomURL)
                .textFieldStyle(.roundedBorder)
            Text("Sonata signs uploads with the plugin's keypair (BUD-01 auth event). Any standard Blossom server will accept them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var s3ModeBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Endpoint").gridColumnAlignment(.trailing)
                    TextField("https://<account>.r2.cloudflarestorage.com", text: $s3Endpoint)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Region")
                    TextField("auto", text: $s3Region)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Bucket")
                    TextField("my-studio-files", text: $s3Bucket)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Path style")
                    Toggle(isOn: $s3PathStyle) {
                        Text("Use path-style URLs (R2 requires this; AWS allows it)")
                    }
                    .toggleStyle(.switch)
                }
                GridRow {
                    Text("Access key ID")
                    TextField("AKIA…", text: $s3AccessKeyId)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Secret access key")
                    SecureField("Stored in macOS Keychain", text: $s3SecretAccessKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            publicReadNotice
        }
    }

    private var publicReadNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("⚠ Bucket must allow public reads for other room members to download attachments.")
                .font(.callout.weight(.medium))
            Text("Encryption keeps content private — the bucket URL just hosts opaque ciphertext. Other room members don't have your S3 credentials, so they need to fetch via the bucket's public-read URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("R2: Bucket settings → Public access → enable r2.dev.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("AWS S3: Permissions → Bucket policy → allow s3:GetObject for principal=\"*\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var testStatusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .error(let detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Behavior

    private func load() async {
        loading = true
        defer { loading = false }
        if let slug = roomSlug {
            // Try room override first; fall through to user default for display.
            do {
                let resp: StudioStorageGetResponse = try await EntityHTTP.postPluginAction(
                    path: "sonata-studio/storage/config/get",
                    body: ["room": slug]
                )
                applyLoaded(resp.storage_config, fallback: resp.default_storage_config)
            } catch {
                NSLog("[StorageSettings] storage/config/get failed: \(error)")
            }
        } else {
            do {
                let resp: StudioDefaultStorageGetResponse = try await EntityHTTP.getPluginAction(
                    path: "sonata-studio/storage/default/get"
                )
                applyLoaded(resp.default_storage_config, fallback: nil)
            } catch {
                NSLog("[StorageSettings] storage/default/get failed: \(error)")
            }
        }
    }

    private func applyLoaded(_ override: StudioStorageConfig?, fallback: StudioStorageConfig?) {
        if let cfg = override {
            applyToFields(cfg)
        } else if let cfg = fallback {
            // Pre-populate fields from the default but keep mode = useDefault
            // so saving doesn't accidentally pin a per-room override.
            applyToFields(cfg)
            mode = .useDefault
        } else {
            mode = .useDefault
        }
    }

    private func applyToFields(_ cfg: StudioStorageConfig) {
        switch cfg.kind {
        case "blossom":
            mode = .blossom
            blossomURL = cfg.blossom_url ?? "https://api.4a4.ai/blossom"
        case "s3":
            mode = .s3
            s3Endpoint = cfg.s3_endpoint ?? ""
            s3Region = cfg.s3_region ?? "auto"
            s3Bucket = cfg.s3_bucket ?? ""
            s3PathStyle = cfg.s3_path_style ?? true
            // Load Keychain creds when refs are present
            let scope = roomSlug.map { StudioKeychain.roomAccessKeyAccount(roomSlug: $0) }
                ?? StudioKeychain.defaultAccessKeyAccount()
            let scopeSecret = roomSlug.map { StudioKeychain.roomSecretAccount(roomSlug: $0) }
                ?? StudioKeychain.defaultSecretAccount()
            s3AccessKeyId = StudioKeychain.readSecret(account: scope) ?? ""
            s3SecretAccessKey = StudioKeychain.readSecret(account: scopeSecret) ?? ""
        default:
            mode = .useDefault
        }
    }

    private func buildConfigPayload() -> [String: Any]? {
        switch mode {
        case .useDefault:
            return nil
        case .blossom:
            let trimmed = blossomURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ["kind": "blossom", "blossom_url": trimmed]
        case .s3:
            return ["kind": "s3",
                    "s3_endpoint": s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                    "s3_region": s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
                    "s3_bucket": s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                    "s3_path_style": s3PathStyle,
                    "s3_access_key_id_keychain_ref": accessKeyAccount(),
                    "s3_secret_access_key_keychain_ref": secretAccount()]
        }
    }

    private func accessKeyAccount() -> String {
        if let slug = roomSlug { return StudioKeychain.roomAccessKeyAccount(roomSlug: slug) }
        return StudioKeychain.defaultAccessKeyAccount()
    }

    private func secretAccount() -> String {
        if let slug = roomSlug { return StudioKeychain.roomSecretAccount(roomSlug: slug) }
        return StudioKeychain.defaultSecretAccount()
    }

    private func writeKeychainSecretsIfNeeded() throws {
        guard mode == .s3 else { return }
        try StudioKeychain.storeSecret(s3AccessKeyId, account: accessKeyAccount())
        try StudioKeychain.storeSecret(s3SecretAccessKey, account: secretAccount())
    }

    private func testConnection() async {
        testStatus = .running
        do {
            try writeKeychainSecretsIfNeeded()
        } catch {
            testStatus = .error("Keychain write failed: \(error)")
            return
        }
        guard let payload = buildConfigPayload() else {
            testStatus = .error("Pick a backend first.")
            return
        }
        var body: [String: Any] = ["config": payload]
        if mode == .s3 {
            body["credentials"] = [
                "access_key_id": s3AccessKeyId,
                "secret_access_key": s3SecretAccessKey
            ]
        }
        do {
            let raw = try await EntityHTTP.postPluginActionRawDict(
                path: "sonata-studio/storage/test",
                body: body
            )
            let ok = (raw["ok"] as? Bool) ?? false
            let detail = (raw["detail"] as? String) ?? ""
            testStatus = ok ? .ok(detail) : .error(detail)
        } catch let err as StudioPluginError {
            testStatus = .error("\(err.code): \(err.message)")
        } catch {
            testStatus = .error("\(error)")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try writeKeychainSecretsIfNeeded()
        } catch {
            testStatus = .error("Keychain write failed: \(error)")
            return
        }

        let payload = buildConfigPayload()
        // ANSWER body shape: { room?, config: <payload>|null }
        do {
            if let slug = roomSlug {
                var body: [String: Any] = ["room": slug]
                body["config"] = payload as Any? ?? NSNull()
                let _ = try await EntityHTTP.postPluginActionRawDict(
                    path: "sonata-studio/storage/config/set",
                    body: body
                )
                if setAsDefault, payload != nil {
                    var defBody: [String: Any] = [:]
                    defBody["config"] = payload!
                    let _ = try await EntityHTTP.postPluginActionRawDict(
                        path: "sonata-studio/storage/default/set",
                        body: defBody
                    )
                }
            } else {
                var defBody: [String: Any] = [:]
                defBody["config"] = payload as Any? ?? NSNull()
                let _ = try await EntityHTTP.postPluginActionRawDict(
                    path: "sonata-studio/storage/default/set",
                    body: defBody
                )
            }
            savedFlash = true
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            savedFlash = false
        } catch let err as StudioPluginError {
            testStatus = .error("Save failed: \(err.code) \(err.message)")
        } catch {
            testStatus = .error("Save failed: \(error)")
        }
    }
}

/// Modal sheet wrapper used by the per-room gear menu. Wraps the inline
/// editor in the same 540pt frame the previous design used and adds a Cancel
/// button so the user can close without saving. Settings → Studio uses the
/// editor directly without this wrapper.
struct StudioStorageSettingsSheet: View {
    let roomSlug: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StudioStorageConfigEditor(roomSlug: roomSlug, showHeader: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}

// MARK: - Wire types

struct StudioStorageConfig: Codable, Equatable {
    let kind: String
    let blossom_url: String?
    let s3_endpoint: String?
    let s3_region: String?
    let s3_bucket: String?
    let s3_path_style: Bool?
    let s3_access_key_id_keychain_ref: String?
    let s3_secret_access_key_keychain_ref: String?
}

struct StudioStorageGetResponse: Decodable {
    let storage_config: StudioStorageConfig?
    let default_storage_config: StudioStorageConfig?
    let effective: StudioStorageConfig?
    let source: String
}

struct StudioDefaultStorageGetResponse: Decodable {
    let default_storage_config: StudioStorageConfig?
}
