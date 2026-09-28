// Frozen global API checks (issue #122). Run: npm run test:global-api
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
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
import {
  buildModel,
  exposedInternals,
  loadClasses,
  parseSources,
  prefixRepoTypes,
  readOnlyWrites,
  ruleViolations,
  stubSources,
  surfaceLines,
} from "./surface.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const CLASSES = join(ROOT, "force-app/main/default/classes");
const MANIFEST = join(ROOT, "docs/global-api.md");
const FIXTURE = "GlobalApiSubscriberTest";
const ENGINE_NS = "rvn";
const SUBSCRIBER_NS = "acme";
const FLOW_ACTIONS = [
  "WorkflowStartInvocableAction",
  "WorkflowSignalInvocableAction",
  "WorkflowStatusInvocableAction",
];

const classes = loadClasses(CLASSES);
const model = buildModel(classes);

function manifestLines() {
  const block = readFileSync(MANIFEST, "utf8").match(
    /```revenant-global-api\n([\s\S]*?)```/,
  );
  assert.ok(block, "docs/global-api.md has no revenant-global-api block");
  return block[1]
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"));
}

// ─── Checker self-tests: each rule finds a known violation ─────────────────

test("checker: finds a global signature that uses a non-global type", () => {
  const m = buildModel(
    parseSources({
      "A.cls": "global class A { global B make() { return null; } }",
      "B.cls": "public class B {}",
    }),
  );
  assert.deepEqual(ruleViolations(m), ["A.make: uses non-global B"]);
});

test("checker: finds a global member in a non-global type", () => {
  const m = buildModel(
    parseSources({ "C.cls": "public class C { global void run() {} }" }),
  );
  assert.deepEqual(ruleViolations(m), [
    "C.run: global member in non-global type",
  ]);
});

test("checker: finds a global inner type in a non-global outer type", () => {
  const m = buildModel(
    parseSources({ "D.cls": "public class D { global class E {} }" }),
  );
  assert.deepEqual(ruleViolations(m), [
    "D.E: global type in non-global type D",
  ]);
});

test("checker: finds a global interface that extends a non-global interface", () => {
  const m = buildModel(
    parseSources({
      "I.cls": "global interface I extends J {}",
      "J.cls": "public interface J {}",
    }),
  );
  assert.deepEqual(ruleViolations(m), ["I: extends non-global J"]);
});

test("checker: finds non-global Flow members in a global class", () => {
  const m = buildModel(
    parseSources({
      "Act.cls":
        "global class Act { @InvocableMethod public static void go(List<Req> r) {} " +
        "global class Req { @InvocableVariable public String x; } }",
    }),
  );
  assert.deepEqual(ruleViolations(m).sort(), [
    "Act.Req.x: @InvocableVariable is not global",
    "Act.go: @InvocableMethod is not global",
  ]);
});

test("checker: finds a global engine internal", () => {
  const m = buildModel(
    parseSources({
      "FooJob.cls": "public class FooJob { global static void x() {} }",
    }),
  );
  assert.deepEqual(exposedInternals(m), ["FooJob"]);
});

test("checker: renders read-only properties, fields, and qualified inner types", () => {
  const m = buildModel(
    parseSources({
      "P.cls":
        "global class P { global Q q { get; private set; } global Integer n { get; set; } " +
        "global String f; global static List<Q> all(Map<String, Q> m) { return null; } " +
        "global class Q {} }",
    }),
  );
  assert.deepEqual(surfaceLines(m), [
    "P.f: String",
    "P.n: Integer { get; set }",
    "P.q: P.Q { get }",
    "global class P",
    "global class P.Q",
    "new P()",
    "new P.Q()",
    "static P.all(Map<String, P.Q>): List<P.Q>",
  ]);
});

