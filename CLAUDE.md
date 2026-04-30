# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MCP server that gives LLMs the ability to create and iterate on CAD models using OpenCASCADE via OCCTSwift. The server exposes a growing set of tools over stdio transport using the `@modelcontextprotocol/sdk` — a few core tools (`execute_script`, scene reads, API reference) plus thin wrappers around occtkit verbs (graph ops, feature recognition, drawing export, reconstruct) and pure-TS scene-mutation tools (remove/rename/clear/appearance/compare/export).

## Build & Run

```bash
npm run build    # tsc → dist/
npm start        # node dist/index.js (stdio transport)
npm run dev      # tsc --watch
```

```bash
npm test                  # node:test unit tests for scene-mutation logic (no occtkit)
npm run test:integration  # node:test end-to-end chain through occtkit (slow; ~30–120s)
```

Tests under `tests/unit/` exercise the pure-TS scene-mutation code against a tempdir (set `OCCTMCP_OUTPUT_DIR` to redirect manifest reads/writes). `tests/integration/` runs every Phase 2 + Phase 3 verb-wrapping tool through a real occtkit subprocess against a tempdir seeded from a starter BREP. No linter configured.

## Architecture

The server is a single-process Node.js app (ESM, strict TypeScript):

- `src/index.ts` — Exports `createServer()` factory (which registers every tool with zod schemas) and connects stdio transport when run directly. Tests import `createServer()` to introspect the tool registry without binding stdio. The `get_api_reference` tool's `mcp_tools` category dumps the live registry as JSON Schema for LLM auto-discovery
- `src/tools.ts` — Core tool implementations (`execute_script`, `get_scene`, `get_script`, `export_model`, `get_api_reference`): writes Swift code to a tempfile, sends it to a long-lived `occtkit run --serve` child by default, falls back to one-shot `occtkit run <path>` if serve mode is unavailable. `executeScript` calls `snapshotScene()` before running so `compare_versions` has history
- `src/scene-tools.ts` — Pure-TS scene-mutation tools (`remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`, `export_scene`). Read/modify/write `manifest.json` directly; OCCTSwiftViewport's ScriptWatcher reloads on the write. `export_scene` is the exception: it generates a one-shot Swift script that loads the bodies' BREPs and calls `Exporter.writeXxx`, run via `occtkit run`. Maintains an in-memory ring buffer of the last 10 manifest snapshots for `compare_versions`
- `src/api-tools.ts` — Thin wrappers around existing occtkit verbs (`validate_geometry` → `graph-validate`, `recognize_features` → `feature-recognize`, `apply_feature` → `reconstruct`, `generate_drawing` → `drawing-export`). Each resolves a `bodyId` against the scene manifest, passes the BREP path to the verb, returns the verb's JSON output
- `src/verb-tools.ts` — Wrappers around the post-#6 batch of occtkit verbs: `compute_metrics`, `query_topology`, `measure_distance`, `check_thickness`, `analyze_clearance`, `generate_mesh` (pure reads); `transform_body`, `boolean_op`, `mirror_or_pattern`, `heal_shape` (scene mutators — snapshot before mutating, support in-place vs new-body output); `read_brep`, `import_file` (run the verb in a staging tmpdir then merge into the live manifest, since `load-brep` / `import` would otherwise clobber the live manifest with their own); `render_preview` (PNG out). Most verbs accept JSON-on-stdin or `<request.json>` form — wrappers always go via `runVerbJSON` (writes a tempfile, passes the path)
- `src/occtkit.ts` — Resolves how to invoke `occtkit`: prefers PATH, falls back to `swift run -c release occtkit` inside the sibling OCCTSwiftScripts repo, throws a clear setup error if neither is available. Result is memoised
- `src/occtkit-serve.ts` — Singleton long-lived `occtkit run --serve` child. JSONL request/response over stdin/stdout (one envelope per request, post-`gsdali/OCCTSwiftScripts#5`). Per-request timeout kills the child and respawns on next call. If a returned envelope lacks the `ok` field (pre-fix occtkit), serve mode is permanently disabled for the session and callers fall back to one-shot
- `src/paths.ts` — Output dir / manifest path resolution. Resolution order: `OCCTMCP_OUTPUT_DIR` env var (used by the test suite) > iCloud Drive > local fallback (`~/.occtswift-scripts/output`). Per-call tempfile name generation lives here too
- `src/api-reference.ts` — **Generated** OCCTSwift API reference strings keyed by category. Do not edit by hand — it is rewritten by `scripts/generate-api-reference.mjs` (runs as `npm run prebuild`). The generator parses `~/Projects/OCCTSwift/Sources/OCCTSwift/*.swift` directly, extracts `public func` declarations, and groups them via the editorial `CATEGORIES` array at the top of the script. New OCCTSwift methods that don't match any category are surfaced in the generator's stderr "UNMATCHED" report — extend `CATEGORIES` (add a `markRx` or `nameRx` rule) when something important is missing.

