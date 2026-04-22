# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MCP server that gives LLMs the ability to create and iterate on CAD models using OpenCASCADE via OCCTSwift. The server exposes five tools over stdio transport using the `@modelcontextprotocol/sdk`.

## Build & Run

```bash
npm run build    # tsc → dist/
npm start        # node dist/index.js (stdio transport)
npm run dev      # tsc --watch
```

No tests or linter configured.

## Architecture

The server is a single-process Node.js app (ESM, strict TypeScript) with four source files:

- `src/index.ts` — Creates `McpServer`, registers all five tools with zod schemas, connects stdio transport
- `src/tools.ts` — Tool implementations: writes Swift code to disk, shells out to `swift run Script`, reads back results
- `src/paths.ts` — Resolves file paths (scripts project, output dir, manifest)
- `src/api-reference.ts` — **Generated** OCCTSwift API reference strings keyed by category. Do not edit by hand — it is rewritten by `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`). The generator parses `~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift` directly, extracts `public func` declarations, and groups them via the editorial `CATEGORIES` array at the top of the script. New OCCTSwift methods that don't match any category are surfaced in the generator's stderr "UNMATCHED" report — extend `CATEGORIES` (add a `markRx` or `nameRx` rule) when something important is missing.

### Data Flow

`execute_script` is the core tool. It:
1. Writes the LLM's Swift code to `~/Projects/OCCTSwiftScripts/Sources/Script/main.swift`
2. Runs `swift run Script` in that project (2min timeout — generous because the cold first build is slow; incremental builds are ~1–2s)
3. Filters noisy OCCT bridge nullability warnings from build output (`filterBuildOutput`); the same filter runs on the failure path so compiler diagnostics still reach the LLM under the `Script failed.` prefix
4. Reads `manifest.json` from the output directory and returns it with build output

Writing `manifest.json` is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so emitting it is what triggers the live 3D reload.

### Output Directory Resolution

`paths.ts:outputDir()` prefers iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) if the iCloud container exists, otherwise falls back to `~/.occtswift-scripts/output/`. The manifest and all BREP/STEP files live here.

## External Dependencies

These sibling projects must exist at `~/Projects/`:

- **OCCTSwiftScripts** — Swift Package Manager project that compiles and runs the generated `main.swift`
- **OCCTSwift** — Swift wrapper around OpenCASCADE (dependency of OCCTSwiftScripts)
- **OCCTSwiftViewport** — Metal viewport that watches the output directory via `ScriptWatcher` and auto-reloads

## MCP Tools

| Tool | Purpose |
|------|---------|
| `execute_script` | Write Swift code to main.swift, compile & run, return output + manifest |
| `get_scene` | Read current manifest.json + list output files |
| `get_script` | Read current main.swift source |
| `export_model` | List exported BREP/STEP/STL/OBJ file paths |
| `get_api_reference` | Return OCCTSwift API reference by category (or "all") |

## Script Template

Scripts must follow this structure:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// ... create geometry using OCCTSwift API ...

try ctx.add(shape, id: "part", color: C.steel, name: "My Part")
try ctx.emit(description: "Description of the model")
```
