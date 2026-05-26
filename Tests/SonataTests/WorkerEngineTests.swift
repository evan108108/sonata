import XCTest
@testable import Sonata

// Unit tests for the no-fork Goose engine binding (T3). These exercise the
// pure argv/env construction in WorkerEngine.swift — no `goose` process is
// launched (the live spawn/wake is the T4 e2e step). They lock in: Claude
// stays the default, `--session-id`/`--name` set the durable session id,
// GOOSE_MODE=auto is the permission-bypass, and the channels/skills-loader
// extensions only attach when present on disk.
final class WorkerEngineTests: XCTestCase {

    // MARK: WorkerEngine parsing / default

    func testEngineParsingDefaultsToClaude() {
        XCTAssertEqual(WorkerEngine.from(nil), .claude)
        XCTAssertEqual(WorkerEngine.from(""), .claude)
        XCTAssertEqual(WorkerEngine.from("   "), .claude)
        XCTAssertEqual(WorkerEngine.from("nonsense"), .claude)
    }

    func testEngineParsingRecognizesGoose() {
        XCTAssertEqual(WorkerEngine.from("goose"), .goose)
        XCTAssertEqual(WorkerEngine.from("GOOSE"), .goose)
        XCTAssertEqual(WorkerEngine.from("  Goose  "), .goose)
        XCTAssertEqual(WorkerEngine.from("claude"), .claude)
    }

    // MARK: binary resolution

    func testBinaryHonorsOverride() {
        let path = GooseEngineBinding.binary(env: ["SONA_GOOSE_BINARY": "/custom/goose"])
        XCTAssertEqual(path, "/custom/goose")
    }

    func testBinaryFallsBackToBareNameWhenNoneInstalled() {
        // Home pointed at a dir with no goose binary → bare "goose" (PATH lookup).
        let path = GooseEngineBinding.binary(env: [:], home: "/nonexistent-home-xyz")
        XCTAssertEqual(path, "goose")
    }

    // MARK: spawn / wake argv

    func testSpawnArgsUseNamedSession() {
        let args = GooseEngineBinding.spawnArgs(sessionId: "abc-123")
        XCTAssertEqual(args, ["session", "--name", "abc-123"])
    }

    func testSpawnArgsAppendExtensions() {
        let args = GooseEngineBinding.spawnArgs(
            sessionId: "abc-123",
            extensionArgs: ["--with-extension", "bun /x/server.ts"]
        )
        XCTAssertEqual(args, ["session", "--name", "abc-123", "--with-extension", "bun /x/server.ts"])
    }

    func testWakeArgsResumeAndInjectPrompt() {
        let args = GooseEngineBinding.wakeArgs(sessionId: "abc-123", eventPrompt: "do the thing")
        XCTAssertEqual(args, ["run", "--resume", "--name", "abc-123", "--text", "do the thing"])
    }

    // MARK: MCP extension args (only attach servers that exist)

    func testExtensionArgsEmptyWhenServersMissing() {
        let args = GooseEngineBinding.extensionArgs(env: [
            "SONA_GOOSE_CHANNELS_SERVER": "/nope/channels.ts",
            "SONA_GOOSE_SKILLS_SERVER": "/nope/skills.ts",
        ])
        XCTAssertTrue(args.isEmpty)
    }

    func testExtensionArgsAttachExistingServers() throws {
        let dir = NSTemporaryDirectory() + "goose-ext-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let channels = "\(dir)/channels.ts"
        let skills = "\(dir)/skills.ts"
        FileManager.default.createFile(atPath: channels, contents: Data())
        FileManager.default.createFile(atPath: skills, contents: Data())

        let args = GooseEngineBinding.extensionArgs(env: [
            "SONA_GOOSE_MCP_RUNNER": "bun",
            "SONA_GOOSE_CHANNELS_SERVER": channels,
            "SONA_GOOSE_SKILLS_SERVER": skills,
        ])
        XCTAssertEqual(args, [
            "--with-extension", "bun \(channels)",
            "--with-extension", "bun \(skills)",
        ])
    }

    // MARK: env additions (permission bypass + provider/model)

    func testEnvAdditionsSetAutoModeWhenSkippingPermissions() {
        let env = GooseEngineBinding.envAdditions(skipPermissions: true, env: [:])
        XCTAssertTrue(env.contains("GOOSE_MODE=auto"))
    }

    func testEnvAdditionsOmitModeWhenNotSkipping() {
        let env = GooseEngineBinding.envAdditions(skipPermissions: false, env: [:])
        XCTAssertFalse(env.contains { $0.hasPrefix("GOOSE_MODE=") })
    }

    func testEnvAdditionsCarryProviderAndModel() {
        let env = GooseEngineBinding.envAdditions(skipPermissions: true, env: [
            "SONA_GOOSE_PROVIDER": "anthropic",
            "SONA_GOOSE_MODEL": "claude-sonnet-4-6",
        ])
        XCTAssertTrue(env.contains("GOOSE_PROVIDER=anthropic"))
        XCTAssertTrue(env.contains("GOOSE_MODEL=claude-sonnet-4-6"))
    }
}