test("checker: renders implements on a global class", () => {
  const m = buildModel(
    parseSources({
      "S.cls":
        "global class S implements Comparable, Q { public Integer compareTo(Object o) { return 0; } } ",
      "Q.cls": "global interface Q {}",
    }),
  );
  assert.ok(
    surfaceLines(m).includes("global class S implements Comparable, Q"),
  );
});

test("checker: lists the implicit global constructor, but not for exceptions or explicit ones", () => {
  const m = buildModel(
    parseSources({
      "R.cls":
        "global class R { public R() {} global class E extends Exception {} " +
        "global class D {} global class G { global G(Integer i) {} } }",
    }),
  );
  assert.deepEqual(surfaceLines(m), [
    "global class R",
    "global class R.D",
    "global class R.E extends Exception",
    "global class R.G",
    "new R.D()",
    "new R.G(Integer)",
  ]);
});

test("checker: prefixes repo types but not variables with the same name", () => {
  const m = buildModel(
    parseSources({ "StepResult.cls": "global class StepResult {}" }),
  );
  const src =
    "public class Sub { StepResult go(StepResult stepResult) { " +
    "for (StepResult r : new List<StepResult>()) {} " +
    "String s = 'StepResult'; return stepResult; } }";
  assert.equal(
    prefixRepoTypes(src, m, "rvn", "Sub"),
    "public class Sub { rvn.StepResult go(rvn.StepResult stepResult) { " +
      "for (rvn.StepResult r : new List<rvn.StepResult>()) {} " +
      "String s = 'StepResult'; return stepResult; } }",
  );
});

test("checker: finds a write to a read-only global property", () => {
  const m = buildModel(
    parseSources({
      "P.cls":
        "global class P { global Integer n { get; private set; } global Integer w { get; set; } }",
    }),
  );
  const src = "P p; p.n = 1; p.n++; p.w = 2; Boolean b = p.n == 1;";
  assert.deepEqual(readOnlyWrites(src, m), ["line 1: .n", "line 1: .n"]);
});

// ─── Repo checks ───────────────────────────────────────────────────────────

test("manifest has no duplicate lines", () => {
  const lines = manifestLines();
  const dupes = lines.filter((l, i) => lines.indexOf(l) !== i);
  assert.deepEqual(dupes, []);
});

test("global surface in force-app equals the manifest", () => {
  const actual = new Set(surfaceLines(model));
  const expected = new Set(manifestLines());
  const notInCode = [...expected].filter((l) => !actual.has(l)).sort();
  const notInManifest = [...actual].filter((l) => !expected.has(l)).sort();
  assert.deepEqual(
    { notInCode, notInManifest },
    { notInCode: [], notInManifest: [] },
  );
});

test("global declarations follow the platform rules", () => {
  assert.deepEqual(ruleViolations(model), []);
});

test("engine internals stay namespace-private", () => {
  for (const name of [
    "WorkflowOrchestrator",
    "WorkflowWatchdog",
    "WorkflowFinalizer",
    "WorkflowRetryJob",
  ]) {
    assert.ok(
      model.has(name.toLowerCase()),
      `${name} is missing from the model`,
    );
  }
  assert.deepEqual(exposedInternals(model), []);
});

test("the three Flow actions are global with a global @InvocableMethod", () => {
  for (const name of FLOW_ACTIONS) {
    const t = model.get(name.toLowerCase());
    assert.ok(t?.global, `${name} is not global`);
    const inv = t.members.filter((m) =>
      m.annotations.some((a) => /^invocablemethod$/i.test(a.id().getText())),
    );
    assert.equal(inv.length, 1, `${name} has no @InvocableMethod`);
    assert.ok(inv[0].global, `${name}.${inv[0].name} is not global`);
  }
});

test("the subscriber fixture is a non-global @IsTest class", () => {
  const fixture = model.get(FIXTURE.toLowerCase());
  assert.ok(fixture?.isTest, `${FIXTURE} must be an @IsTest class`);
  assert.ok(!fixture.global, `${FIXTURE} must not be global`);
});

