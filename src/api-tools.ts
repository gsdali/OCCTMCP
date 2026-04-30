import { execFile } from "child_process";
import { readFile, writeFile, unlink, stat } from "fs/promises";
import { existsSync } from "fs";
import { join, basename, extname } from "path";
import { tmpdir } from "os";
import { promisify } from "util";
import { randomUUID } from "crypto";
import { outputDir, manifestPath } from "./paths.js";
import { resolveOcctkit } from "./occtkit.js";
import { snapshotScene } from "./scene-tools.js";

const execFileAsync = promisify(execFile);

type ToolResult = { content: Array<{ type: "text"; text: string }> };

type Body = {
  id?: string;
  file: string;
  format?: string;
  name?: string;
  color?: number[];
  roughness?: number;
  metallic?: number;
};

type Manifest = {
  version: number;
  timestamp: string;
  description?: string;
  bodies: Body[];
  graphs?: unknown[];
  metadata?: unknown;
};

function text(t: string): ToolResult {
  return { content: [{ type: "text" as const, text: t }] };
}

async function readManifest(): Promise<Manifest | null> {
  if (!existsSync(manifestPath())) return null;
  return JSON.parse(await readFile(manifestPath(), "utf-8")) as Manifest;
}

async function writeManifest(m: Manifest): Promise<void> {
  m.timestamp = new Date().toISOString();
  await writeFile(manifestPath(), JSON.stringify(m, null, 2), "utf-8");
}

function findBody(m: Manifest, bodyId: string): Body | null {
  return m.bodies.find((b) => b.id === bodyId) ?? null;
}

async function runVerb(
  verb: string,
  verbArgs: string[],
  timeoutMs = 60_000
): Promise<{ ok: true; stdout: string } | { ok: false; error: string; stderr: string }> {
  const oc = await resolveOcctkit();
  try {
    const { stdout } = await execFileAsync(
      oc.command,
      [...oc.baseArgs, verb, ...verbArgs],
      { cwd: oc.cwd, timeout: timeoutMs, maxBuffer: 50 * 1024 * 1024 }
    );
    return { ok: true, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { stderr?: string; message?: string };
    return { ok: false, error: e.message ?? "unknown error", stderr: (e.stderr ?? "").trim() };
  }
}

// ── validate_geometry ──────────────────────────────────────────────────────

export async function validateGeometry(bodyId?: string): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");

  const targets = bodyId
    ? m.bodies.filter((b) => b.id === bodyId)
    : m.bodies.filter((b) => b.format === undefined || b.format === "brep");

  if (bodyId && targets.length === 0) return text(`Body not found: ${bodyId}`);
  if (targets.length === 0) return text("No BREP bodies in scene.");

  const dir = outputDir();
  const reports: Array<Record<string, unknown>> = [];
  for (const b of targets) {
    const path = join(dir, b.file);
    if (!existsSync(path)) {
      reports.push({ id: b.id, file: b.file, error: "BREP file missing" });
      continue;
    }
    const r = await runVerb("graph-validate", [path]);
    if (!r.ok) {
      reports.push({ id: b.id, file: b.file, error: r.error, stderr: r.stderr });
      continue;
    }
    try {
      const parsed = JSON.parse(r.stdout) as Record<string, unknown>;
      reports.push({ id: b.id, file: b.file, ...parsed });
    } catch {
      reports.push({ id: b.id, file: b.file, raw: r.stdout });
    }
  }

  return text(JSON.stringify({ bodies: reports }, null, 2));
}

// ── recognize_features ─────────────────────────────────────────────────────

type FeatureKind = "pocket" | "hole";

