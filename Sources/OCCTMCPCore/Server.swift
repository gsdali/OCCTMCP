// OCCTMCPCore — server factory + tool registration for the OCCTMCP MCP
// server. Tools are registered against a single Server instance via the
// MCP SDK's withMethodHandler API.
//
// The Swift port grows tool by tool, mirroring the existing Node
// implementation under src/. Once the Swift side reaches feature parity
// the Node code under src/ can be retired.

import Foundation
import MCP

public enum OCCTMCPVersion {
    public static let serverName = "occtmcp"
    public static let serverVersion = "0.1.0"
}

/// Build a fully-configured MCP server with every OCCTMCP tool registered.
/// Caller is responsible for `start(transport:)` and `waitUntilCompleted()`.
public func makeOCCTMCPServer() async -> Server {
    let server = Server(
        name: OCCTMCPVersion.serverName,
        version: OCCTMCPVersion.serverVersion,
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )
    await registerTools(on: server)
    return server
}

func registerTools(on server: Server) async {
    let tools = catalogTools()

    await server.withMethodHandler(ListTools.self) { _ in
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        return await dispatch(callName: params.name, arguments: params.arguments ?? [:])
    }
}

func catalogTools() -> [Tool] {
    return [
        Tool(
            name: "ping",
            description: "Sanity-check tool — returns 'pong' so callers can verify the OCCTMCP Swift server is alive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "remove_body",
            description: "Delete a body from the current scene by id. Removes the body's BREP file from the output directory and re-emits the manifest (triggers viewport reload).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object([
                        "type": .string("string"),
                        "description": .string("The id of the body to remove."),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "clear_scene",
            description: "Remove every body from the current scene. Optionally preserves the compare_versions history ring buffer.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "keepHistory": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, keep the compare_versions history ring. Default false."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "rename_body",
            description: "Change a body's id in the scene manifest. Fails if the new id is already in use.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "newBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId"), .string("newBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "set_appearance",
            description: "Update color / opacity / roughness / metallic / display name for a scene body without re-running a script. The viewport reloads automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "color": .object([
                        "type": .string("array"),
                        "description": .string("RGBA or RGB array (0-1 per channel)."),
                        "items": .object(["type": .string("number")]),
                    ]),
                    "opacity": .object([
                        "type": .string("number"),
                        "description": .string("Sets color alpha (0-1). Leaves RGB unchanged."),
                    ]),
                    "roughness": .object(["type": .string("number")]),
                    "metallic": .object(["type": .string("number")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "compare_versions",
            description: "Diff the current scene against a snapshot from N runs ago. Detects added / removed / appearance-changed / file-changed bodies.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "description": .string("How many runs back to compare against. Default 1."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]
}

func dispatch(callName: String, arguments: [String: Value]) async -> CallTool.Result {
    switch callName {
    case "ping":
        return ToolText("pong").asCallToolResult()

    case "remove_body":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("remove_body requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await SceneTools.removeBody(bodyId: bodyId).asCallToolResult()

    case "clear_scene":
        let keepHistory = arguments["keepHistory"]?.boolValue ?? false
        return await SceneTools.clearScene(keepHistory: keepHistory).asCallToolResult()

    case "rename_body":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let newBodyId = arguments["newBodyId"]?.stringValue else {
            return ToolText("rename_body requires `bodyId` and `newBodyId`.", isError: true).asCallToolResult()
        }
        return await SceneTools.renameBody(bodyId: bodyId, newBodyId: newBodyId).asCallToolResult()

    case "set_appearance":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("set_appearance requires `bodyId`.", isError: true).asCallToolResult()
        }
        let update = SceneTools.AppearanceUpdate(
            color: arguments["color"]?.arrayValue?.compactMap { $0.doubleValue.flatMap { Float($0) } },
            opacity: arguments["opacity"]?.doubleValue.flatMap { Float($0) },
            roughness: arguments["roughness"]?.doubleValue.flatMap { Float($0) },
            metallic: arguments["metallic"]?.doubleValue.flatMap { Float($0) },
            name: arguments["name"]?.stringValue
        )
        return await SceneTools.setAppearance(bodyId: bodyId, update: update).asCallToolResult()

    case "compare_versions":
        let since = arguments["since"]?.intValue ?? 1
        return await SceneTools.compareVersions(since: since).asCallToolResult()

    default:
        return ToolText("Unknown tool: \(callName)", isError: true).asCallToolResult()
    }
}
