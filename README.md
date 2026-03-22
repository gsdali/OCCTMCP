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

| Tool | Purpose |
|------|---------|
| `execute_script` | Write & execute Swift CAD code |
| `get_scene` | Read current scene manifest (bodies, colors, materials) |
| `get_script` | Read current Swift script source |
| `export_model` | List exported BREP/STEP file paths |
| `get_api_reference` | Browse OCCTSwift API by category |

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