export async function recognizeFeatures(
  bodyId: string,
  kinds?: FeatureKind[]
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");

  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const path = join(outputDir(), body.file);
  if (!existsSync(path)) return text(`BREP file missing: ${path}`);

  const r = await runVerb("feature-recognize", [path]);
  if (!r.ok) return text(`feature-recognize failed.\n\n${r.error}\n${r.stderr}`);

  let parsed: { pockets?: unknown[]; holes?: unknown[] };
  try {
    parsed = JSON.parse(r.stdout);
  } catch {
    return text(`Could not parse feature-recognize output:\n\n${r.stdout}`);
  }

  const wantPockets = !kinds || kinds.includes("pocket");
  const wantHoles = !kinds || kinds.includes("hole");

  const out: Record<string, unknown> = { bodyId };
  if (wantPockets) out.pockets = parsed.pockets ?? [];
  if (wantHoles) out.holes = parsed.holes ?? [];

  return text(JSON.stringify(out, null, 2));
}

// ── apply_feature ──────────────────────────────────────────────────────────

export async function applyFeature(
  bodyId: string,
  feature: Record<string, unknown>,
  outputBodyId?: string
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");

  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const dir = outputDir();
  const inputPath = join(dir, body.file);
  if (!existsSync(inputPath)) return text(`BREP file missing: ${inputPath}`);

  await snapshotScene();

  const inPlace = !outputBodyId || outputBodyId === bodyId;
  const targetStem = inPlace
    ? basename(body.file, extname(body.file))
    : `applied-${outputBodyId}-${randomUUID().slice(0, 8)}`;
  const targetFile = `${targetStem}.brep`;
  const targetPath = join(dir, targetFile);

  const request = {
    outputDir: dir,
    outputName: targetStem,
    inputBrep: inputPath,
    features: [feature],
  };

  const requestPath = join(tmpdir(), `occtmcp-reconstruct-${randomUUID()}.json`);
  await writeFile(requestPath, JSON.stringify(request), "utf-8");

  try {
    const r = await runVerb("reconstruct", [requestPath], 120_000);
    if (!r.ok) return text(`reconstruct failed.\n\n${r.error}\n${r.stderr}`);

    let report: { shape?: string; fulfilled?: string[]; skipped?: unknown[]; annotations?: unknown[] };
    try {
      report = JSON.parse(r.stdout);
    } catch {
      return text(`Could not parse reconstruct output:\n\n${r.stdout}`);
    }

    if (!report.shape) {
      return text(
        `Reconstruct returned null shape. Skipped:\n${JSON.stringify(report.skipped, null, 2)}`
      );
    }

    if (!existsSync(targetPath)) {
      return text(
        `Reconstruct reported success but output file is missing: ${targetPath}`
      );
    }

    if (inPlace) {
      // file already overwritten in place; manifest is unchanged
    } else {
      m.bodies.push({
        id: outputBodyId,
        file: targetFile,
        format: "brep",
        color: body.color,
        name: body.name,
      });
    }
    await writeManifest(m);

    return text(
      `Applied feature ${JSON.stringify(feature)} to "${bodyId}".\n\n` +
        `Output: ${inPlace ? `(in place) ${body.file}` : `new body "${outputBodyId}" → ${targetFile}`}\n\n` +
        JSON.stringify(report, null, 2)
    );
  } finally {
    await unlink(requestPath).catch(() => {});
  }
}

// ── generate_drawing ───────────────────────────────────────────────────────

export async function generateDrawing(
  bodyId: string,
  outputPath: string,
  spec: Record<string, unknown>
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");

  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const inputPath = join(outputDir(), body.file);
  if (!existsSync(inputPath)) return text(`BREP file missing: ${inputPath}`);

  const fullSpec = { ...spec, shape: inputPath, output: outputPath };
  const specPath = join(tmpdir(), `occtmcp-drawing-${randomUUID()}.json`);
  await writeFile(specPath, JSON.stringify(fullSpec), "utf-8");

  try {
    const r = await runVerb("drawing-export", [specPath], 120_000);
    if (!r.ok) return text(`drawing-export failed.\n\n${r.error}\n${r.stderr}`);

    let size = 0;
    try {
      size = (await stat(outputPath)).size;
    } catch {
      // ignore
    }

    return text(
      `Drawing exported → ${outputPath} (${size} bytes).\n\n${r.stdout}`
    );
  } finally {
    await unlink(specPath).catch(() => {});
  }
}
