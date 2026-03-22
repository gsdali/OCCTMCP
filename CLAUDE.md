# CLAUDE.md

MCP server that gives LLMs the ability to create and iterate on CAD models using OpenCASCADE via OCCTSwift.

## How It Works

```
LLM writes Swift code via execute_script tool
  → Writes to OCCTSwiftScripts/Sources/Script/main.swift
  → Runs `swift run Script`
  → Outputs BREP/STEP files + manifest.json to ~/.occtswift-scripts/output/
  → OCCTSwiftViewport auto-reloads via ScriptWatcher
```

## Project Structure

```
src/
  index.ts          — MCP server entry point, tool registration
  tools.ts          — Tool implementations (execute, get_scene, etc.)
  paths.ts          — File path constants for OCCTSwiftScripts
  api-reference.ts  — OCCTSwift API reference served to LLMs
```

## Dependencies

- **OCCTSwiftScripts** (`../OCCTSwiftScripts`) — Swift executable that runs CAD scripts
- **OCCTSwift** (`../OCCTSwift`) — Swift wrapper for OCCT (900+ operations)
- **OCCTSwiftViewport** (`../OCCTSwiftViewport`) — Metal viewport that auto-reloads output

## Build & Run

```bash
npm run build    # Compile TypeScript
npm start        # Run MCP server (stdio transport)
npm run dev      # Watch mode for development
```

## MCP Tools

| Tool | Purpose |
|------|---------|
| `execute_script` | Write & run Swift CAD code |
| `get_scene` | Read current manifest (bodies, colors, materials) |
| `get_script` | Read current main.swift source |
| `export_model` | List exported BREP/STEP file paths |
| `get_api_reference` | OCCTSwift API reference by category |

## Script Template

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ... create geometry using OCCTSwift API ...

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "Description of the model")
```

## Adding to Claude Code

Add to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "node",
      "args": ["/Users/elb/Projects/OCCTMCP/dist/index.js"]
    }
  }
}
```
