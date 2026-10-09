// Checks the keeper steps of the Apex workflow. Run: npm run test:ci-org
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const FILE = new URL("../../.github/workflows/apex-tests.yml", import.meta.url);
const lines = readFileSync(FILE, "utf8").split("\n");
const STEP = /^(\s*)- (name|uses|run|id):/;

// Returns the body of the step with this name: from its "- name:" line to the next step.
function stepBody(name) {
  const start = lines.findIndex((l) => l.trim() === `- name: ${name}`);
  assert.notEqual(start, -1, `step not found: ${name}`);
  const indent = lines[start].match(/^\s*/)[0].length;
  const body = [lines[start]];
  for (const l of lines.slice(start + 1)) {
    const m = l.match(STEP);
    if (m && m[1].length === indent) break;
    body.push(l);
  }
  return body;
}

// Returns the "if:" condition of a step, with comments removed and spaces folded.
function condition(name) {
  const body = stepBody(name).filter((l) => !l.trim().startsWith("#"));
  const i = body.findIndex((l) => /^\s*if:/.test(l));
  assert.notEqual(i, -1, `no if: in step: ${name}`);
  let text = body[i].replace(/^\s*if:\s*/, "");
  if (/^[>|][+-]?$/.test(text.trim())) {
    text = "";
    for (const l of body.slice(i + 1)) {
      if (/^\s*[a-z-]+:/.test(l) && !l.includes("steps.")) break;
      text += ` ${l}`;
    }
  }
  return text.replace(/^\$\{\{|\}\}$/g, "").replace(/\s+/g, " ").trim();
}

const LOOKUP = "Check that the shared CI org was cached";
const DELETE = "Delete a scratch org that nobody can reuse";

test("the cache lookup runs after a cancel, for a new keeper org only", () => {
  assert.equal(condition(LOOKUP), "always() && steps.org.outputs.save == 'true'");
});

test("the cache lookup step has the id that the delete step reads", () => {
  assert.match(stepBody(LOOKUP).join("\n"), /^\s*id: cached\s*$/m);
});

test("the delete step runs after a cancel and covers every case", () => {
  const c = condition(DELETE);
  assert.ok(c.startsWith("always() &&"), "needs always()");
  assert.ok(c.includes("steps.org.outputs.source == 'oneoff'"), "one-off org");
  assert.ok(
    c.includes("steps.org.outputs.save == 'true' && steps.cached.outcome != 'success'"),
    "new org that is not cached",
  );
  assert.ok(c.includes("hashFiles('.ci-org-creating') != ''"), "marker file");
});
