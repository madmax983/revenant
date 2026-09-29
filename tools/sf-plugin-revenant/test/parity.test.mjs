// The native CLI and the sf plugin give the same report for the same files.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { loadEngine } from "../src/engine.js";
import { collectSources } from "../src/sources.js";

const root = fileURLToPath(new URL("..", import.meta.url));
const corpus = "../revenant-lint/tests/corpus";
const hasCargo = spawnSync("cargo", ["--version"]).status === 0;

test("native CLI and wasm core agree on the seed corpus", { skip: !hasCargo && "cargo not found" }, async () => {
  const native = spawnSync(
    "cargo",
    ["run", "--quiet", "--manifest-path", "../revenant-lint/Cargo.toml", "--", "--json", "--fail-on", "never", corpus],
    { cwd: root, encoding: "utf8" },
  );
  assert.equal(native.status, 0, native.stderr);
  const engine = await loadEngine();
  const plugin = engine.lint(collectSources([corpus], root));
  assert.deepEqual(plugin, JSON.parse(native.stdout));
  assert.ok(plugin.defects.length > 25);
});
