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

// MARK: - Route Registration

public func registerSecretRoutes(
    on router: Router<some RequestContext>
) {
    let api = router.group("/api/secrets")

    // GET /api/secrets — list all secret names + descriptions (no values)
    api.get("/") { _, _ -> Response in
        let secrets = SecretStore.list()
        let items = secrets.map { SecretListItem(name: $0.name, description: $0.description) }
        return jsonResponse(items)
    }

    // GET /api/secrets/:name — get a single secret's value
    api.get("/:name") { request, _ -> Response in
        // Extract name from path: /api/secrets/AGENTMAIL_API_KEY
        guard let name = request.uri.path.split(separator: "/").last.map(String.init), name != "secrets" else {
            return errorResponse("name required")
        }
        guard let value = SecretStore.get(name) else {
            return errorResponse("secret not found", status: .notFound)
        }
        return jsonResponse(SecretValueResponse(name: name, value: value))
    }

    // POST /api/secrets — set a secret {name, value, description?}
    api.post("/") { request, context -> Response in
        guard let body = try? await request.decode(as: SetSecretRequest.self, context: context) else {
            return errorResponse("Invalid request body — need {name, value}")
        }
        SecretStore.set(name: body.name, value: body.value, description: body.description ?? "")
        return jsonResponse(SecretActionResponse(success: true, name: body.name))
    }

    // DELETE /api/secrets/:name — delete a secret
    api.delete("/:name") { request, _ -> Response in
        guard let name = request.uri.path.split(separator: "/").last.map(String.init), name != "secrets" else {
            return errorResponse("name required")
        }
        let deleted = SecretStore.delete(name)
        return jsonResponse(SecretActionResponse(success: deleted, name: name), status: deleted ? .ok : .notFound)
    }
}
