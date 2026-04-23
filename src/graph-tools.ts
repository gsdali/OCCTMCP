import { execFile } from "child_process";
import { existsSync } from "fs";
import { promisify } from "util";
import { resolveOcctkit } from "./occtkit.js";

const execFileAsync = promisify(execFile);

type ToolResult = { content: Array<{ type: "text"; text: string }> };

/**
 * One-shot invocation of a pre-compiled occtkit verb (`graph-validate`,
 * `graph-compact`, `graph-dedup`, `graph-ml`, `feature-recognize`). These
 * verbs don't compile Swift at call time, so there's no cold-start to
 * amortise — plain execFile is fine.
 *
 * On success the verb writes one JSON document to stdout. On failure it
 * writes a line like "Error: …" to stderr and exits non-zero.
 */
async function runVerb(
  verb: string,
  verbArgs: string[],
  timeoutMs = 60_000
): Promise<
  | { ok: true; stdout: string }
  | { ok: false; error: string; stderr: string }
> {
  const oc = await resolveOcctkit();
  try {
    const { stdout } = await execFileAsync(
      oc.command,
      [...oc.baseArgs, verb, ...verbArgs],
      {
        cwd: oc.cwd,
        timeout: timeoutMs,
        maxBuffer: 50 * 1024 * 1024,
      }
    );
    return { ok: true, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { stderr?: string; message?: string };
    return {
      ok: false,
      error: e.message ?? "unknown error",
      stderr: (e.stderr ?? "").trim(),
    };
  }
}

function requirePath(path: string, kind: string): ToolResult | null {
  if (!existsSync(path)) {
    return {
      content: [
        {
          type: "text" as const,
          text: `${kind} not found: ${path}\nCheck the path. Use export_model to list available files.`,
        },
      ],
    };
  }
  return null;
}

function formatVerbResult(
  verb: string,
  result: Awaited<ReturnType<typeof runVerb>>
): ToolResult {
  if (result.ok) {
    return { content: [{ type: "text" as const, text: result.stdout }] };
  }
  const tail = result.stderr ? `\n\n${result.stderr}` : "";
  return {
    content: [
      {
        type: "text" as const,
        text: `occtkit ${verb} failed.\n\n${result.error}${tail}`,
      },
    ],
  };
}

// ── graph_validate ──────────────────────────────────────────────────────────

export async function graphValidate(brepPath: string): Promise<ToolResult> {
  const missing = requirePath(brepPath, "BREP file");
  if (missing) return missing;
  return formatVerbResult("graph-validate", await runVerb("graph-validate", [brepPath]));
}

// ── graph_compact ───────────────────────────────────────────────────────────

export async function graphCompact(
  brepPath: string,
  outputPath: string
): Promise<ToolResult> {
  const missing = requirePath(brepPath, "BREP file");
  if (missing) return missing;
  return formatVerbResult(
    "graph-compact",
    await runVerb("graph-compact", [brepPath, outputPath])
  );
}

// ── graph_dedup ─────────────────────────────────────────────────────────────

export async function graphDedup(
  brepPath: string,
  outputPath: string
): Promise<ToolResult> {
  const missing = requirePath(brepPath, "BREP file");
  if (missing) return missing;
  return formatVerbResult(
    "graph-dedup",
    await runVerb("graph-dedup", [brepPath, outputPath])
  );
}

// ── graph_ml ────────────────────────────────────────────────────────────────

export async function graphMl(
  brepPath: string,
  uvSamples?: number,
  edgeSamples?: number
): Promise<ToolResult> {
  const missing = requirePath(brepPath, "BREP file");
  if (missing) return missing;
  const args = [brepPath];
  if (uvSamples !== undefined) args.push("--uv-samples", String(uvSamples));
  if (edgeSamples !== undefined) args.push("--edge-samples", String(edgeSamples));
  return formatVerbResult("graph-ml", await runVerb("graph-ml", args, 180_000));
}

// ── feature_recognize ───────────────────────────────────────────────────────

export async function featureRecognize(brepPath: string): Promise<ToolResult> {
  const missing = requirePath(brepPath, "BREP file");
  if (missing) return missing;
  return formatVerbResult(
    "feature-recognize",
    await runVerb("feature-recognize", [brepPath])
  );
}
