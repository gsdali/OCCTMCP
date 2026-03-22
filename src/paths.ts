import { homedir } from "os";
import { join } from "path";
import { existsSync } from "fs";

/** Root of the OCCTSwiftScripts project. */
export const SCRIPTS_PROJECT = join(homedir(), "Projects", "OCCTSwiftScripts");

/** The script source file that gets rewritten on each execute_script call. */
export const MAIN_SWIFT = join(SCRIPTS_PROJECT, "Sources", "Script", "main.swift");

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
