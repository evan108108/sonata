import AppKit
import Foundation
import SwiftUI

/// Founder-only "Invite people…" sheet. Mints a fresh invite URL the first
/// time it opens, shows the `https_url` form (more shareable across apps),
/// and offers a Copy + Generate-new affordance. TTL is the plugin's 7-day
/// default; "Generate new" re-invokes the action without changing the TTL.
struct StudioInviteSheet: View {
    @ObservedObject var store: StudioStore
    let roomSlug: String
    let roomTitle: String
    @Environment(\.dismiss) private var dismiss

    @State private var invite: StudioInviteResponse?
    @State private var isLoading: Bool = false
    @State private var loadError: String?
    @State private var didCopy: Bool = false
    /// Which URL form to display + copy. `.s4a` is the native scheme
    /// (`s4a://invite/...`) that opens Sonata directly via the registered
    /// CFBundleURLTypes handler. `.https` is the web fallback shape, useful
    /// when the invitee doesn't have Sonata installed (lands on a 4a4.ai
    /// page documenting Sonata; one-click on the same machine still opens
    /// Sonata via LaunchServices). Default to `.s4a` so the click-to-open
    /// path is the first-class choice.
    @State private var urlForm: URLForm = .s4a

    private enum URLForm: String, CaseIterable, Identifiable {
        case s4a, https
        var id: String { rawValue }
        var label: String {
            switch self {
            case .s4a: return "s4a://"
            case .https: return "https://"
            }
        }
    }

    private static let defaultTTLSeconds: Int = 7 * 24 * 60 * 60

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520)
        .onAppear {
            if invite == nil && !isLoading {
                Task { await fetchInvite() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("Invite people to \"\(displayRoomName)\"")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var displayRoomName: String {
        roomTitle.isEmpty ? roomSlug : roomTitle
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy this link and share it with whoever you want to invite. They open it inside Sonata Studio to join.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let invite {
                urlRow(invite: invite)
                HStack(spacing: 10) {
                    Text(expirationLine(invite: invite))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await fetchInvite() }
                    } label: {
                        HStack(spacing: 4) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Generate new")
                        }
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoading)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Minting invite…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else if let loadError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Text(loadError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Button("Retry") { Task { await fetchInvite() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private func urlRow(invite: StudioInviteResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $urlForm) {
                ForEach(URLForm.allCases) { form in
                    Text(form.label).tag(form)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .onChange(of: urlForm) { _, _ in didCopy = false }

            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(displayedURL(for: invite))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )
                Button {
                    copy(displayedURL(for: invite))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        Text(didCopy ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11))
                    .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
            }

            if urlForm == .s4a {
                Text("Clicking s4a:// opens Sonata directly via the system URL handler.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("https:// is a web fallback for invitees who don't have Sonata yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func displayedURL(for invite: StudioInviteResponse) -> String {
        switch urlForm {
        case .s4a: return invite.s4aUrl
        case .https: return invite.httpsUrl
        }
    }

    private func expirationLine(invite: StudioInviteResponse) -> String {
        let expires = Date(timeIntervalSince1970: TimeInterval(invite.expiresAt))
        let now = Date()
        let delta = expires.timeIntervalSince(now)
        if delta <= 0 { return "Expired" }
        let days = Int(delta / 86_400)
        if days >= 1 {
            return "Expires in \(days) day\(days == 1 ? "" : "s")"
        }
        let hours = Int(delta / 3600)
        if hours >= 1 {
            return "Expires in \(hours) hour\(hours == 1 ? "" : "s")"
        }
        let minutes = max(1, Int(delta / 60))
        return "Expires in \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fetchInvite() async {
        isLoading = true
        loadError = nil
        didCopy = false
        do {
            let resp = try await store.inviteRoom(
                slug: roomSlug,
                ttlSeconds: Self.defaultTTLSeconds
            )
            invite = resp
            isLoading = false
        } catch let err as StudioPluginError {
            isLoading = false
            loadError = err.message
        } catch {
            isLoading = false
            loadError = "Couldn't mint invite: \(error.localizedDescription)"
        }
    }

    private func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopy = false
        }
    }
}
