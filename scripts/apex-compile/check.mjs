#!/usr/bin/env node
// Compiles every package folder in sfdx-project.json with apex-ls. No org, no signup.
// A scratch org compile can fail on a rule that the code never broke before (a name that
// is shadowed by a local variable, a reserved word, a lock query with ORDER BY). apex-ls
// finds the Apex ones. Its limits: it does not check SOQL locking rules, Batchable
// placement or the order of elements in metadata XML.
// Run: npm run check:apex-compile   (needs Java and apex-ls: scripts/global-api/fetch-apex-ls.sh;
// check out the submodule: git submodule update --init)
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { apexLsClasspath, apexLsErrors, apexLsMissing } from "../global-api/apex-ls.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

/** The package folders of the project that exist and hold files. */
export function packageFolders(projectFile = join(ROOT, "sfdx-project.json")) {
  const project = JSON.parse(readFileSync(projectFile, "utf8"));
  const base = dirname(projectFile);
  const found = [];
  const missing = [];
  for (const { path } of project.packageDirectories) {
    const dir = join(base, path);
    (existsSync(dir) && readdirSync(dir).length > 0 ? found : missing).push(path);
  }
  return { project, found, missing };
}

/** Builds a temp workspace that links each folder, so apex-ls sees a normal project. */
export function makeWorkspace(root = ROOT) {
  const { project, found, missing } = packageFolders(join(root, "sfdx-project.json"));
  const ws = mkdtempSync(join(tmpdir(), "apex-compile-"));
  for (const path of found) {
    mkdirSync(dirname(join(ws, path)), { recursive: true });
    symlinkSync(join(root, path), join(ws, path), "dir");
  }
  // Only the folders that exist: apex-ls fails on a missing one.
  const kept = {
    ...project,
    packageDirectories: project.packageDirectories.filter((d) => found.includes(d.path)),
  };
  writeFileSync(join(ws, "sfdx-project.json"), `${JSON.stringify(kept, null, 2)}\n`);
  return { ws, found, missing };
}

export async function main() {
  const why = apexLsMissing();
  if (why) {
    if (process.env.REQUIRE_APEX_LS) {
      console.error(`::error::${why}`);
      return 1;
    }
    console.log(`Skipped: ${why}`);
    return 0;
  }
  const { ws, found, missing } = makeWorkspace();
  try {
    if (missing.length) {
      const note = `Not compiled (empty or missing): ${missing.join(", ")}. Run git submodule update --init.`;
      if (process.env.REQUIRE_SUBMODULES) {
        console.error(`::error::${note}`);
        return 1;
      }
      console.log(`Note: ${note}`);
    }
    const issues = apexLsErrors(apexLsClasspath(), ws);
    for (const issue of issues) console.log(`::error::${issue}`);
    console.log(`apex-ls compiled ${found.join(", ")}: ${issues.length} issue(s).`);
    return issues.length === 0 ? 0 : 1;
  } finally {
    rmSync(ws, { recursive: true, force: true });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(await main());
}
