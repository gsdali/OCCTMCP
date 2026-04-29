/**
 * Integration test: exercises the canonical end-to-end chain across every
 * Phase 2 + Phase 3 tool against a real occtkit subprocess.
 *
 * Slow (~30–120s depending on whether occtkit needs a rebuild). Run with:
 *   npm run test:integration
 *
 * Setup: copies the user's existing BREP from iCloud (or from a fixture
 * shipped in tests/fixtures/) into a fresh tempdir, points
 * OCCTMCP_OUTPUT_DIR at it, and runs the chain. No live scene is touched.
 *
 * Tools exercised: validate_geometry, recognize_features, compute_metrics,
 * query_topology, transform_body, measure_distance, analyze_clearance,
 * boolean_op, mirror_or_pattern, heal_shape, check_thickness,
 * generate_mesh, render_preview, export_scene, inspect_assembly,
 * remove_body, clear_scene, compare_versions.
 *
 * Tools NOT exercised here (need carefully constructed schemas — separate
 * tests): apply_feature (FeatureSpec), generate_drawing (DrawingSpec),
 * read_brep (covered indirectly via export_scene + import_file would be
 * the natural pair), import_file (would clobber if mis-pointed; covered
 * once we have a fixture STEP), set_assembly_metadata.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  rmSync,
  existsSync,
  copyFileSync,
  writeFileSync,
  readFileSync,
  statSync,
} from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join } from "node:path";

const ICLOUD_BREP = join(
  homedir(),
  "Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output/body-0.brep"
);
const FIXTURE_BREP = join(
  process.cwd(),
  "tests/fixtures/cylinder.brep"
);

let SCENE_DIR;
let scene;
let verb;
let api;

function pickStarterBrep() {
  if (existsSync(ICLOUD_BREP)) return ICLOUD_BREP;
  if (existsSync(FIXTURE_BREP)) return FIXTURE_BREP;
  return null;
}

before(async () => {
  const starter = pickStarterBrep();
  if (!starter) {
    throw new Error(
      `No starter BREP found. Expected one of:\n  ${ICLOUD_BREP}\n  ${FIXTURE_BREP}`
    );
  }

  SCENE_DIR = mkdtempSync(join(tmpdir(), "occtmcp-itest-"));
  process.env.OCCTMCP_OUTPUT_DIR = SCENE_DIR;

  // Seed the scene with a single body called "cyl"
  copyFileSync(starter, join(SCENE_DIR, "body-0.brep"));
  const manifest = {
    version: 1,
    timestamp: new Date().toISOString(),
    description: "Integration-test scene",
    bodies: [
      { id: "cyl", file: "body-0.brep", format: "brep", color: [0.8, 0.7, 0.3, 1] },
    ],
  };
  writeFileSync(join(SCENE_DIR, "manifest.json"), JSON.stringify(manifest, null, 2));

  // Import the modules — relies on dist/ already being built
  scene = await import("../../dist/scene-tools.js");
  verb = await import("../../dist/verb-tools.js");
  api = await import("../../dist/api-tools.js");
});

after(() => {
  if (SCENE_DIR && existsSync(SCENE_DIR)) {
    rmSync(SCENE_DIR, { recursive: true, force: true });
  }
});

function parseJSON(toolResult) {
  return JSON.parse(toolResult.content[0].text);
}

function trailingJSON(toolResult) {
  // Tools that prefix with a human-readable line then dump JSON. Find the
  // first '{' and parse from there.
  const t = toolResult.content[0].text;
  const i = t.indexOf("{");
  assert.ok(i >= 0, `no JSON found in tool output:\n${t}`);
  return JSON.parse(t.slice(i));
}

describe("canonical chain", () => {
  it("compute_metrics returns volume + bbox + principal axes", async () => {
    const r = await verb.computeMetrics("cyl");
    const data = parseJSON(r);
    assert.ok(data.volume > 0, "volume should be positive");
    assert.ok(Array.isArray(data.boundingBox.min));
    assert.ok(Array.isArray(data.boundingBox.max));
    assert.ok(Array.isArray(data.principalAxes.moments));
  });

  it("validate_geometry reports per-body health", async () => {
    const r = await api.validateGeometry();
    const data = parseJSON(r);
    assert.ok(Array.isArray(data.bodies));
    assert.equal(data.bodies.length, 1);
    assert.equal(data.bodies[0].id, "cyl");
    assert.equal(data.bodies[0].isValid, true);
  });

  it("query_topology returns face IDs", async () => {
    const r = await verb.queryTopology("cyl", "face");
    const data = parseJSON(r);
    assert.equal(data.entity, "face");
    assert.ok(data.results.length >= 3, "cylinder has 3 faces (lateral + 2 caps)");
    for (const f of data.results) {
      assert.match(f.id, /^face\[\d+\]$/);
    }
  });

  it("recognize_features returns pockets/holes (likely empty for plain cyl)", async () => {
    const r = await api.recognizeFeatures("cyl");
    const data = parseJSON(r);
    assert.equal(data.bodyId, "cyl");
    assert.ok(Array.isArray(data.pockets));
    assert.ok(Array.isArray(data.holes));
  });

  it("transform_body creates a translated copy", async () => {
    const r = await verb.transformBody("cyl", [40, 0, 0], undefined, undefined, undefined, false, "cyl2");
    const data = trailingJSON(r);
    assert.ok(data.outputPath.endsWith(".brep"));
    assert.deepEqual(data.trsf.slice(12, 15), [40, 0, 0]);
  });

  it("measure_distance between cyl and cyl2 is non-negative", async () => {
    const r = await verb.measureDistance("cyl", "cyl2");
    const data = parseJSON(r);
    assert.ok(typeof data.minDistance === "number");
    assert.ok(data.minDistance >= 0);
  });

  it("analyze_clearance produces pair entries", async () => {
    const r = await verb.analyzeClearance(["cyl", "cyl2"]);
    const data = parseJSON(r);
    assert.equal(data.pairs.length, 1);
    assert.ok(typeof data.pairs[0].minDistance === "number");
  });

  it("boolean_op union produces a new body", async () => {
    const r = await verb.booleanOp("union", "cyl", "cyl2", "merged");
    const text = r.content[0].text;
    assert.match(text, /Boolean union/);
    const data = trailingJSON(r);
    assert.equal(data.isValid, true);
  });

  it("mirror_or_pattern linear produces 3 bodies", async () => {
    const r = await verb.mirrorOrPattern(
      "cyl",
      "linear",
      { direction: [0, 1, 0], spacing: 30, count: 3 },
      "row"
    );
    const text = r.content[0].text;
    assert.match(text, /3 bodies/);
  });

  it("heal_shape produces before/after stats", async () => {
    const r = await verb.healShape("cyl", undefined, "cyl_healed");
    const data = trailingJSON(r);
    assert.ok(data.before);
    assert.ok(data.after);
    assert.ok(data.outputPath.endsWith(".brep"));
  });

  it("check_thickness returns sample stats", async () => {
    const r = await verb.checkThickness("cyl");
    const data = parseJSON(r);
    assert.ok(typeof data.samples === "number");
    assert.ok(data.samples >= 0);
  });

  it("generate_mesh returns triangle counts", async () => {
    const r = await verb.generateMesh("cyl", undefined, undefined, undefined, false);
    const data = parseJSON(r);
    assert.ok(data.triangleCount > 0);
    assert.ok(data.vertexCount > 0);
    assert.ok(data.quality);
  });

  it("render_preview writes a non-empty PNG", async () => {
    const png = join(SCENE_DIR, "preview.png");
    const r = await verb.renderPreview(png, undefined, { camera: "iso", width: 400, height: 300 });
    assert.match(r.content[0].text, /Rendered/);
    assert.ok(existsSync(png));
    assert.ok(statSync(png).size > 0);
  });

  it("export_scene writes a STEP file", async () => {
    const step = join(SCENE_DIR, "scene.step");
    const r = await scene.exportScene("step", step, ["cyl"]);
    assert.match(r.content[0].text, /Exported/);
    assert.ok(existsSync(step));
    assert.ok(statSync(step).size > 0);
  });

  it("inspect_assembly walks the exported STEP", async () => {
    const step = join(SCENE_DIR, "scene.step");
    const r = await verb.inspectAssembly(undefined, step);
    const data = parseJSON(r);
    assert.ok(data.root);
    assert.ok(typeof data.totalComponents === "number");
  });

  it("compare_versions sees the bodies added across the chain", async () => {
    const r = await scene.compareVersions(1);
    const text = r.content[0].text;
    // After the chain, the most recent mutation was heal_shape (added cyl_healed)
    // or mirror_or_pattern. compare_versions(since=1) compares current vs the
    // prior snapshot, so we just check the structure parses.
    const data = JSON.parse(text);
    assert.ok("added" in data);
    assert.ok("removed" in data);
  });

  it("remove_body cleans the merged body", async () => {
    const r = await scene.removeBody("merged");
    assert.match(r.content[0].text, /Removed body "merged"/);
  });

  it("clear_scene wipes everything", async () => {
    const r = await scene.clearScene(false);
    assert.match(r.content[0].text, /Cleared/);
    const finalManifest = JSON.parse(
      readFileSync(join(SCENE_DIR, "manifest.json"), "utf-8")
    );
    assert.equal(finalManifest.bodies.length, 0);
  });
});
