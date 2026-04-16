import Foundation
import Hummingbird

// MARK: - Request Bodies

struct SetSecretRequest: Decodable {
    let name: String
    let value: String
    let description: String?
}

// MARK: - Response Types

struct SecretListItem: Encodable {
    let name: String
    let description: String
}

struct SecretValueResponse: Encodable {
    let name: String
    let value: String
}

struct SecretActionResponse: Encodable {
    let success: Bool
    let name: String
}
