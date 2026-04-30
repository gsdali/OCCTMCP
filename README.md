# OCCTMCP

MCP server that gives LLMs the ability to create and iterate on 3D CAD models using [OpenCASCADE](https://www.opencascade.com/) via [OCCTSwift](https://github.com/gsdali/OCCTSwift).

## How It Works

```
LLM writes Swift CAD code via execute_script
  → OCCTSwiftScripts compiles & runs it (~0.5s incremental)
  → Outputs BREP/STEP files + manifest.json
  → OCCTSwiftViewport auto-reloads the 3D model
```

The LLM has full access to OCCTSwift's 900+ CAD operations: primitives, booleans, fillets, sweeps, lofts, patterns, healing, measurement, import/export, and more.

## Tools

36 tools, organized below. Call `get_api_reference({ category: "mcp_tools" })` to dump every tool's JSON Schema in one shot — useful for LLM auto-discovery. Most LLM flows can answer "what's the volume?", "make it red", "boolean-subtract these", "render a preview", "export to STEP", and "draw this" without ever round-tripping through `execute_script` — that's reserved for novel geometry the typed tools don't cover.

### Authoring

| Tool | Purpose |
|------|---------|
| `execute_script` | Write & execute arbitrary Swift CAD code (full OCCTSwift API) |
| `get_script` | Read the most recent script's source |
| `get_api_reference` | Browse OCCTSwift API by category |

### Scene reads

| Tool | Purpose |
|------|---------|
| `get_scene` | Read current scene manifest (bodies, colors, materials) |
| `export_model` | List exported BREP / STEP / STL / OBJ file paths |
| `compare_versions` | Diff current scene vs N runs ago (added / removed / appearance / file changed) |

### Scene mutation

| Tool | Purpose |
|------|---------|
| `remove_body` | Delete a body from the scene (manifest + BREP file) |
| `clear_scene` | Wipe all bodies, optionally keep diff history |
| `rename_body` | Change a body's id |
| `set_appearance` | Update color / opacity / roughness / metallic / display name |

### Introspection

| Tool | Purpose |
|------|---------|
| `validate_geometry` | Per-body topology validation (isValid, error counts) |
| `compute_metrics` | Volume, area, centroid, bounding box, principal axes |
| `query_topology` | Find faces / edges / vertices matching criteria, return stable IDs |
| `measure_distance` | Min distance + contacts between two bodies |
| `recognize_features` | Pockets and holes via AAG heuristics |
| `inspect_assembly` | Walk an XCAF assembly tree (STEP / IGES / XBF) |

### Construction

| Tool | Purpose |
|------|---------|
| `apply_feature` | Drill / fillet / chamfer / extrude / revolve / thread / boolean (FeatureSpec) |
| `transform_body` | Translate / rotate / uniform-scale (in place or new body) |
| `boolean_op` | Union / subtract / intersect / split between two bodies |
| `mirror_or_pattern` | Mirror / linear / circular pattern → N new bodies |

### Engineering analysis

| Tool | Purpose |
|------|---------|
| `check_thickness` | Wall-thickness analysis with thin-region flags |
| `analyze_clearance` | Pairwise interference / minimum clearance |
| `heal_shape` | Heal imported / non-watertight geometry; before/after stats |

### I/O

| Tool | Purpose |
|------|---------|
| `read_brep` | Load a `.brep` from disk into the scene |
| `import_file` | Multi-format import (STEP / IGES / STL / OBJ); optional XCAF assembly |
| `export_scene` | Export to STEP / IGES / BREP / STL / OBJ / glTF / GLB |
| `set_assembly_metadata` | Modify XCAF document or per-component metadata |

### Mesh & visualisation

| Tool | Purpose |
|------|---------|
| `generate_mesh` | Tessellate to triangles + quality metrics |
| `simplify_mesh` | QEM mesh decimation to .stl/.obj — wraps OCCTSwiftMesh's `Mesh.simplified` (vendored meshoptimizer) |
| `render_preview` | One-shot PNG render |
| `generate_drawing` | Multi-view ISO 128-30 DXF technical drawing |

### Topology graph (low-level)

| Tool | Purpose |
|------|---------|
| `graph_validate` | Validate a BREP's topology graph (raw path) |
| `graph_compact` | Drop unreferenced graph nodes; write rebuilt BREP |
| `graph_dedup` | Deduplicate shared surface / curve geometry |
| `graph_ml` | Export topology + UV/edge samples as ML-friendly JSON |
| `feature_recognize` | Pockets + holes (raw BREP path; `recognize_features` is the scene-aware wrapper) |

## Prerequisites

- [OCCTSwift](https://github.com/gsdali/OCCTSwift) — Swift wrapper for OpenCASCADE
- [OCCTSwiftScripts](https://github.com/gsdali/OCCTSwiftScripts) — Script runner (sibling directory)
- [OCCTSwiftViewport](https://github.com/gsdali/OCCTSwiftViewport) — Metal viewport for live preview (optional)
- Node.js 18+
- Swift 6.0+ / Xcode 16+

## Setup

```bash
git clone https://github.com/gsdali/OCCTMCP.git
cd OCCTMCP
npm install
npm run build
```

### Add to Claude Code

Create or edit `.mcp.json` in your project:

```json
{
  "mcpServers": {
    "occtmcp": {
      "command": "node",
      "args": ["/path/to/OCCTMCP/dist/index.js"]
    }
  }
}
```

## Example

Once configured, an LLM can create CAD models by writing Swift code:

```swift
import OCCTSwift
import ScriptHarness

let ctx = ScriptContext()
let C = ScriptContext.Colors.self

// Create a filleted box with a hole
let box = Shape.box(width: 40, height: 30, depth: 20)!
let hole = Shape.cylinder(radius: 5, height: 30)!
    .translated(by: SIMD3(20, -1, 10))!
let result = box.subtracting(hole)!
let filleted = result.filleted(radius: 2.0)!

try ctx.add(filleted, id: "part", color: C.steel, name: "Bracket")
try ctx.emit(description: "Filleted bracket with mounting hole")
```

## API Categories

The `get_api_reference` tool provides documentation for:

- **primitives** — box, cylinder, sphere, cone, torus, wedge
- **sweeps** — extrude, revolve, pipe sweep, loft, ruled
- **booleans** — union, subtract, intersect, section
- **modifications** — fillet, chamfer, shell, offset, draft, defeature
- **transforms** — translate, rotate, scale, mirror
- **wires** — rectangle, circle, polygon, spline, helix, offset
- **curves2d/3d** — line, arc, ellipse, bspline, bezier, interpolate
- **surfaces** — plane, cylinder, cone, sphere, extrusion, revolution, plate
- **analysis** — volume, area, distance, bounds, validation
- **import_export** — STL, STEP, IGES, BREP, OBJ, PLY

## License

LGPL-2.1-or-later — same as [OCCTSwift](https://github.com/gsdali/OCCTSwift).
