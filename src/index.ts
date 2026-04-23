#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { executeScript, getScene, getScript, exportModel, getApiReference } from "./tools.js";
import {
  graphValidate,
  graphCompact,
  graphDedup,
  graphMl,
  featureRecognize,
} from "./graph-tools.js";

const server = new McpServer({
  name: "occtmcp",
  version: "0.1.0",
});

// ── execute_script ──────────────────────────────────────────────────────────
// The core tool: write Swift CAD code, compile & run it via OCCTSwiftScripts.
// The viewport app auto-reloads when the manifest is written.
server.tool(
  "execute_script",
  "Write and execute Swift CAD code using the OCCTSwift API. " +
    "The code runs via OCCTSwiftScripts and outputs BREP/STEP files + manifest.json. " +
    "The viewport app auto-reloads on change. " +
    "You have access to the full OCCTSwift API: Shape, Wire, Edge, Face, Surface, Curve2D, Curve3D, etc. " +
    "Use ScriptContext to accumulate geometry and call ctx.emit() at the end.",
  {
    code: z
      .string()
      .describe(
        "Complete Swift source for main.swift. Must import OCCTSwift and ScriptHarness, " +
          "create a ScriptContext, add geometry, and call ctx.emit()."
      ),
    description: z
      .string()
      .optional()
      .describe("Short description of what this script creates"),
  },
  async ({ code, description }) => {
    return executeScript(code, description);
  }
);

// ── get_scene ───────────────────────────────────────────────────────────────
// Read the current manifest to understand what's currently rendered.
server.tool(
  "get_scene",
  "Read the current scene manifest from OCCTSwiftScripts output. " +
    "Returns the list of bodies, their IDs, colors, materials, and metadata.",
  {},
  async () => {
    return getScene();
  }
);

// ── get_script ──────────────────────────────────────────────────────────────
// Return the most recent script run in this MCP session.
server.tool(
  "get_script",
  "Return the source of the most recent Swift CAD script executed in this MCP session. " +
    "Returns a 'no script executed' message if execute_script has not been called yet.",
  {},
  async () => {
    return getScript();
  }
);

// ── export_model ────────────────────────────────────────────────────────────
// Get paths to exported files for downstream use.
server.tool(
  "export_model",
  "List the exported model files (BREP, STEP) from the last script run. " +
    "Returns absolute file paths that can be opened in external CAD tools.",
  {},
  async () => {
    return exportModel();
  }
);

// ── get_api_reference ───────────────────────────────────────────────────────
// Quick reference for the OCCTSwift API surface.
server.tool(
  "get_api_reference",
  "Get a reference guide for OCCTSwift API operations. " +
    "Use this to look up available methods before writing a script.",
  {
    category: z
      .enum([
        "primitives",
        "sweeps",
        "booleans",
        "modifications",
        "transforms",
        "wires",
        "curves2d",
        "curves3d",
        "surfaces",
        "analysis",
        "import_export",
        "topology_graph",
        "topology_graph_builder",
        "all",
      ])
      .describe("API category to look up"),
  },
  async ({ category }) => {
    return getApiReference(category);
  }
);

// ── graph_validate ──────────────────────────────────────────────────────────
// Run BRepGraph validation on a BREP file and return the report JSON.
server.tool(
  "graph_validate",
  "Validate a BREP shape's topology graph. Returns a JSON report: " +
    "validity, error/warning counts, and per-category issue details. " +
    "Use export_model to find BREP paths after execute_script.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
  },
  async ({ brep_path }) => {
    return graphValidate(brep_path);
  }
);

// ── graph_compact ───────────────────────────────────────────────────────────
// Compact a BREP's topology graph (drops unreferenced nodes) and write a
// rebuilt BREP to output_path. Returns JSON stats (nodes before/after).
server.tool(
  "graph_compact",
  "Compact a BREP's topology graph (drops unreferenced nodes) and write the " +
    "rebuilt shape to output_path. Returns a JSON report with before/after " +
    "node counts.",
  {
    brep_path: z.string().describe("Absolute path to the input BREP file."),
    output_path: z.string().describe("Absolute path where the compacted BREP is written."),
  },
  async ({ brep_path, output_path }) => {
    return graphCompact(brep_path, output_path);
  }
);

// ── graph_dedup ─────────────────────────────────────────────────────────────
// Deduplicate shared surface/curve geometry in a BREP, write rebuilt BREP.
server.tool(
  "graph_dedup",
  "Deduplicate shared surface/curve geometry in a BREP's topology graph. " +
    "Writes the rebuilt shape to output_path and returns a JSON report.",
  {
    brep_path: z.string().describe("Absolute path to the input BREP file."),
    output_path: z.string().describe("Absolute path where the deduped BREP is written."),
  },
  async ({ brep_path, output_path }) => {
    return graphDedup(brep_path, output_path);
  }
);

// ── graph_ml ────────────────────────────────────────────────────────────────
// Export the topology graph plus UV/edge samples as ML-friendly JSON.
server.tool(
  "graph_ml",
  "Export a BREP's topology graph as ML-friendly JSON: vertex positions, " +
    "edge/face adjacency (COO), per-face UV-grid samples (position, normal, " +
    "gaussian/mean curvature), and per-edge polyline samples. Output can be " +
    "large for complex shapes — up to ~50 MB.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
    uv_samples: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Per-face UV grid resolution (default 16 × 16)."),
    edge_samples: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Per-edge polyline sample count (default 32)."),
  },
  async ({ brep_path, uv_samples, edge_samples }) => {
    return graphMl(brep_path, uv_samples, edge_samples);
  }
);

// ── feature_recognize ───────────────────────────────────────────────────────
// AAG heuristic detection of pockets and holes.
server.tool(
  "feature_recognize",
  "Detect pockets and cylindrical holes in a BREP via AAG (attributed " +
    "adjacency graph) heuristics. Returns a JSON report listing each " +
    "pocket's floor/wall faces, z-level, depth, and bounds, plus each " +
    "hole's face index, radius, and depth.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
  },
  async ({ brep_path }) => {
    return featureRecognize(brep_path);
  }
);

// ── Start ───────────────────────────────────────────────────────────────────
const transport = new StdioServerTransport();
await server.connect(transport);
