// OCCTMCPCore — server factory + tool registration for the OCCTMCP MCP
// server. Tools are registered against a single Server instance via the
// MCP SDK's withMethodHandler API.
//
// During the migration from the Node implementation, this module starts
// minimal (one `ping` tool to verify wiring) and grows tool by tool as
// each is ported in subsequent commits.

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

/// The static list of tools the server advertises. Each entry pairs a Tool
/// descriptor (name + description + JSON-Schema input) with a handler that
/// the dispatcher in `dispatch(callName:arguments:)` routes to.
func catalogTools() -> [Tool] {
    return [
        Tool(
            name: "ping",
            description: "Sanity-check tool — returns 'pong' so callers can verify the OCCTMCP Swift server is alive. Replaced by real OCCTSwift-backed tools as the Swift port progresses.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]
}

func dispatch(callName: String, arguments: [String: Value]) async -> CallTool.Result {
    switch callName {
    case "ping":
        return .init(
            content: [.text(text: "pong", annotations: nil, _meta: nil)],
            isError: false
        )
    default:
        return .init(
            content: [.text(text: "Unknown tool: \(callName)", annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
