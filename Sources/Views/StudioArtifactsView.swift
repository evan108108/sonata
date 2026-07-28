import SwiftUI
import AppKit

/// Manage-only panel for Public Artifacts (Settings → Studio). Lists what
/// this Sonata has published to api.4a4.ai via `studio_artifact_list`,
/// offers copy/open/revoke per row, and a read-only detail sheet.
/// Publishing is Sona-invoked (`studio_artifact_publish` over MCP) — there
/// is deliberately no publish form here. Modeled on WebhookRoutesView.
struct StudioArtifactsView: View {
    @StateObject private var vm = StudioArtifactsViewModel()
    @State private var detail: StudioArtifactItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ArtifactFilterChip(label: "Personal", selected: true)
                ArtifactFilterChip(label: "Room · v2", selected: false, disabled: true)
                    .help("Room-qualified artifacts are v2 — coming after real multi-room usage lands.")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if vm.artifacts.isEmpty && vm.error == nil {
                VStack(spacing: 12) {
                    Image(systemName: "shippingbox.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No public artifacts yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Ask Sona to \u{201C}publish this as a public artifact\u{201D} — published dashboards, reports, and images show up here with their shareable URLs.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.artifacts) { artifact in
                        StudioArtifactRow(
                            artifact: artifact,
                            onCopy: { vm.copyURL($0) },
                            onOpen: { vm.openInBrowser($0) },
                            onShowDetail: { detail = artifact },
                            onRevoke: {
                                Task { _ = await vm.revoke(dTag: artifact.dTag) }
                            }
                        )
                        Divider()
                    }
                }
            }

            if let err = vm.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .sheet(item: $detail) { artifact in
            StudioArtifactDetailSheet(artifact: artifact, vm: vm)
        }
        .task { await vm.fetch() }
    }
}

// MARK: - Filter chip

private struct ArtifactFilterChip: View {
    let label: String
    let selected: Bool
    var disabled: Bool = false

    var body: some View {
        Text(label)
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                (selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10)),
                in: Capsule()
            )
            .foregroundStyle(disabled ? .tertiary : (selected ? .primary : .secondary))
    }
}

// MARK: - Row

private struct StudioArtifactRow: View {
    let artifact: StudioArtifactItem
    let onCopy: (String) -> Void
    let onOpen: (String) -> Void
    let onShowDetail: () -> Void
    let onRevoke: () -> Void

    @State private var showRevokeConfirm = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.displayTitle)
                    .font(.body.weight(.medium))
                Text(artifact.dTag)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(artifact.contentType)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(Self.relativeFormatter.localizedString(for: artifact.publishedAt, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Published")
                if artifact.revoked {
                    Text("revoked")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                } else if artifact.keyMissing {
                    Text("K missing — republish to restore")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                        .help("The encryption key for this slug is gone from the secret store; the URLs can't be reconstructed. Republishing under the same slug mints a fresh key.")
                }
            }

            // Copy-URL buttons are hidden on revoked rows; the key_missing
            // chip replaces them when the key secret is gone.
            if !artifact.revoked && !artifact.keyMissing {
                Button {
                    copyFrozen()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(artifact.frozenURL == nil)
                .help("Copy frozen URL")
            }

            // The menu stays available on key-missing rows: the artifact is
            // still LIVE on the gateway, and revoking it is exactly what a
            // user who lost the key may need. The copy/open items self-hide
            // via their URL guards.
            if !artifact.revoked {
                Menu {
                    if let frozen = artifact.frozenURL {
                        Button("Copy Frozen URL") { onCopy(frozen) }
                    }
                    if let latest = artifact.latestURL {
                        Button("Copy Latest URL") { onCopy(latest) }
                        Button("Open in Browser") { onOpen(latest) }
                    }
                    Divider()
                    Button("Revoke…", role: .destructive) { showRevokeConfirm = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Button(action: onShowDetail) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Details")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .opacity(artifact.revoked ? 0.55 : 1)
        .alert("Revoke Artifact", isPresented: $showRevokeConfirm) {
            Button("Revoke", role: .destructive) { onRevoke() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Revoke every version published under \u{201C}\(artifact.dTag)\u{201D}? Frozen and latest URLs for all versions of this slug will return 410 Gone within about 30 seconds. This cannot be undone from here; republishing the slug later starts a fresh version.")
        }
    }

    private func copyFrozen() {
        guard let url = artifact.frozenURL else { return }
        onCopy(url)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

// MARK: - Detail Sheet (read-only)

private struct StudioArtifactDetailSheet: View {
    let artifact: StudioArtifactItem
    @ObservedObject var vm: StudioArtifactsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(artifact.displayTitle)
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if artifact.revoked {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "nosign")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(revokedSummary)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                if let reason = artifact.revokedReason, !reason.isEmpty {
                                    Text("Reason: \(reason)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if artifact.keyMissing {
                        HStack(spacing: 8) {
                            Image(systemName: "key.slash")
                                .foregroundStyle(.orange)
                            Text("Encryption key missing from the secret store — URLs can't be reconstructed. Republish under the same slug to mint a fresh key.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    detailRow("Slug", artifact.dTag, monospaced: true)
                    detailRow("Content type", artifact.contentType, monospaced: true)
                    detailRow("Published", Self.dateFormatter.string(from: artifact.publishedAt))
                    if !artifact.pubkey.isEmpty {
                        copyableRow("Signed by", artifact.pubkey)
                    }
                    if let frozen = artifact.frozenURL {
                        copyableRow("Frozen URL", frozen)
                    }
                    if let latest = artifact.latestURL {
                        copyableRow("Latest URL", latest)
                    }
                    copyableRow("SHA-256", artifact.sha256)
                    if !artifact.eventId.isEmpty {
                        copyableRow("Manifest event", artifact.eventId)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 420)
    }

    private var revokedSummary: String {
        if let at = artifact.revokedAt {
            return "Revoked \(Self.dateFormatter.string(from: at)) — URLs return 410 Gone."
        }
        return "Revoked — URLs return 410 Gone."
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
        }
    }

    private func copyableRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                CopyFlashButton(value: value) { vm.copyURL($0) }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

/// Borderless copy button with the 1.5s checkmark flash (WebhookRoutesView
/// copy-URL pattern, extracted because the sheet has several copyable rows).
private struct CopyFlashButton: View {
    let value: String
    let onCopy: (String) -> Void
    @State private var copied = false

    var body: some View {
        Button {
            onCopy(value)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}