### Data Flow

`execute_script` is the core tool. It:
1. Writes the LLM's Swift code to a per-call tempfile under `os.tmpdir()` and stashes the source for `get_script`
2. **Serve path (default):** sends `{"args": ["<tempfile>"]}` over stdin to the singleton `occtkit run --serve` child managed by `src/occtkit-serve.ts`, awaits one JSONL envelope `{ ok, exit, stdout, stderr, error? }`. Cold start of the child is 60+s on first call; subsequent calls amortise to ~1–2s incremental.
3. **One-shot fallback:** if serve mode threw (timeout, child crash, pre-fix occtkit detected), runs `occtkit run <tempfile>` as a fresh subprocess. Triggers automatically; `OCCTMCP_OCCTKIT_NO_SERVE=1` forces this path always.
4. Filters noisy OCCT bridge nullability warnings from build output (`filterBuildOutput`); the same filter runs on both paths so compiler diagnostics still reach the LLM under the `Script failed.` prefix
5. Reads `manifest.json` from the output directory and returns it with build output
6. Removes the tempfile in a `finally` block

Writing `manifest.json` is the side effect that matters: `OCCTSwiftViewport`'s `ScriptWatcher` watches that file, so emitting it is what triggers the live 3D reload.

The 2 min timeout is per-request in both paths. On serve-mode timeout the child is `SIGTERM`'d so any pending requests reject and the next `execute_script` respawns it.

### Output Directory Resolution

