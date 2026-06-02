import Foundation
import GRDB
import Hummingbird

// /api/pith — compress text to roughly maxLength chars via the local chat
// server (Llama 3.1 8B). No external API key required; same input/output
// shape as the legacy OpenRouter-backed implementation it replaced. Reuses
// `PithResponse` declared in PithRoutes.swift.

let pithActions: [SonataAction] = [

    // POST /api/pith — compress text via local llama-server
    SonataAction(
        name: "pith_generate",
        description: "Compress text via the local Llama 3.1 8B chat server to roughly maxLength characters while preserving key information.",
        group: "/api",
        path: "/pith",
        method: .post,
        params: [
            ActionParam("text", .string, required: true, description: "Text to compress"),
            ActionParam("maxLength", .integer, description: "Target character length (default 280)"),
        ],
        handler: { ctx in
            let text = try ctx.params.require("text")
            guard !text.isEmpty else {
                throw ActionError.invalidParam("text", "must not be empty")
            }
            let maxLen = ctx.params.int("maxLength") ?? 280
            do {
                let compressed = try await Pith.compress(text: text, maxLength: maxLen)
                return PithResponse(compressed: compressed)
            } catch {
                throw ActionError.custom("Pith compress failed: \(error)", .internalServerError)
            }
        }
    ),
]
