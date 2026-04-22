import { execFile } from "child_process";
import { readFile, readdir, writeFile, unlink } from "fs/promises";
import { existsSync } from "fs";
import { join } from "path";
import { promisify } from "util";
import { outputDir, manifestPath, tempScriptPath } from "./paths.js";
import { API_REFERENCE } from "./api-reference.js";
import { resolveOcctkit } from "./occtkit.js";

const execFileAsync = promisify(execFile);

/** Source of the most recent script run in this MCP session, for `get_script`. */
let lastScriptCode: string | undefined;

/**
 * Filter out noisy compiler warnings (OCCT bridge nullability warnings, etc.)
 * and keep only meaningful output: script print statements, build summary, errors.
 */
function filterBuildOutput(raw: string): string {
  const lines = raw.split("\n");
  const kept: string[] = [];
  for (const line of lines) {
    // Skip OCCT bridge nullability warnings and their context
    if (
      line.includes("nullability type specifier") ||
      line.includes("insert '_Nullable'") ||
      line.includes("insert '_Nonnull'") ||
      line.includes("insert '_Null_unspecified'") ||
      line.includes("<module-includes>:") ||
      line.includes("in file included from <module-includes>") ||
      line.includes('#import "OCCTBridge.h"') ||
      // Skip pure line-number-only context lines from warnings
      /^\s*\d+\s*\|\s*$/.test(line) ||
      // Skip caret/note lines from warnings
      /^\s*\|.*(?:warning|note):/.test(line) ||
      /^\s*\|\s*[`|]-/.test(line)
    ) {
      continue;
    }
    kept.push(line);
  }
  return kept.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

// ── execute_script ──────────────────────────────────────────────────────────

export async function executeScript(
  code: string,
  description?: string
): Promise<{ content: Array<{ type: "text"; text: string }> }> {
  const scriptPath = tempScriptPath();
  await writeFile(scriptPath, code, "utf-8");
  lastScriptCode = code;

  try {
    const oc = await resolveOcctkit();
    try {
      const { stdout, stderr } = await execFileAsync(
        oc.command,
        [...oc.baseArgs, scriptPath],
        {
          cwd: oc.cwd,
          timeout: 120_000, // 2 min for first build; incremental ~1–2s
          maxBuffer: 10 * 1024 * 1024,
        }
      );

      const filteredStdout = filterBuildOutput(stdout || "");
      const filteredStderr = filterBuildOutput(stderr || "");
      const output = [filteredStdout, filteredStderr].filter(Boolean).join("\n").trim();

      let manifest = "";
      const mp = manifestPath();
      if (existsSync(mp)) {
        const raw = await readFile(mp, "utf-8");
        manifest = `\n\nManifest:\n${raw}`;
      }

      return {
        content: [
          {
            type: "text" as const,
            text: `Script executed successfully.${description ? ` (${description})` : ""}\n\nOutput:\n${output || "(no output)"}${manifest}`,
          },
        ],
      };
    } catch (err: unknown) {
      const error = err as { stdout?: string; stderr?: string; message?: string };
      const parts = [
        filterBuildOutput(error.stdout || ""),
        filterBuildOutput(error.stderr || ""),
      ].filter(Boolean);

      const output = parts.join("\n").trim() || error.message || "Unknown error";

      return {
        content: [
          {
            type: "text" as const,
            text: `Script failed.\n\n${output}`,
          },
        ],
      };
    }
  } finally {
    await unlink(scriptPath).catch(() => {});
  }
}

// ── get_scene ───────────────────────────────────────────────────────────────

export async function getScene(): Promise<{
  content: Array<{ type: "text"; text: string }>;
}> {
  const mp = manifestPath();
  if (!existsSync(mp)) {
    return {
      content: [{ type: "text" as const, text: "No scene loaded. Run execute_script first." }],
    };
  }

  const raw = await readFile(mp, "utf-8");
  const manifest = JSON.parse(raw);

  // Also list files in output directory
  const dir = outputDir();
  const files = existsSync(dir) ? await readdir(dir) : [];

  return {
    content: [
      {
        type: "text" as const,
        text: `Current scene:\n${JSON.stringify(manifest, null, 2)}\n\nOutput files: ${files.join(", ")}`,
      },
    ],
  };
}

// ── get_script ──────────────────────────────────────────────────────────────

export async function getScript(): Promise<{
  content: Array<{ type: "text"; text: string }>;
}> {
  if (lastScriptCode === undefined) {
    return {
      content: [
        {
          type: "text" as const,
          text: "No script has been executed in this session. Call execute_script first.",
        },
      ],
    };
  }
  return {
    content: [{ type: "text" as const, text: lastScriptCode }],
  };
}

// ── export_model ────────────────────────────────────────────────────────────

export async function exportModel(): Promise<{
  content: Array<{ type: "text"; text: string }>;
}> {
  const dir = outputDir();
  if (!existsSync(dir)) {
    return {
      content: [
        { type: "text" as const, text: "No output directory found. Run execute_script first." },
      ],
    };
  }

  const files = await readdir(dir);
  const modelFiles = files.filter(
    (f) =>
      f.endsWith(".step") ||
      f.endsWith(".brep") ||
      f.endsWith(".stl") ||
      f.endsWith(".obj") ||
      f.endsWith(".json")
  );

  if (modelFiles.length === 0) {
    return {
      content: [{ type: "text" as const, text: "No model files found in output." }],
    };
  }

  const paths = modelFiles.map((f) => join(dir, f));
  return {
    content: [
      {
        type: "text" as const,
        text: `Exported model files:\n${paths.join("\n")}`,
      },
    ],
  };
}

// ── get_api_reference ───────────────────────────────────────────────────────

export async function getApiReference(
  category: string
): Promise<{ content: Array<{ type: "text"; text: string }> }> {
  if (category === "all") {
    const all = Object.entries(API_REFERENCE)
      .map(([cat, ref]) => `## ${cat}\n${ref}`)
      .join("\n\n");
    return { content: [{ type: "text" as const, text: all }] };
  }

  const ref = API_REFERENCE[category];
  if (!ref) {
    return {
      content: [
        {
          type: "text" as const,
          text: `Unknown category: ${category}. Available: ${Object.keys(API_REFERENCE).join(", ")}`,
        },
      ],
    };
  }

  return { content: [{ type: "text" as const, text: ref }] };
}
