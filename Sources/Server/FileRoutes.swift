import Foundation
import Hummingbird

// MARK: - File Browsing Routes

struct FileEntry: Encodable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modified: Int64  // ms since epoch
}

struct FileListResponse: Encodable {
    let directory: String
    let files: [FileEntry]
}

struct FileReadResponse: Encodable {
    let path: String
    let content: String
    let size: Int64
    let modified: Int64
}

/// Resolve and validate that a requested path stays within ~/.sonata/
/// Returns the absolute file path if safe, nil if it escapes the sandbox.
private func resolveSecurePath(relativePath: String, sonataDir: String) -> String? {
    // Normalize: strip leading slashes, collapse path
    let cleaned = relativePath
        .replacingOccurrences(of: "\0", with: "")  // null byte injection
    let fullPath = (sonataDir as NSString).appendingPathComponent(cleaned)
    // Resolve symlinks and .. to get canonical path
    let resolved = (fullPath as NSString).standardizingPath
    // Must start with the sonata dir (no traversal)
    guard resolved.hasPrefix(sonataDir) else { return nil }
    return resolved
}

public func registerFileRoutes(
    on router: Router<some RequestContext>
) {
    let fm = FileManager.default
    let sonataDir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(".sonata").path

    let api = router.group("/api/files")

    // GET /api/files/list?dir=private — list files in a subdirectory
    api.get("/list") { request, _ -> Response in
        guard let dir = request.uri.queryParameters.get("dir"),
              !dir.isEmpty else {
            return errorResponse("Missing 'dir' parameter")
        }

        guard let dirPath = resolveSecurePath(relativePath: dir, sonataDir: sonataDir) else {
            return errorResponse("Invalid directory path", status: .forbidden)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
            return jsonResponse(FileListResponse(directory: dir, files: []))
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

        return jsonResponse(FileListResponse(directory: dir, files: entries))
    }

    // GET /api/files/read?path=private/journal.md — read file content
    api.get("/read") { request, _ -> Response in
        guard let path = request.uri.queryParameters.get("path"),
              !path.isEmpty else {
            return errorResponse("Missing 'path' parameter")
        }

        guard let filePath = resolveSecurePath(relativePath: path, sonataDir: sonataDir) else {
            return errorResponse("Invalid file path", status: .forbidden)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else {
            return errorResponse("File not found", status: .notFound)
        }

        let attrs = (try? fm.attributesOfItem(atPath: filePath)) ?? [:]
        let size = (attrs[.size] as? Int64) ?? 0
        let modified = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000

        guard let data = fm.contents(atPath: filePath),
              let content = String(data: data, encoding: .utf8) else {
            return errorResponse("Could not read file (binary or encoding error)")
        }

        return jsonResponse(FileReadResponse(
            path: path,
            content: content,
            size: size,
            modified: Int64(modified)
        ))
    }

    // GET /api/files/dirs — list top-level browsable directories
    api.get("/dirs") { _, _ -> Response in
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
        return jsonResponse(["dirs": dirs])
    }
}
