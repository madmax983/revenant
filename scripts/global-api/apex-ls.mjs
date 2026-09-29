// Shared apex-ls helpers for the Node tests. apex-ls compiles Apex without an org.
// To download it: scripts/global-api/fetch-apex-ls.sh (needs Java and Maven).
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/** Class meta file for API 67.0. */
export const META =
  '<?xml version="1.0" encoding="UTF-8"?>\n' +
  '<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">' +
  "<apiVersion>67.0</apiVersion><status>Active</status></ApexClass>\n";

/** The apex-ls classpath, or null if apex-ls is not downloaded. */
export function apexLsClasspath() {
  if (process.env.APEX_LS_CLASSPATH) return process.env.APEX_LS_CLASSPATH;
  const local = join(HERE, ".apex-ls", "lib");
  return existsSync(local) ? join(local, "*") : null;
}

/**
 * Gives the reason to skip when Java or apex-ls is missing, else null.
 * With REQUIRE_APEX_LS set, a missing tool is a failure, not a skip.
 */
export function apexLsMissing() {
  const java = spawnSync("java", ["-version"]);
  if (apexLsClasspath() && java.status === 0) return null;
  return "needs Java and apex-ls (run scripts/global-api/fetch-apex-ls.sh)";
}

/** Runs apex-ls on a workspace. Returns "File.cls:line Category: message" rows. */
export function apexLsErrors(classpath, workspace, keepFile = () => true) {
  const run = spawnSync(
    "java",
    [
      "-cp",
      classpath,
      "io.github.apexdevtools.apexls.CheckForIssues",
      "-n",
      "-f",
      "json",
      "-w",
      workspace,
    ],
    { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  if (run.error) throw run.error;
  // apex-ls exits 0 with no issue and 4 with issues.
  if (![0, 4].includes(run.status) || !run.stdout.includes("{")) {
    throw new Error(`apex-ls failed (exit ${run.status}): ${run.stderr}`);
  }
  const json = JSON.parse(run.stdout.slice(run.stdout.indexOf("{")));
  return json.files
    .filter((f) => keepFile(f.path))
    .flatMap((f) =>
      f.messages.map(
        (m) =>
          `${f.path.split(/[\\/]/).pop()}:${m.start.line} ${m.category}: ${m.message}`,
      ),
    );
}
