// sf revenant lint determinism: flags, output, JSON envelope, and the gate.
import { afterEach, test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { Config } from "@oclif/core";

const root = fileURLToPath(new URL("..", import.meta.url));
const fixtures = join(root, "test", "fixtures");

/** Runs the command. Returns the result, the text output and the exit code. */
async function run(args, cwd = root) {
  const config = await Config.load(root);
  const Command = await config.findCommand("revenant:lint:determinism").load();
  const out = [];
  const write = process.stdout.write;
  const errWrite = process.stderr.write;
  const oldCwd = process.cwd();
  process.stdout.write = (chunk) => (out.push(String(chunk)), true);
  process.stderr.write = (chunk) => (out.push(String(chunk)), true);
  process.chdir(cwd);
  try {
    const result = await Command.run(args, config);
    return { result, text: out.join(""), exitCode: process.exitCode };
  } finally {
    process.chdir(oldCwd);
    process.stdout.write = write;
    process.stderr.write = errWrite;
  }
}

afterEach(() => {
  process.exitCode = undefined;
});

test("the command is registered under the revenant topic", async () => {
  const config = await Config.load(root);
  assert.ok(config.findCommand("revenant:lint:determinism"));
});

test("a HIGH defect fails the gate and names the file and line", async () => {
  const dir = join(fixtures, "project", "force-app");
  const { result, text, exitCode } = await run(["--source-dir", dir]);
  assert.equal(exitCode, 1);
  assert.equal(result.defects[0].rule, "CLOCK_READ");
  assert.match(text, /ClockStep\.cls:3:\d+ HIGH CLOCK_READ/);
  assert.match(text, /once\(/);
});

test("clean source passes", async () => {
  const { result, text, exitCode } = await run(["--source-dir", join(fixtures, "clean")]);
  assert.equal(exitCode, undefined);
  assert.deepEqual(result.defects, []);
  assert.match(text, /0 defects/);
});

test("--fail-on sets the gate level", async () => {
  const medium = join(fixtures, "medium");
  assert.equal((await run(["-d", medium])).exitCode, undefined);
  process.exitCode = undefined;
  assert.equal((await run(["-d", medium, "--fail-on", "medium"])).exitCode, 1);
  process.exitCode = undefined;
  const high = join(fixtures, "project", "force-app");
  assert.equal((await run(["-d", high, "--fail-on", "never"])).exitCode, undefined);
});

test("--json prints the envelope with the report and the gate status", async () => {
  const dir = join(fixtures, "project", "force-app");
  const { text, exitCode } = await run(["--source-dir", dir, "--json"]);
  const envelope = JSON.parse(text);
  assert.equal(exitCode, 1);
  assert.equal(envelope.status, 1);
  assert.equal(envelope.result.defects[0].code, "NON_DETERMINISTIC_SOURCE");
});

test("more than one --source-dir is one project", async () => {
  const { result } = await run([
    "-d",
    join(fixtures, "project", "force-app"),
    "-d",
    join(fixtures, "project", "other"),
  ]);
  assert.deepEqual(
    result.defects.map((d) => d.rule),
    ["CLOCK_READ", "RANDOM_VALUE"],
  );
});

test("with no flag, the package directories of the project are scanned", async () => {
  const cwd = join(fixtures, "project");
  const { result, text } = await run([], cwd);
  assert.equal(result.filesScanned, 1);
  assert.equal(result.defects[0].file, join("force-app", "main", "default", "classes", "ClockStep.cls"));
  assert.match(text, /missing-submodule/);
});

test("errors that are not defects exit 2", async () => {
  const exit2 = (pattern) => (e) => e.exitCode === 2 && pattern.test(e.message);
  await assert.rejects(run([], "/"), exit2(/sfdx-project\.json/));
  await assert.rejects(run(["-d", "no-such-dir"]), exit2(/not found/));
  await assert.rejects(run(["-d", join(fixtures, "empty")]), exit2(/No \.cls files/));
  await assert.rejects(run([], join(fixtures, "missing-project")), exit2(/No \.cls files/));
});