`paths.ts:outputDir()` prefers iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/`) if the iCloud container exists, otherwise falls back to `~/.occtswift-scripts/output/`. The manifest and all BREP/STEP files live here.

## External Dependencies

- **OCCTSwiftScripts** ≥ post-`fd2a1cf` (the `--serve` framing fix from `gsdali/OCCTSwiftScripts#5`) — provides the `occtkit` CLI used by every `execute_script` call. Two install options, either works:
  - `make install` from the OCCTSwiftScripts repo puts `occtkit` on `$PATH` (preferred — fastest invocation, no sibling-repo path dependency).
  - Clone OCCTSwiftScripts to `~/Projects/OCCTSwiftScripts` so `swift run -c release occtkit` works as the fallback (slower per-call than the binary, but no install step).
  - Older OCCTSwiftScripts (without #5's framing) still works in one-shot fallback mode, just without the serve-mode amortisation. The serve client auto-detects the missing `ok` field on the first envelope and disables serve for the session.
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
| `graph_validate` | Validate a BREP's topology graph — wraps `occtkit graph-validate` |
| `graph_compact` | Drop unreferenced nodes, write rebuilt BREP — wraps `occtkit graph-compact` |
| `graph_dedup` | Deduplicate shared surface/curve geometry — wraps `occtkit graph-dedup` |
| `graph_ml` | ML-friendly graph + UV/edge sample export — wraps `occtkit graph-ml` |
| `feature_recognize` | AAG-based pocket + hole detection — wraps `occtkit feature-recognize` |
| `remove_body` | Delete a body from the manifest + its BREP file (pure TS) |
| `clear_scene` | Wipe all bodies from the manifest + delete their BREPs (pure TS) |
| `rename_body` | Change a body's id in the manifest (pure TS) |
| `set_appearance` | Update color / opacity / roughness / metallic / name on a body (pure TS) |
| `compare_versions` | Diff current scene vs a snapshot N runs back; uses an in-memory ring buffer |
| `export_scene` | Export current scene to step / iges / brep / stl / obj / gltf / glb (templated `occtkit run` script) |
| `validate_geometry` | Per-body topology validation — resolves bodyId → BREP, wraps `graph-validate` |
| `recognize_features` | Pockets + holes for a scene body — resolves bodyId, wraps `feature-recognize` |
| `apply_feature` | Apply a single feature spec to a scene body — wraps `occtkit reconstruct` |
| `generate_drawing` | Multi-view ISO 128-30 DXF for a scene body — wraps `occtkit drawing-export` |
| `compute_metrics` | Volume / area / centroid / bbox / principal axes — wraps `occtkit metrics` |
| `query_topology` | Find faces/edges/vertices matching criteria — wraps `occtkit query-topology` |
| `measure_distance` | Min distance + contacts between two bodies — wraps `occtkit measure-distance` |
| `check_thickness` | Wall-thickness analysis — wraps `occtkit check-thickness` |
| `analyze_clearance` | Pairwise interference / clearance — wraps `occtkit analyze-clearance` |
| `generate_mesh` | Triangle mesh + quality metrics — wraps `occtkit mesh` |
| `transform_body` | Translate / rotate / uniform-scale a body (in place or new) — wraps `occtkit transform` |
| `boolean_op` | Union / subtract / intersect / split between two bodies — wraps `occtkit boolean` |
| `mirror_or_pattern` | Mirror / linear / circular pattern — wraps `occtkit pattern` |
| `heal_shape` | Heal imported / non-watertight geometry — wraps `occtkit heal` |
| `read_brep` | Add a `.brep` from disk to the scene — wraps `occtkit load-brep` (staged + merged) |
| `import_file` | STEP / IGES / STL / OBJ import — wraps `occtkit import` (staged + merged) |
| `simplify_mesh` | QEM mesh decimation to .stl/.obj — wraps `occtkit simplify-mesh` (which wraps OCCTSwiftMesh's `Mesh.simplified`, vendoring meshoptimizer) |
| `render_preview` | One-shot PNG render of the scene — wraps `occtkit render-preview` |
| `inspect_assembly` | Walk an XCAF assembly tree — wraps `occtkit inspect-assembly` |
| `set_assembly_metadata` | Modify XCAF document or per-component metadata — wraps `occtkit set-metadata` |

The five graph/feature tools (`graph_*`, `feature_recognize`) are thin one-shot wrappers around pre-compiled occtkit verbs defined in `src/graph-tools.ts`. They go through the same `resolveOcctkit()` discovery as `execute_script` but bypass serve mode — these verbs don't compile Swift at call time, so there's no amortisation benefit. Each takes a BREP file path (use `export_model` to list available ones) and returns the verb's JSON report verbatim.

The scene-mutation tools (`remove_body`, `clear_scene`, `rename_body`, `set_appearance`, `compare_versions`) are pure manifest manipulation — they don't shell out to occtkit at all. `export_scene` is the exception: it generates a small templated Swift program that loads the relevant BREPs and calls `Exporter.writeXxx`, run via `occtkit run` (one-shot, not serve). The `validate_geometry` / `recognize_features` / `apply_feature` / `generate_drawing` tools resolve a `bodyId` against the manifest and delegate to the corresponding occtkit verb.

All 26 tools from [#6](https://github.com/gsdali/OCCTMCP/issues/6) are built. Mesh-domain algorithms beyond decimation live in [OCCTSwiftMesh](https://github.com/gsdali/OCCTSwiftMesh) (sibling to OCCTSwift, vendors permissive implementations because OCCT-Open ships only mesh generation, not post-processing). As more verbs land in OCCTSwiftMesh → OCCTSwiftScripts (smoothing, repair, remeshing, subdivision per the OCCTSwiftMesh roadmap), wire them as additional MCP tools using the same `runVerbJSON` pattern.

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
