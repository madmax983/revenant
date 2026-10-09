// Checks the keeper steps of the Apex workflow. Run: npm run test:ci-org
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const FILE = new URL("../../.github/workflows/apex-tests.yml", import.meta.url);
const text = readFileSync(FILE, "utf8");

// Returns the lines of the step with this name, up to the next step.
function step(name) {
  const lines = text.split("\n");
  const start = lines.findIndex((l) => l.trim() === `- name: ${name}`);
  assert.notEqual(start, -1, `step not found: ${name}`);
  let end = lines.findIndex((l, i) => i > start && /^\s*- name: /.test(l));
  if (end === -1) end = lines.length;
  return lines.slice(start, end).join("\n");
}

test("the cache lookup runs after a cancel", () => {
  const s = step("Check that the shared CI org was cached");
  assert.match(s, /if: always\(\) && steps\.org\.outputs\.save == 'true'/);
});

test("the delete step still deletes a new org that is not cached", () => {
  const s = step("Delete a scratch org that nobody can reuse");
  assert.match(s, /steps\.org\.outputs\.save == 'true' && steps\.cached\.outcome != 'success'/);
});
