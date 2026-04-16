import Foundation
import Hummingbird

// Phase 2 migration: action definitions for /api/files routes.
// Handler logic duplicated from FileRoutes.swift.

/// Resolve and validate that a requested path stays within ~/.sonata/
/// Returns the absolute file path if safe, nil if it escapes the sandbox.
private func resolveSecurePathForAction(relativePath: String, sonataDir: String) -> String? {
    // Normalize: strip null bytes
    let cleaned = relativePath
        .replacingOccurrences(of: "\0", with: "")
    let fullPath = (sonataDir as NSString).appendingPathComponent(cleaned)
    // Resolve symlinks and .. to get canonical path
    let resolved = (fullPath as NSString).standardizingPath
    // Must start with the sonata dir (no traversal)
    guard resolved.hasPrefix(sonataDir) else { return nil }
    return resolved
}

private struct FileDirsResponse: Encodable {
    let dirs: [FileEntry]
}

let fileActions: [SonataAction] = [

    // GET /api/files/list?dir= — list files in a subdirectory
    SonataAction(
        name: "file_list",
        description: "List entries in a subdirectory of ~/.sonata/.",
        group: "/api/files",
        path: "/list",
        method: .get,
        params: [
            ActionParam("dir", .string, required: true, description: "Subdirectory under ~/.sonata/"),
        ],
        handler: { ctx in
            let dir = try ctx.params.require("dir")
            let fm = FileManager.default
            let sonataDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".sonata").path

            guard let dirPath = resolveSecurePathForAction(relativePath: dir, sonataDir: sonataDir) else {
                throw ActionError.custom("Invalid directory path", .forbidden)
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
                return FileListResponse(directory: dir, files: [])
            }

            var entries: [FileEntry] = []
            if let items = try? fm.contentsOfDirectory(atPath: dirPath) {
                for item in items.sorted() {
                    if item.hasPrefix(".") { continue }  // skip hidden files
                    let itemPath = (dirPath as NSString).appendingPathComponent(item)
                    var itemIsDir: ObjCBool = false
                    fm.fileExists(atPath: itemPath, isDirectory: &itemIsDir)
                    let attrs = (try? fm.attributesOfItem(atPath: itemPath)) ?? [:]
                    let size = (attrs[.size] as? Int64) ?? 0
                    let modified = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
                    entries.append(FileEntry(
                        name: item,
                        path: dir + "/" + item,
                        isDirectory: itemIsDir.boolValue,
                        size: size,
                        modified: Int64(modified)
                    ))
                }
            }

            return FileListResponse(directory: dir, files: entries)
        }
    ),

    // GET /api/files/read?path= — read file content
    SonataAction(
        name: "file_read",
        description: "Read a UTF-8 file under ~/.sonata/.",
        group: "/api/files",
        path: "/read",
        method: .get,
        params: [
            ActionParam("path", .string, required: true, description: "File path under ~/.sonata/"),
        ],
        handler: { ctx in
            let path = try ctx.params.require("path")
            let fm = FileManager.default
            let sonataDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".sonata").path

            guard let filePath = resolveSecurePathForAction(relativePath: path, sonataDir: sonataDir) else {
                throw ActionError.custom("Invalid file path", .forbidden)
            }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else {
                throw ActionError.notFound("File not found")
            }

            let attrs = (try? fm.attributesOfItem(atPath: filePath)) ?? [:]
            let size = (attrs[.size] as? Int64) ?? 0
            let modified = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000

            guard let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8) else {
                throw ActionError.custom("Could not read file (binary or encoding error)", .badRequest)
            }

            return FileReadResponse(
                path: path,
                content: content,
                size: size,
                modified: Int64(modified)
            )
        }
    ),

    // GET /api/files/dirs — list top-level browsable directories
    SonataAction(
        name: "file_dirs",
        description: "List top-level browsable directories under ~/.sonata/.",
        group: "/api/files",
        path: "/dirs",
        method: .get,
        params: [],
        handler: { _ in
            let fm = FileManager.default
            let sonataDir = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(".sonata").path

            var dirs: [FileEntry] = []
            if let items = try? fm.contentsOfDirectory(atPath: sonataDir) {
                for item in items.sorted() {
                    if item.hasPrefix(".") { continue }
                    let itemPath = (sonataDir as NSString).appendingPathComponent(item)
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: itemPath, isDirectory: &isDir)
                    if isDir.boolValue {
                        dirs.append(FileEntry(
                            name: item,
                            path: item,
                            isDirectory: true,
                            size: 0,
                            modified: 0
                        ))
                    }
                }
            }
            return FileDirsResponse(dirs: dirs)
        }
    ),
]
