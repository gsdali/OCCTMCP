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
import OCCTSwift
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

    @Test("history-based remap preserves selectionIds across transform_body")
    func historyRemapPreservesAcrossTransform() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built — run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-history-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Synthesize a real cylinder BREP so transform_body /
        // select_topology can actually load it. r=10mm, h=25mm gives
        // 3 faces (lateral + 2 caps), which is enough to verify
        // selection survives a translate.
        guard let cyl = Shape.cylinder(radius: 10, height: 25) else {
            Issue.record("Failed to synthesize cylinder BREP fixture")
            return
        }
        try Exporter.writeBREP(shape: cyl, to: URL(fileURLWithPath: "\(scene)/cyl.brep"))

        let manifest = ScriptManifest(
            description: "History remap test scene",
            bodies: [
                BodyDescriptor(
                    id: "cyl",
                    file: "cyl.brep",
                    color: [0.8, 0.7, 0.3, 1]
                ),
            ]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // 1. select_topology — pick a face on the cylinder
        try harness.send(.init(
            id: 30, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("cyl"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selectResp = try harness.recv(timeout: 10)
        guard case .object(let result)? = selectResp["result"],
              case .array(let content)? = result["content"],
              case .object(let firstContent)? = content.first,
              let text = firstContent["text"]?.stringValue,
              let selectData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: selectData) as? [String: Any],
              let selections = parsed["selections"] as? [[String: Any]],
              let firstSelection = selections.first,
              let selectionId = firstSelection["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // 2. transform_body — move it
        try harness.send(.init(
            id: 31, method: "tools/call",
            params: .object([
                "name": .string("transform_body"),
                "arguments": .object([
                    "bodyId": .string("cyl"),
                    "translate": .array([.double(20), .double(0), .double(0)]),
                ]),
            ])
        ))
        let transformResp = try harness.recv(timeout: 30)
        #expect(transformResp["error"] == nil)

        // 3. remap_selection — should find the face via history (fate
        //    preserved), not via centroid heuristic
        try harness.send(.init(
            id: 32, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let remapResp = try harness.recv(timeout: 5)
        guard case .object(let remapResult)? = remapResp["result"],
              case .array(let remapContent)? = remapResult["content"],
              case .object(let remapBody)? = remapContent.first,
              let remapText = remapBody["text"]?.stringValue,
              let remapData = remapText.data(using: .utf8),
              let remapParsed = try JSONSerialization.jsonObject(with: remapData) as? [String: Any],
              let remapped = remapParsed["remapped"] as? [[String: Any]],
              let firstEntry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        #expect(firstEntry["fate"] as? String == "preserved",
                "expected history-based remap to preserve, got: \(firstEntry["fate"] ?? "<nil>")")
        if let conf = firstEntry["confidenceMm"] as? Double {
            #expect(conf == 0, "history-based remap should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("annotation tools round-trip via the sidecar")
    func annotationsRoundTrip() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built — run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-anno-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // No BREP needed for these tools — annotations are pure scene
        // sidecar mutation. We do still need a manifest so other tools
        // don't fail; an empty bodies array is fine.
        let manifest = ScriptManifest(
            description: "Annotation round-trip scene",
            bodies: []
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // add a Trihedron
        try harness.send(.init(
            id: 20, method: "tools/call",
            params: .object([
                "name": .string("add_scene_primitive"),
                "arguments": .object([
                    "kind": .string("trihedron"),
                    "id": .string("test_trihedron"),
                    "params": .object([
                        "origin": .array([.double(0), .double(0), .double(0)]),
                        "axisLength": .double(10),
                    ]),
                ]),
            ])
        ))
        let addResp = try harness.recv(timeout: 5)
        #expect(addResp["error"] == nil)

        // sidecar should now exist with our trihedron
        let sidecarPath = "\(scene)/annotations.json"
        #expect(FileManager.default.fileExists(atPath: sidecarPath))
        let raw = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let decoded = try JSONDecoder().decode(AnnotationsSidecar.self, from: raw)
        #expect(decoded.primitives.contains { $0.id == "test_trihedron" })

        // remove it
        try harness.send(.init(
            id: 21, method: "tools/call",
            params: .object([
                "name": .string("remove_scene_annotation"),
                "arguments": .object([
                    "id": .string("test_trihedron"),
                ]),
            ])
        ))
        let removeResp = try harness.recv(timeout: 5)
        #expect(removeResp["error"] == nil)

        let raw2 = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let decoded2 = try JSONDecoder().decode(AnnotationsSidecar.self, from: raw2)
        #expect(decoded2.primitives.allSatisfy { $0.id != "test_trihedron" })
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
