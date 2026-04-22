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

The server is a single-process Node.js app (ESM, strict TypeScript):

- `src/index.ts` — Creates `McpServer`, registers all five tools with zod schemas, connects stdio transport
- `src/tools.ts` — Tool implementations: writes Swift code to a tempfile, shells out to `occtkit run`, reads back results
- `src/occtkit.ts` — Resolves how to invoke `occtkit`: prefers PATH, falls back to `swift run -c release occtkit` inside the sibling OCCTSwiftScripts repo, throws a clear setup error if neither is available. Result is memoised
- `src/paths.ts` — Output dir / manifest path resolution (iCloud-vs-local) and per-call tempfile name generation
- `src/api-reference.ts` — **Generated** OCCTSwift API reference strings keyed by category. Do not edit by hand — it is rewritten by `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`). The generator parses `~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift` directly, extracts `public func` declarations, and groups them via the editorial `CATEGORIES` array at the top of the script. New OCCTSwift methods that don't match any category are surfaced in the generator's stderr "UNMATCHED" report — extend `CATEGORIES` (add a `markRx` or `nameRx` rule) when something important is missing.

### Data Flow

`execute_script` is the core tool. It:
1. Writes the LLM's Swift code to a per-call tempfile under `os.tmpdir()` and stashes the source for `get_script`
2. Resolves an `occtkit` invocation via `src/occtkit.ts` and runs `occtkit run <tempfile>` (2min timeout — generous because the cold first build is slow; incremental builds are ~1–2s)
3. Filters noisy OCCT bridge nullability warnings from build output (`filterBuildOutput`); the same filter runs on the failure path so compiler diagnostics still reach the LLM under the `Script failed.` prefix
4. Reads `manifest.json` from the output directory and returns it with build output
5. Removes the tempfile in a `finally` block

Writing `manifest.json` is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so emitting it is what triggers the live 3D reload.

`occtkit run --serve` (long-lived JSONL request loop) would let us drop the per-call build-cache check overhead, but adoption is deferred — see `gsdali/OCCTSwiftScripts#5` for the upstream framing gap that blocks safe client integration.

### Output Directory Resolution

`paths.ts:outputDir()` prefers iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) if the iCloud container exists, otherwise falls back to `~/.occtswift-scripts/output/`. The manifest and all BREP/STEP files live here.

## External Dependencies

- **OCCTSwiftScripts** ≥ v0.5.0-rc.1 — provides the `occtkit` CLI used by every `execute_script` call. Two install options, either works:
  - `make install` from the OCCTSwiftScripts repo puts `occtkit` on `$PATH` (preferred — fastest invocation, no sibling-repo path dependency).
  - Clone OCCTSwiftScripts to `~/Projects/OCCTSwiftScripts` so `swift run -c release occtkit` works as the fallback (slower per-call than the binary, but no install step).
- **OCCTSwift** — Swift wrapper around OpenCASCADE; transitive dep of OCCTSwiftScripts. Required at `~/Projects/OCCTSwift/` only when regenerating `src/api-reference.ts` via `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`).
- **OCCTSwiftViewport** — Metal viewport that watches the output directory via `ScriptWatcher` and auto-reloads. Optional but expected if you want the live preview.

## MCP Tools

| Tool | Purpose |
|------|---------|
| `execute_script` | Write Swift code to a tempfile, run via `occtkit run`, return output + manifest |
| `get_scene` | Read current manifest.json + list output files |
| `get_script` | Return the most recent script executed in this MCP session (kept in memory; not a filesystem read) |
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
