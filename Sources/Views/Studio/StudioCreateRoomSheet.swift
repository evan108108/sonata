import Foundation
import SwiftUI

struct StudioCreateRoomSheet: View {
    @ObservedObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss

    @State private var slug: String = ""
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var tracks: [DraftTrack] = [DraftTrack(name: "general", title: "General")]

    @State private var isSubmitting: Bool = false
    @State private var submitError: String?

    private static let slugRegex = #"^[A-Za-z0-9-]{2,64}$"#
    private static let trackNameRegex = #"^[A-Za-z0-9-]{1,64}$"#
    private static let titleMax = 200
    private static let descriptionMax = 2000

    private var slugIsValid: Bool {
        slug.range(of: Self.slugRegex, options: .regularExpression) != nil
    }

    private var titleIsValid: Bool {
        !title.isEmpty && title.count <= Self.titleMax
    }

    private var descriptionIsValid: Bool {
        description.count <= Self.descriptionMax
    }

    private var tracksAreValid: Bool {
        !tracks.isEmpty && tracks.allSatisfy { t in
            t.name.range(of: Self.trackNameRegex, options: .regularExpression) != nil
                && !t.title.isEmpty
                && t.title.count <= Self.titleMax
        }
    }

    private var formIsValid: Bool {
        slugIsValid && titleIsValid && descriptionIsValid && tracksAreValid
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    slugField
                    titleField
                    descriptionField
                    tracksField
                    if let err = submitError {
                        errorBanner(err)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text("New Room")
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var slugField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Slug")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("acme-leads", text: $slug)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .disableAutocorrection(true)
            if !slug.isEmpty && !slugIsValid {
                Text("Slug must be 2-64 chars: letters, digits, hyphens only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                Text("Stable identifier used in URLs and dispatch envelopes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Title")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(title.count)/\(Self.titleMax)")
                    .font(.system(size: 10))
                    .foregroundStyle(title.count > Self.titleMax ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            TextField("Acme Lead Discovery", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onChange(of: title) { _, new in
                    if new.count > Self.titleMax {
                        title = String(new.prefix(Self.titleMax))
                    }
                }
            if !title.isEmpty && !titleIsValid {
                Text("Title must be 1-200 characters.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Description")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(optional)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(description.count)/\(Self.descriptionMax)")
                    .font(.system(size: 10))
                    .foregroundStyle(description.count > Self.descriptionMax ? AnyShapeStyle(Color.red) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            TextEditor(text: $description)
                .font(.system(size: 12))
                .frame(minHeight: 72, maxHeight: 120)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .onChange(of: description) { _, new in
                    if new.count > Self.descriptionMax {
                        description = String(new.prefix(Self.descriptionMax))
                    }
                }
            if !descriptionIsValid {
                Text("Description must be ≤ 2000 characters.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var tracksField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Default tracks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    tracks.append(DraftTrack(name: "", title: ""))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Add track")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            VStack(spacing: 6) {
                ForEach(tracks.indices, id: \.self) { i in
                    trackRow(index: i)
                }
            }
            Text("Each track is a tab inside the room. Track names accept letters, digits, hyphens.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func trackRow(index i: Int) -> some View {
        let isLast = tracks.count == 1
        return HStack(spacing: 6) {
            TextField("name", text: $tracks[i].name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 120)
                .disableAutocorrection(true)
            TextField("Title", text: $tracks[i].title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            Button {
                tracks.remove(at: i)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(isLast ? .tertiary : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isLast)
            .help(isLast ? "At least one track required" : "Remove track")
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.red)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSubmitting)

            Button {
                Task { await submit() }
            } label: {
                HStack(spacing: 6) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isSubmitting ? "Creating…" : "Create")
                }
                .frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!formIsValid || isSubmitting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func submit() async {
        guard formIsValid, !isSubmitting else { return }
        isSubmitting = true
        submitError = nil

        let payloadTracks: [(name: String, title: String)] = tracks.map {
            (name: $0.name, title: $0.title)
        }
        let trimmedDescription = description.isEmpty ? nil : description

        do {
            _ = try await store.createRoom(
                slug: slug,
                title: title,
                description: trimmedDescription,
                defaultTracks: payloadTracks
            )
            isSubmitting = false
            dismiss()
        } catch {
            isSubmitting = false
            submitError = "Couldn't create room: \(error.localizedDescription)"
        }
    }
}

private struct DraftTrack: Identifiable, Equatable {
    let id: UUID = UUID()
    var name: String
    var title: String
}
