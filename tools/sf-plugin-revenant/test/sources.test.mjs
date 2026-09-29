// Source discovery: sfdx-project.json package directories and the .cls walk.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { collectSources, projectSourceDirs } from "../src/sources.js";

const fixtures = fileURLToPath(new URL("./fixtures/", import.meta.url));

test("package directories come from the nearest sfdx-project.json", () => {
  const nested = join(fixtures, "project", "force-app", "main");
  const { root, dirs, missing } = projectSourceDirs(nested);
  assert.equal(root, join(fixtures, "project"));
  assert.deepEqual(dirs, [join(fixtures, "project", "force-app")]);
  assert.deepEqual(missing, [join(fixtures, "project", "missing-submodule")]);
});

test("no sfdx-project.json gives null", () => {
  assert.equal(projectSourceDirs(mkdtempSync(join(tmpdir(), "rl-none-"))), null);
});

test("the walk reads .cls files only and skips hidden, node_modules and links", () => {
  const root = mkdtempSync(join(tmpdir(), "rl-walk-"));
  const put = (rel, text = "public class X {}") => {
    mkdirSync(join(root, rel, ".."), { recursive: true });
    writeFileSync(join(root, rel), text);
  };
  put("a/b/A.cls");
  put("a/B.CLS");
  put("a/A.cls-meta.xml");
  put("a/T.trigger");
  put(".sf/H.cls");
  put("node_modules/p/N.cls");
  symlinkSync(join(root, "a"), join(root, "loop"));
  symlinkSync(join(root, "a", "B.CLS"), join(root, "Link.cls"));
  const files = collectSources([root], root);
  assert.deepEqual(
    files.map((f) => f.path),
    [join("a", "B.CLS"), join("a", "b", "A.cls")],
  );
  assert.equal(files[0].source, "public class X {}");
});

test("a file path is read as is", () => {
  const root = mkdtempSync(join(tmpdir(), "rl-file-"));
  writeFileSync(join(root, "A.cls"), "x");
  assert.deepEqual(collectSources([join(root, "A.cls")], root), [
    { path: "A.cls", source: "x" },
  ]);
});

test("overlapping paths read each file one time", () => {
  const root = mkdtempSync(join(tmpdir(), "rl-overlap-"));
  mkdirSync(join(root, "a"));
  writeFileSync(join(root, "a", "A.cls"), "x");
  const files = collectSources([root, join(root, "a"), join(root, "a", "A.cls")], root);
  assert.deepEqual(files.map((f) => f.path), [join("a", "A.cls")]);
});

test("an invalid sfdx-project.json is an error", () => {
  const root = mkdtempSync(join(tmpdir(), "rl-badproj-"));
  writeFileSync(join(root, "sfdx-project.json"), "{ nope");
  assert.throws(() => projectSourceDirs(root), /not valid JSON/);
  writeFileSync(join(root, "sfdx-project.json"), '{"packageDirectories":[{"default":true}]}');
  assert.throws(() => projectSourceDirs(root), /"path" string/);
});
