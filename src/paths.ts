import { homedir, tmpdir } from "os";
import { join } from "path";
import { existsSync } from "fs";
import { randomUUID } from "crypto";

/** Root of the OCCTSwiftScripts project — used as a fallback when occtkit is not on $PATH. */
export const SCRIPTS_PROJECT = join(homedir(), "Projects", "OCCTSwiftScripts");

/** Path for a fresh per-call script tempfile. */
export function tempScriptPath(): string {
  return join(tmpdir(), `occtmcp-script-${randomUUID()}.swift`);
}

/** Output directory — prefers iCloud Drive, falls back to local. */
export function outputDir(): string {
  const icloud = join(
    homedir(),
    "Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output"
  );
  const local = join(homedir(), ".occtswift-scripts/output");

  // Check if iCloud container exists (parent of OCCTSwiftScripts)
  const icloudParent = join(
    homedir(),
    "Library/Mobile Documents/com~apple~CloudDocs"
  );
  if (existsSync(icloudParent)) {
    return icloud;
  }
  return local;
}

/** Path to the manifest.json trigger file. */
export function manifestPath(): string {
  return join(outputDir(), "manifest.json");
}