test("the subscriber fixture writes no read-only global property", () => {
  const source = readFileSync(join(CLASSES, `${FIXTURE}.cls`), "utf8");
  assert.deepEqual(readOnlyWrites(source, model), []);
});

// ─── Packaged view: compile against the global API only ───────────────────

function apexLsClasspath() {
  if (process.env.APEX_LS_CLASSPATH) return process.env.APEX_LS_CLASSPATH;
  const local = join(HERE, ".apex-ls", "lib");
  return existsSync(local) ? join(local, "*") : null;
}

const META =
  '<?xml version="1.0" encoding="UTF-8"?>\n' +
  '<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">' +
  "<apiVersion>67.0</apiVersion><status>Active</status></ApexClass>\n";

function writeProject(dir, namespace, files, dependency) {
  const classesDir = join(dir, "src", "classes");
  mkdirSync(classesDir, { recursive: true });
  const project = {
    packageDirectories: [{ path: "src", default: true }],
    namespace,
    sourceApiVersion: "67.0",
  };
  if (dependency) project.plugins = { dependencies: [dependency] };
  writeFileSync(
    join(dir, "sfdx-project.json"),
    JSON.stringify(project, null, 2),
  );
  for (const [name, source] of Object.entries(files)) {
    writeFileSync(join(classesDir, name), source);
    writeFileSync(join(classesDir, `${name}-meta.xml`), META);
  }
}

/** Runs apex-ls on a workspace. Returns the error and missing-type messages. */
function apexLsErrors(classpath, workspace) {
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
  const json = JSON.parse(run.stdout.slice(run.stdout.indexOf("{")));
  return json.files.flatMap((f) =>
    f.messages.map(
      (m) =>
        `${f.path.split("/").pop()}:${m.start.line} ${m.category}: ${m.message}`,
    ),
  );
}

test("packaged view: the subscriber fixture compiles in a foreign namespace", (t) => {
  const classpath = apexLsClasspath();
  const java = spawnSync("java", ["-version"]);
  if (!classpath || java.status !== 0) {
    const why =
      "needs Java and apex-ls (run scripts/global-api/fetch-apex-ls.sh)";
    if (process.env.REQUIRE_APEX_LS) assert.fail(why);
    t.skip(why);
    return;
  }
  const work = mkdtempSync(join(tmpdir(), "revenant-global-api-"));
  try {
    const engineDir = join(work, ENGINE_NS);
    const subscriberDir = join(work, SUBSCRIBER_NS);
    writeProject(engineDir, ENGINE_NS, stubSources(model));
    assert.deepEqual(
      apexLsErrors(classpath, engineDir),
      [],
      "the stub of the global API does not compile",
    );

    const source = readFileSync(join(CLASSES, `${FIXTURE}.cls`), "utf8");
    const probe =
      "@IsTest public class NonGlobalProbe { static void probe() { " +
      "WorkflowEngine.runStep(null); StepContext.Builder b; } }";
    writeProject(
      subscriberDir,
      SUBSCRIBER_NS,
      {
        [`${FIXTURE}.cls`]: prefixRepoTypes(source, model, ENGINE_NS, FIXTURE),
        "NonGlobalProbe.cls": prefixRepoTypes(
          probe,
          model,
          ENGINE_NS,
          "NonGlobalProbe",
        ),
      },
      { namespace: ENGINE_NS, path: engineDir },
    );
    const errors = apexLsErrors(classpath, subscriberDir);
    const fixtureErrors = errors.filter((e) => e.startsWith(`${FIXTURE}.cls`));
    const probeErrors = errors.filter((e) =>
      e.startsWith("NonGlobalProbe.cls"),
    );
    assert.deepEqual(
      fixtureErrors,
      [],
      "the fixture uses a member that is not global",
    );
    // Negative control: the packaged view must reject a namespace-private member and type.
    assert.equal(
      probeErrors.length,
      2,
      `the probe must fail twice, got: ${probeErrors.join(" | ")}`,
    );
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
