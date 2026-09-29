// Static checks of the quickstart path (issue #133). Run: npm run test:quickstart
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DEPLOY_SOURCES } from "./smoke.mjs";
import {
  META,
  apexLsClasspath,
  apexLsErrors,
  apexLsMissing,
} from "../global-api/apex-ls.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const read = (path) => readFileSync(join(ROOT, path), "utf8");

const DOC = "docs/quickstart.md";
const HELLO = "examples/quickstart/classes/HelloWorkflow.cls";
const RUN = "scripts/apex/run-hello.apex";
const VERIFY = "scripts/apex/verify-hello.apex";
const CI = ".github/workflows/quickstart.yml";

test("README links the quickstart above the feature list", () => {
  const readme = read("README.md");
  const link = readme.indexOf("(docs/quickstart.md)");
  assert.ok(link >= 0, "README has no link to docs/quickstart.md");
  assert.ok(
    link < readme.indexOf("## Key Features"),
    "the quickstart link is below Key Features",
  );
});

test("the quickstart gives the commands in order", () => {
  const doc = read(DOC);
  const deploy = `sf project deploy start ${DEPLOY_SOURCES.map((s) => `--source-dir ${s}`).join(" ")}`;
  const steps = [
    "sf org create scratch --definition-file config/quickstart-scratch-def.json",
    deploy,
    "sf org assign permset --name Revenant_Admin",
    `sf apex run --file ${RUN}`,
    `sf apex run --file ${VERIFY}`,
  ];
  let last = -1;
  for (const step of steps) {
    const at = doc.indexOf(step, last + 1);
    assert.ok(at > last, `missing or out of order: ${step}`);
    last = at;
  }
});

test("each repo path in the quickstart exists", () => {
  const doc = read(DOC);
  const paths = [
    ...doc.matchAll(
      /`((?:config|docs|examples|scripts|force-app|\.github)\/[^`\s]*)`/g,
    ),
  ].map((m) => m[1]);
  assert.ok(paths.length >= 5, `too few paths: ${paths}`);
  for (const path of paths) {
    assert.ok(
      existsSync(join(ROOT, path)),
      `${DOC} names a missing path: ${path}`,
    );
  }
});

test("HelloWorkflow stays minimal", () => {
  // Code only: the comments can name what the example does not use.
  const source = read(HELLO).replace(/\/\*[\s\S]*?\*\/|\/\/.*$/gm, "");
  const steps = source.match(
    /getSteps\(\)\s*\{\s*return new List<String>\{([^}]*)\}/,
  );
  assert.ok(steps, "no getSteps() list");
  const count = steps[1].split(",").filter((s) => s.trim()).length;
  assert.ok(count >= 1 && count <= 2, `HelloWorkflow has ${count} steps`);
  const banned =
    /\bHttp\b|callout|CompensatableStep|Workflow_Signal__c|signals\(\)|StepResult\.(sleep|suspend|split|startChild|waitForApproval|retry|continueAsNew)/;
  assert.doesNotMatch(source, banned);
});

test("the scripts use only the public API and do no DML", () => {
  const run = read(RUN);
  assert.match(run, /WorkflowEngine\.start\(/);
  assert.match(run, /HELLO_INSTANCE_ID=/);
  const verify = read(VERIFY);
  assert.match(verify, /HelloWorkflowCheck\.verifyLatest\(\)/);
  assert.match(verify, /HELLO_VERIFY: /);
  for (const source of [run, verify]) {
    assert.doesNotMatch(
      source,
      /WorkflowOrchestrator|runStep|\b(insert|update|upsert|delete)\s/i,
    );
  }
});

test("CI runs the smoke job with a budget of 10 minutes or less", () => {
  const ci = read(CI);
  assert.match(ci, /npm run test:quickstart/);
  assert.match(ci, /scripts\/quickstart\/smoke\.mjs/);
  const budget = ci.match(/QUICKSTART_MAX_SECONDS:\s*"?(\d+)"?/);
  assert.ok(budget, "CI declares no QUICKSTART_MAX_SECONDS");
  assert.ok(Number(budget[1]) <= 600, `budget ${budget[1]} s is over 600 s`);
  assert.match(ci, /--max-seconds "?\$\{\{ env\.QUICKSTART_MAX_SECONDS \}\}"?/);
});

// ─── Compile: the Hello classes and both scripts ──────────────────────────

/** Puts each script body in a method, so apex-ls can compile it. */
function scriptProbe() {
  const method = (name, path) =>
    `  static void ${name}() {\n${read(path)}\n  }\n`;
  return (
    "public class QuickstartScriptProbe {\n" +
    method("runHello", RUN) +
    method("verifyHello", VERIFY) +
    "}\n"
  );
}

test("apex-ls compiles the Hello classes and both scripts", (t) => {
  const why = apexLsMissing();
  if (why) {
    if (process.env.REQUIRE_APEX_LS) assert.fail(why);
    t.skip(why);
    return;
  }
  const work = mkdtempSync(join(tmpdir(), "revenant-quickstart-"));
  try {
    cpSync(join(ROOT, "force-app"), join(work, "force-app"), {
      recursive: true,
    });
    cpSync(join(ROOT, "examples/quickstart"), join(work, "quickstart"), {
      recursive: true,
    });
    const probe = join(work, "quickstart", "probe");
    mkdirSync(probe, { recursive: true });
    writeFileSync(join(probe, "QuickstartScriptProbe.cls"), scriptProbe());
    writeFileSync(join(probe, "QuickstartScriptProbe.cls-meta.xml"), META);
    writeFileSync(
      join(work, "sfdx-project.json"),
      JSON.stringify({
        packageDirectories: [
          { path: "force-app", default: true },
          { path: "quickstart" },
        ],
        namespace: "",
        sourceApiVersion: "67.0",
      }),
    );
    // Only the quickstart files. apex-ls reports false positives in the engine.
    const errors = apexLsErrors(apexLsClasspath(), work, (path) =>
      path.split(/[\\/]/).includes("quickstart"),
    );
    assert.deepEqual(errors, []);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
