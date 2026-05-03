// IntegrationTests — spawn the occtmcp-server binary, drive it via
// JSON-RPC over stdio (newline-delimited per the Swift MCP SDK
// StdioTransport contract), assert tool responses against a
// tempdir-redirected scene.
//
// Slow: requires the binary to be built (`swift build` ahead of test
// run). The harness is deliberately minimal — the unit suites already
// cover the deterministic logic; this is the smoke test that proves
// the wired-up server actually serves requests.
//
// `.serialized` because the harness cd's into a tempdir and points
// OCCTMCP_OUTPUT_DIR at it; running multiple instances in parallel
// would fight over the same env var.

import Foundation
import Testing
import ScriptHarness
@testable import OCCTMCPCore

@Suite("stdio integration", .serialized)
struct IntegrationTests {

    /// Path to the built binary. Phase 6.3's smoke test requires
    /// `swift build` to have run; absence is treated as a skipped test
    /// rather than a failure so contributors who haven't built yet
    /// don't see a misleading red.
    static var binaryURL: URL? {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        for cfg in ["debug", "release"] {
            let url = URL(fileURLWithPath: "\(cwd)/.build/\(cfg)/occtmcp-server")
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    @Test("server initialises and lists tools")
    func initialisesAndLists() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built — run `swift build` first.")
            return
        }
        let harness = try Harness(binary: binary)
        defer { harness.terminate() }

        try harness.send(.init(
            id: 1,
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("integration-test"),
                    "version": .string("0.1"),
                ]),
            ])
        ))
        let initResponse = try harness.recv(timeout: 10)
        #expect(initResponse["id"]?.intValue == 1)
        #expect(initResponse["result"] != nil)

        try harness.send(.init(
            method: "notifications/initialized",
            params: .object([:])
        ))

        try harness.send(.init(id: 2, method: "tools/list", params: .object([:])))
        let listResponse = try harness.recv(timeout: 5)
        guard case .object(let result)? = listResponse["result"],
              case .array(let tools)? = result["tools"] else {
            Issue.record("tools/list result missing tools array")
            return
        }
        #expect(tools.count >= 30)
        let names = tools.compactMap { tool -> String? in
            guard case .object(let dict) = tool else { return nil }
            return dict["name"]?.stringValue
        }
        for expected in [
            "ping", "get_scene", "execute_script", "render_preview",
            "compute_metrics", "boolean_op", "set_assembly_metadata",
            "check_thickness",
        ] {
            #expect(names.contains(expected), "missing tool: \(expected)")
        }
    }

    @Test("ping responds and the scene tools resolve a tempdir manifest")
    func pingAndScene() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built — run `swift build` first.")
            return
        }

        // Seed a fresh scene the server will see when we redirect
        // OCCTMCP_OUTPUT_DIR.
        let scene = NSTemporaryDirectory()
            + "occtmcp-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        let manifest = ScriptManifest(
            description: "Integration test scene",
            bodies: [BodyDescriptor(id: "alpha", file: "alpha.brep", color: [1, 0, 0, 1])]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)
        try "DUMMY".write(toFile: "\(scene)/alpha.brep", atomically: true, encoding: .utf8)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }

        try harness.handshake()

        // ping
        try harness.send(.init(
            id: 10, method: "tools/call",
            params: .object([
                "name": .string("ping"),
                "arguments": .object([:]),
            ])
        ))
        let pingResp = try harness.recv(timeout: 5)
        #expect(pingResp["error"] == nil)

        // get_scene — should round-trip our seeded manifest
        try harness.send(.init(
            id: 11, method: "tools/call",
            params: .object([
                "name": .string("get_scene"),
                "arguments": .object([:]),
            ])
        ))
        let sceneResp = try harness.recv(timeout: 5)
        guard case .object(let result)? = sceneResp["result"],
              case .array(let content)? = result["content"],
              case .object(let firstContent)? = content.first,
              let text = firstContent["text"]?.stringValue else {
            Issue.record("get_scene response shape unexpected")
            return
        }
        #expect(text.contains("alpha"))
    }
}

// MARK: - Harness

/// JSON-RPC over newline-delimited stdio against a spawned MCP server.
final class Harness {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var pending = Data()

    init(binary: URL, extraEnv: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        try p.run()
        self.process = p
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading
    }

    struct Request {
        let id: Int?
        let method: String
        let params: Value
        init(id: Int? = nil, method: String, params: Value) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    func send(_ request: Request) throws {
        var dict: [String: Value] = [
            "jsonrpc": .string("2.0"),
            "method": .string(request.method),
            "params": request.params,
        ]
        if let id = request.id {
            dict["id"] = .int(id)
        }
        let data = try JSONEncoder().encode(Value.object(dict))
        try stdin.write(contentsOf: data)
        try stdin.write(contentsOf: [UInt8(ascii: "\n")])
    }

    /// Block until a complete JSON object arrives on stdout, or the
    /// timeout elapses. Returns the parsed object (top-level dict).
    func recv(timeout seconds: TimeInterval) throws -> [String: Value] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Try to peel a line out of pending.
            if let line = nextLine() {
                let parsed = try JSONDecoder().decode(Value.self, from: line)
                guard case .object(let dict) = parsed else {
                    throw HarnessError.unexpectedShape("top-level not an object")
                }
                return dict
            }
            // Read more from stdout, non-blocking-ish.
            let chunk = stdout.availableData
            if chunk.isEmpty {
                try? Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                pending.append(chunk)
            }
        }
        throw HarnessError.timeout(seconds)
    }

    private func nextLine() -> Data? {
        guard let nl = pending.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = pending[..<nl]
        pending.removeSubrange(...nl)
        return Data(line)
    }

    func handshake() throws {
        try send(.init(
            id: 1, method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("integration-test"),
                    "version": .string("0.1"),
                ]),
            ])
        ))
        _ = try recv(timeout: 10)
        try send(.init(
            method: "notifications/initialized",
            params: .object([:])
        ))
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    enum HarnessError: Error, CustomStringConvertible {
        case timeout(TimeInterval)
        case unexpectedShape(String)
        var description: String {
            switch self {
            case .timeout(let s): return "stdio response timeout after \(s)s"
            case .unexpectedShape(let m): return "unexpected JSON shape: \(m)"
            }
        }
    }
}

// MCP's Value type is in the MCP module; harness needs to encode/decode it.
// Re-import here so this file doesn't depend on @testable internals.
import MCP
