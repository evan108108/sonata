import Foundation
import GRDB
import Hummingbird

// MARK: - Request Bodies

struct SupervisorQueryRequest: Decodable {
    let message: String
    let context: String?
}

struct SupervisorRespondRequest: Decodable {
    let messageId: String?
    let response: String
    let actions: [String]?
}

struct SupervisorReportRequest: Decodable {
    let summary: String
    let actions: [String]?
    let issuesFound: Int?
}

struct SupervisorAlertRequest: Decodable {
    let title: String
    let detail: String
    let severity: String?
    let relatedTaskIds: [String]?
}

struct SupervisorHeartbeatRequest: Decodable {
    let sessionId: String?
}
