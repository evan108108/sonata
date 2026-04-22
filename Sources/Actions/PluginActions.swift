import Foundation
import GRDB

/// Plugin management actions — registered as SonataActions so they're
/// available as both HTTP endpoints and MCP tools.
///
/// Requires: `pluginManager` to be set on the ActionRegistry or passed
/// via a shared reference. Since ActionContext doesn't have a pluginManager
/// field, we capture it in the closure.
func makePluginActions(pluginManager: PluginManager) -> [SonataAction] {
    [
        // GET /api/plugins — list all plugins
        SonataAction(
            name: "plugin_list",
            description: "List all installed plugins and their status",
            group: "/api/plugins",
            path: "",
            method: .get,
            params: [],
            handler: { _ in
                let plugins = try await pluginManager.listPlugins()
                return AnyEncodable(JSONPassthrough(plugins))
            }
        ),

        // POST /api/plugins/install — install from tarball path
        SonataAction(
            name: "plugin_install",
            description: "Install a plugin from a tarball file path",
            group: "/api/plugins",
            path: "/install",
            method: .post,
            params: [
                ActionParam("path", .string, required: true, description: "Path to the plugin tarball (.tar.gz)"),
            ],
            handler: { ctx in
                let path = try ctx.params.require("path")
                let manifest = try await pluginManager.install(tarballPath: path)
                return PluginOpResponse(ok: true, message: "Installed \(manifest.name) v\(manifest.version)")
            }
        ),

        // POST /api/plugins/connect — register an external plugin
        SonataAction(
            name: "plugin_connect",
            description: "Connect to an already-running external plugin by URL",
            group: "/api/plugins",
            path: "/connect",
            method: .post,
            params: [
                ActionParam("name", .string, required: true, description: "Plugin name"),
                ActionParam("url", .string, required: true, description: "Plugin base URL (e.g., http://localhost:4000)"),
                ActionParam("manifest_path", .string, description: "Optional path to the plugin's manifest file"),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                let url = try ctx.params.require("url")
                let manifestPath = ctx.params.string("manifest_path")
                try await pluginManager.connect(name: name, url: url, manifestPath: manifestPath)
                return PluginOpResponse(ok: true, message: "Connected to \(name) at \(url)")
            }
        ),

        // POST /api/plugins/:name/enable — enable + start
        SonataAction(
            name: "plugin_enable",
            description: "Enable and start a plugin",
            group: "/api/plugins",
            path: "/:name/enable",
            method: .post,
            params: [
                ActionParam("name", .string, required: true, description: "Plugin name", source: .path),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                try await pluginManager.enable(name: name)
                return PluginOpResponse(ok: true, message: "Plugin \(name) enabled and running")
            }
        ),

        // POST /api/plugins/:name/disable — disable + stop
        SonataAction(
            name: "plugin_disable",
            description: "Disable and stop a plugin",
            group: "/api/plugins",
            path: "/:name/disable",
            method: .post,
            params: [
                ActionParam("name", .string, required: true, description: "Plugin name", source: .path),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                try await pluginManager.disable(name: name)
                return PluginOpResponse(ok: true, message: "Plugin \(name) disabled")
            }
        ),

        // POST /api/plugins/:name/config — update config
        SonataAction(
            name: "plugin_config",
            description: "Update a plugin's configuration",
            group: "/api/plugins",
            path: "/:name/config",
            method: .post,
            params: [
                ActionParam("name", .string, required: true, description: "Plugin name", source: .path),
                ActionParam("config", .object, required: true, description: "Configuration object"),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                guard let config = ctx.params.object("config") else {
                    throw ActionError.missingParam("config")
                }
                let json = try JSONSerialization.data(withJSONObject: config)
                let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
                try await pluginManager.updateConfig(name: name, configJson: jsonStr)
                return PluginOpResponse(ok: true, message: "Config updated for \(name)")
            }
        ),

        // DELETE /api/plugins/:name — uninstall
        SonataAction(
            name: "plugin_uninstall",
            description: "Uninstall a plugin (stop, remove from DB, delete files)",
            group: "/api/plugins",
            path: "/:name",
            method: .delete,
            params: [
                ActionParam("name", .string, required: true, description: "Plugin name", source: .path),
            ],
            handler: { ctx in
                let name = try ctx.params.require("name")
                try await pluginManager.uninstall(name: name)
                return PluginOpResponse(ok: true, message: "Plugin \(name) uninstalled")
            }
        ),
    ]
}

// MARK: - Response Types

struct PluginOpResponse: Codable {
    let ok: Bool
    let message: String
}

struct SendWithReplyResponse: Codable {
    let messageId: String
    let status: String     // "replied" or "pending"
    let reply: String?     // The reply content, if available
}
