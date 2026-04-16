import Foundation
import Hummingbird

// Phase 2 migration: action definitions for /api/secrets routes.
// Handler logic duplicated from SecretRoutes.swift.

let secretActions: [SonataAction] = [

    // GET /api/secrets — list all secret names + descriptions (no values)
    SonataAction(
        name: "mem_secret_list",
        description: "List all secret names and descriptions (values omitted).",
        group: "/api/secrets",
        path: "/",
        method: .get,
        params: [],
        handler: { _ in
            let secrets = SecretStore.list()
            return secrets.map { SecretListItem(name: $0.name, description: $0.description) }
        }
    ),

    // GET /api/secrets/:name — get a single secret's value
    SonataAction(
        name: "mem_secret_get",
        description: "Get a single secret's value by name.",
        group: "/api/secrets",
        path: "/:name",
        method: .get,
        params: [
            ActionParam("name", .string, required: true, description: "Secret name", source: .path),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            guard let value = SecretStore.get(name) else {
                throw ActionError.notFound("secret not found")
            }
            return SecretValueResponse(name: name, value: value)
        }
    ),

    // POST /api/secrets — set a secret {name, value, description?}
    SonataAction(
        name: "mem_secret_set",
        description: "Set (create or update) a secret value by name.",
        group: "/api/secrets",
        path: "/",
        method: .post,
        params: [
            ActionParam("name", .string, required: true, description: "Secret name"),
            ActionParam("value", .string, required: true, description: "Secret value"),
            ActionParam("description", .string, description: "Optional description"),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let value = try ctx.params.require("value")
            let description = ctx.params.string("description") ?? ""
            SecretStore.set(name: name, value: value, description: description)
            return SecretActionResponse(success: true, name: name)
        }
    ),

    // DELETE /api/secrets/:name — delete a secret
    SonataAction(
        name: "mem_secret_delete",
        description: "Delete a secret by name.",
        group: "/api/secrets",
        path: "/:name",
        method: .delete,
        params: [
            ActionParam("name", .string, required: true, description: "Secret name", source: .path),
        ],
        handler: { ctx in
            let name = try ctx.params.require("name")
            let deleted = SecretStore.delete(name)
            if !deleted {
                throw ActionError.notFound("secret not found")
            }
            return SecretActionResponse(success: deleted, name: name)
        }
    ),
]
