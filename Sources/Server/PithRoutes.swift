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

// MARK: - Route Registration

public func registerPithRoutes(
    on router: Router<some RequestContext>,
    dbPool: DatabasePool
) {
    // POST /api/pith — compress text via LLM (OpenRouter)
    router.post("/api/pith") { request, context -> Response in
        let body: PithRequest
        do {
            body = try await request.decode(as: PithRequest.self, context: context)
        } catch {
            return errorResponse("Invalid request body: \(error.localizedDescription)")
        }

        guard !body.text.isEmpty else {
            return errorResponse("'text' must not be empty")
        }

        let maxLen = body.maxLength ?? 280
        let apiKey = SecretStore.get("OPENROUTER_API_KEY") ?? ""
        guard !apiKey.isEmpty else {
            return errorResponse("OPENROUTER_API_KEY not set", status: .internalServerError)
        }

        let systemPrompt = "You are a text compressor. Compress the user's text to at most \(maxLen) characters while preserving all key information. Return ONLY the compressed text, nothing else."

        // Build OpenRouter request
        let payload: [String: Any] = [
            "model": "openai/gpt-4o-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": body.text]
            ],
            "max_tokens": maxLen * 2
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            return errorResponse("Failed to encode LLM request", status: .internalServerError)
        }

        var urlRequest = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = jsonData

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                return errorResponse("OpenRouter returned \(statusCode): \(body)", status: .internalServerError)
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                return errorResponse("Unexpected LLM response format", status: .internalServerError)
            }

            return jsonResponse(PithResponse(compressed: content.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            return errorResponse("LLM request failed: \(error.localizedDescription)", status: .internalServerError)
        }
    }
}
