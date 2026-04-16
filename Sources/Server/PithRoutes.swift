import Foundation
import Hummingbird
import GRDB

// MARK: - Request / Response Types

struct PithRequest: Decodable {
    let text: String
    let maxLength: Int?
}

struct PithResponse: Encodable {
    let compressed: String
}
