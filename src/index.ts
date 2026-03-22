#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { executeScript, getScene, getScript, exportModel, getApiReference } from "./tools.js";

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
// Read the current main.swift source.
server.tool(
  "get_script",
  "Read the current Swift CAD script source (main.swift) from OCCTSwiftScripts.",
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
        "all",
      ])
      .describe("API category to look up"),
  },
  async ({ category }) => {
    return getApiReference(category);
  }
);

// ── Start ───────────────────────────────────────────────────────────────────
const transport = new StdioServerTransport();
await server.connect(transport);
