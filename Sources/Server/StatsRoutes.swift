import Foundation
import Hummingbird
import GRDB

// MARK: - Response Types

struct StatsResponse: Encodable {
    let totalMemories: Int
    let avgImportance: Double
    let byType: [String: Int]
    let entityCount: Int
    let relationCount: Int
}
