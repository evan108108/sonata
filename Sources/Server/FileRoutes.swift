import Foundation
import Hummingbird

// MARK: - File Browsing Types

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
