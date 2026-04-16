import Foundation
import GRDB
import Hummingbird

// Phase 2 migration: action definition for /api/pith route.
// Handler logic is duplicated from PithRoutes.swift so the two implementations
// run side-by-side. When the old routes are retired this becomes canonical.
// Reuses `PithResponse` declared in PithRoutes.swift.

let pithActions: [SonataAction] = [

    // POST /api/pith — compress text via LLM (OpenRouter)
    SonataAction(
        name: "pith_generate",
        description: "Compress text via LLM (OpenRouter) to at most maxLength characters while preserving key information.",
        group: "/api",
        path: "/pith",
        method: .post,
        params: [
            ActionParam("text", .string, required: true, description: "Text to compress"),
            ActionParam("maxLength", .integer, description: "Maximum character length (default 280)"),
        ],
        handler: { ctx in
            let text = try ctx.params.require("text")
            guard !text.isEmpty else {
                throw ActionError.invalidParam("text", "must not be empty")
            }

            let maxLen = ctx.params.int("maxLength") ?? 280
            guard let apiKey = SecretStore.get("OPENROUTER_API_KEY"), !apiKey.isEmpty else {
                throw ActionError.custom("OPENROUTER_API_KEY not set", .internalServerError)
            }

            let systemPrompt = "You are a text compressor. Compress the user's text to at most \(maxLen) characters while preserving all key information. Return ONLY the compressed text, nothing else."

            // Build OpenRouter request
            let payload: [String: Any] = [
                "model": "openai/gpt-4o-mini",
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": text]
                ],
                "max_tokens": maxLen * 2
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
                throw ActionError.custom("Failed to encode LLM request", .internalServerError)
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
                    throw ActionError.custom("OpenRouter returned \(statusCode): \(body)", .internalServerError)
                }

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String
                else {
                    throw ActionError.custom("Unexpected LLM response format", .internalServerError)
                }

                return PithResponse(compressed: content.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let e as ActionError {
                throw e
            } catch {
                throw ActionError.custom("LLM request failed: \(error.localizedDescription)", .internalServerError)
            }
        }
    ),
]
