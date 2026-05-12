import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// Small async-loaded circular avatar for a Studio member. Loads via the
/// shared `StudioStore.avatarImage(for:in:)` pipeline; falls back to a
/// `person.crop.circle.fill` SF Symbol when the member has no avatar block
/// or the fetch fails. Reload-on-change is keyed on `roomSlug|pubkeyHex` plus
/// the sha256 of the underlying block (so a profile re-publish swaps in the
/// new image without leaving the prior CGImage stuck behind).
struct StudioAvatarView: View {
    let store: StudioStore
    let pubkeyHex: String
    let roomSlug: String?
    var diameter: CGFloat = 20

    @State private var image: CGImage? = nil

    var body: some View {
        Group {
            if let cg = image {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .task(id: reloadKey) { await load() }
    }

    private var reloadKey: String {
        guard let room = roomSlug, !room.isEmpty else { return "no-room|\(pubkeyHex)" }
        let member = store.roomMembers["\(room)|\(pubkeyHex.lowercased())"]
        let sha = member?.avatarImageBlock?.sha256 ?? ""
        return "\(room)|\(pubkeyHex.lowercased())|\(sha)"
    }

    private func load() async {
        guard let room = roomSlug, !room.isEmpty else {
            await MainActor.run { image = nil }
            return
        }
        let result = await store.avatarImage(for: pubkeyHex, in: room)
        await MainActor.run { image = result }
    }
}

/// File-picker helper that drives both Settings and the per-room profile
/// picker. Re-encodes the user's pick as a JPEG under NIP-44's 60 KiB ceiling
/// (so the room-publish path can encrypt in one shot) and writes the result
/// into a stable, app-owned directory under
/// `~/Library/Application Support/Sonata/avatars/`. The compose sheet's
/// `~/Library/Caches/com.sonata` defer-cleanup would clobber files placed
/// there, so we deliberately use Application Support instead.
enum StudioAvatarPicker {
    /// Reveal an NSOpenPanel and, on confirm, recompress the chosen image
    /// into the avatars dir. Returns the absolute path on success, nil on
    /// cancel, throws `StudioAvatarPickerError` on read/encode/write failure.
    static func pickAndStage() throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .heif]
        panel.title = "Choose avatar image"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64, size > 100 * 1024 * 1024 {
            throw StudioAvatarPickerError.sourceTooLarge
        }
        guard let nsImage = NSImage(contentsOf: url) else {
            throw StudioAvatarPickerError.unreadable
        }
        guard let jpeg = encodeJPEGFittingForAvatar(image: nsImage, maxBytes: 60 * 1024) else {
            throw StudioAvatarPickerError.uncompressable
        }

        let dir = try avatarsDirectory()
        let dest = dir.appendingPathComponent("\(UUID().uuidString).jpg")
        try jpeg.write(to: dest, options: Data.WritingOptions.atomic)
        return dest.path
    }

    /// Resolve (and create on first use) the directory that holds avatar
    /// source images. Stable across launches; survives compose-sheet
    /// cleanup; lives under Application Support so macOS treats it as app
    /// data rather than disposable cache.
    static func avatarsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base
            .appendingPathComponent("Sonata", isDirectory: true)
            .appendingPathComponent("avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

enum StudioAvatarPickerError: LocalizedError {
    case sourceTooLarge
    case unreadable
    case uncompressable

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge: return "Image source is larger than 100 MiB."
        case .unreadable: return "Couldn't read image file."
        case .uncompressable: return "Couldn't compress avatar under 60 KiB (NIP-44 v2 plaintext cap)."
        }
    }
}

/// JPEG re-encoder for avatar staging. Mirrors `StudioComposeSheet`'s
/// `encodeJPEGFitting` (kept duplicated because the compose-sheet variant
/// is a View-scoped static and can't be referenced from a non-View call
/// site cleanly across files). Same descent ladder; same target ≤ 60 KiB
/// for NIP-44 v2's plaintext ceiling.
private func encodeJPEGFittingForAvatar(image: NSImage, maxBytes: Int) -> Data? {
    let maxDimensions: [CGFloat] = [512, 320, 256, 192, 128]
    let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4, 0.25, 0.1]
    for dim in maxDimensions {
        guard let scaled = avatarDownscale(image: image, longestEdge: dim) else { continue }
        for q in qualities {
            guard let data = avatarJpegEncode(image: scaled, quality: q) else { continue }
            if data.count <= maxBytes { return data }
        }
    }
    return nil
}

private func avatarDownscale(image: NSImage, longestEdge: CGFloat) -> NSImage? {
    let srcSize = image.size
    guard srcSize.width > 0, srcSize.height > 0 else { return nil }
    let longest = max(srcSize.width, srcSize.height)
    if longest <= longestEdge { return image }
    let scale = longestEdge / longest
    let newSize = NSSize(width: floor(srcSize.width * scale), height: floor(srcSize.height * scale))
    let out = NSImage(size: newSize)
    out.lockFocus()
    defer { out.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(
        in: NSRect(origin: .zero, size: newSize),
        from: NSRect(origin: .zero, size: srcSize),
        operation: .copy,
        fraction: 1.0
    )
    return out
}

private func avatarJpegEncode(image: NSImage, quality: CGFloat) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
}

/// Larger preview helper for the Settings and profile-picker panes. Loads
/// from a local filesystem path (the user's chosen avatar source) rather
/// than the room-encrypted block. Falls back to a placeholder if the file
/// has been moved or deleted out from under us.
struct StudioLocalAvatarPreview: View {
    let path: String?
    var diameter: CGFloat = 56

    var body: some View {
        Group {
            if let p = path, !p.isEmpty,
               FileManager.default.fileExists(atPath: p),
               let img = NSImage(contentsOfFile: p) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}
