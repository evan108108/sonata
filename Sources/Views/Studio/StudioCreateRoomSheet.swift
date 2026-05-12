import Foundation
import SwiftUI

struct StudioCreateRoomSheet: View {
    @ObservedObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss

    /// Notify the parent when create succeeds. Carries the slug + final
    /// title so the sidebar can preselect the row and surface the
    /// profile-picker sheet for the newly-founded room.
    var onCreated: ((_ slug: String, _ title: String) -> Void)? = nil

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var tracks: [DraftTrack] = [DraftTrack(title: "General")]

    @State private var isSubmitting: Bool = false
    @State private var submitError: String?

    private static let slugRegex = #"^[A-Za-z0-9-]{2,64}$"#
    private static let trackNameRegex = #"^[A-Za-z0-9-]{1,64}$"#
    private static let titleMax = 200
    private static let descriptionMax = 2000

    private var derivedSlug: String { Self.slugify(title) }

    private var slugIsValid: Bool {
        derivedSlug.range(of: Self.slugRegex, options: .regularExpression) != nil
    }

    private var titleIsValid: Bool {
        !title.isEmpty && title.count <= Self.titleMax
    }

    private var descriptionIsValid: Bool {
        description.count <= Self.descriptionMax
    }

    private var tracksAreValid: Bool {
        !tracks.isEmpty && tracks.allSatisfy { t in
            let derived = Self.slugify(t.title)
            return derived.range(of: Self.trackNameRegex, options: .regularExpression) != nil
                && !t.title.isEmpty
                && t.title.count <= Self.titleMax
        }
    }

    private var tracksHaveUniqueNames: Bool {
        let names = tracks.map { Self.slugify($0.title) }
        return Set(names).count == names.count
    }

    private var formIsValid: Bool {
        slugIsValid && titleIsValid && descriptionIsValid && tracksAreValid && tracksHaveUniqueNames
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
            } else if !title.isEmpty && !slugIsValid {
                Text("Slug \"\(derivedSlug)\" is invalid — needs 2-64 letters/digits/hyphens. Try a longer title.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if !title.isEmpty {
                Text("Slug: \(derivedSlug)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Stable slug is derived from the title.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
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
                    tracks.append(DraftTrack(title: ""))
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
            if !tracksHaveUniqueNames {
                Text("Two tracks derive the same slug — give them more distinct titles.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else {
                Text("Each track is a tab inside the room. Slug is derived from the title.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func trackRow(index i: Int) -> some View {
        let isLast = tracks.count == 1
        let derived = Self.slugify(tracks[i].title)
        let derivedIsValid = derived.range(of: Self.trackNameRegex, options: .regularExpression) != nil
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: $tracks[i].title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if !tracks[i].title.isEmpty {
                    Text(derivedIsValid ? "slug: \(derived)" : "slug invalid — add letters or digits")
                        .font(.system(size: 10))
                        .foregroundStyle(derivedIsValid ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Color.red))
                }
            }
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
            (name: Self.slugify($0.title), title: $0.title)
        }
        let trimmedDescription = description.isEmpty ? nil : description

        do {
            let finalSlug = derivedSlug
            let finalTitle = title
            _ = try await store.createRoom(
                slug: finalSlug,
                title: finalTitle,
                description: trimmedDescription,
                defaultTracks: payloadTracks
            )
            isSubmitting = false
            dismiss()
            onCreated?(finalSlug, finalTitle)
        } catch {
            isSubmitting = false
            submitError = "Couldn't create room: \(error.localizedDescription)"
        }
    }

    private static func slugify(_ input: String) -> String {
        let lowered = input.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for scalar in lowered.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-" {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "_" {
                out.unicodeScalars.append("-")
            }
            // everything else dropped
        }
        // collapse runs of hyphens
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        // trim leading / trailing hyphens
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

private struct DraftTrack: Identifiable, Equatable {
    let id: UUID = UUID()
    var title: String
}
