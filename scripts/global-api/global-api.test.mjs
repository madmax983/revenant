// Frozen global API checks (issue #122). Run: npm run test:global-api
import { test } from "node:test";
import assert from "node:assert/strict";
import {
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
  stubOnlyCalls,
  ruleViolations,
  stubSources,
  surfaceLines,
} from "./surface.mjs";
import {
  META,
  apexLsClasspath,
  apexLsErrors,
  apexLsMissing,
} from "./apex-ls.mjs";

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
    /```revenant-global-api\r?\n([\s\S]*?)```/,
  );
  assert.ok(block, "docs/global-api.md has no revenant-global-api block");
  return block[1]
    .split(/\r?\n/)
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
  assert.deepEqual(readOnlyWrites(src, m), ["line 1: p.n", "line 1: p.n"]);
});

test("checker: renders virtual, abstract, webservice, accessors, and annotation arguments", () => {
  const m = buildModel(
    parseSources({
      "V.cls":
        "global virtual class V { global virtual Integer a() { return 1; } " +
        "@Deprecated global static void old() {} " +
        "webservice static void ws() {} " +
        "global Integer k { private get; set; } " +
        "global class R { @InvocableVariable(label='X'   required=true) global String x; } }",
      "B.cls": "global abstract class B { global abstract void run(); }",
    }),
  );
  const lines = surfaceLines(m);
  for (const expected of [
    "global virtual class V",
    "global abstract class B",
    "abstract B.run(): void",
    "virtual V.a(): Integer",
    "@Deprecated static V.old(): void",
    "webservice static V.ws(): void",
    "V.k: Integer { set }",
    "@InvocableVariable(required=true) V.R.x: String",
  ]) {
    assert.ok(
      lines.includes(expected),
      `missing: ${expected}\n${lines.join("\n")}`,
    );
  }
});

test("checker: finds webservice in a non-global type and implements of a non-global interface", () => {
  const m = buildModel(
    parseSources({
      "W.cls": "public class W { webservice static void ws() {} }",
      "G.cls": "global class G implements H {}",
      "H.cls": "public interface H {}",
    }),
  );
  assert.deepEqual(ruleViolations(m).sort(), [
    "G: implements non-global H",
    "W.ws: global member in non-global type",
  ]);
});

test("checker: finds internals by structure and ignores name case", () => {
  const m = buildModel(
    parseSources({
      "Tick.cls":
        "global class Tick implements Schedulable { global void execute(SchedulableContext c) {} }",
      "Hop.cls":
        "public class Hop implements Queueable, Database.AllowsCallouts { global void x() {} }",
      "Ui.cls": "public class Ui { @AuraEnabled global static void x() {} }",
      "workflowretryjob.cls": "global class workflowretryjob {}",
      "Fine.cls":
        "global class Fine implements Comparable { public Integer compareTo(Object o) { return 0; } }",
    }),
  );
  assert.deepEqual(exposedInternals(m), [
    "Hop",
    "Tick",
    "Ui",
    "workflowretryjob",
  ]);
});

test("checker: stub implements the methods of super-interfaces", () => {
  const m = buildModel(
    parseSources({
      "W.cls": "global interface W { void a(); }",
      "C.cls": "global interface C extends W { void b(); }",
      "K.cls":
        "global class K implements C { public void a() {} public void b() {} }",
    }),
  );
  const stub = stubSources(m)["K.cls"];
  assert.match(stub, /public void a\(\)/);
  assert.match(stub, /public void b\(\)/);
});

test("checker: finds typed, prefix, and compound writes to read-only properties", () => {
  const m = buildModel(
    parseSources({
      "S.cls":
        "global class S { global String status { get; private set; } global Integer n { get; private set; } }",
      "D.cls": "global class D { global String status; }",
    }),
  );
  const src =
    "S s; D d; s.status = 'x'; d.status = 'y'; ++s.n; s.n |= 1; s.n <<= 1; Boolean b = s.n == 1;";
  assert.deepEqual(readOnlyWrites(src, m), [
    "line 1: s.status",
    "line 1: s.n",
    "line 1: s.n",
    "line 1: s.n",
  ]);
});

test("checker: finds calls to stub-only public methods", () => {
  const m = buildModel(
    parseSources({
      "Sig.cls":
        "global class Sig implements Comparable { public Integer compareTo(Object o) { return 0; } public void helper() {} }",
    }),
  );
  assert.deepEqual(
    stubOnlyCalls("Sig s; s.compareTo(null); List<Sig> l; l.sort();", m),
    ["line 1: .compareTo("],
  );
});

test("checker: read-only writes use scope-safe receiver types", () => {
  const m = buildModel(
    parseSources({
      "S.cls":
        "global class S { global String status { get; private set; } global Integer n { get; private set; } global S next() { return this; } }",
      "D.cls": "global class D { global String status; }",
    }),
  );
  const src =
    "public class Sub { String status; " +
    "void a() { S s; s.status = 'x'; } void b() { D s; s.status = 'y'; } " +
    "void c() { Account acc; acc.Name = 'z'; this.status = 'w'; ++s.next().n; } }";
  assert.deepEqual(readOnlyWrites(src, m), [
    "line 1: s.status",
    "line 1: s.status",
    "line 1: ?.n",
  ]);
});

test("checker: survives cyclic interfaces and flags only the structural internal type", () => {
  const m = buildModel(
    parseSources({
      "A.cls": "global interface A extends B { void a(); }",
      "B.cls": "global interface B extends A { void b(); }",
      "K.cls":
        "global class K implements A { public void a() {} public void b() {} }",
      "Facade.cls":
        "global class Facade { global static void go() {} " +
        "private class Hop implements Queueable { public void execute(QueueableContext c) {} } }",
    }),
  );
  assert.match(stubSources(m)["K.cls"], /public void b\(\)/);
  assert.deepEqual(exposedInternals(m), []);
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

test("the subscriber fixture calls no stub-only public method", () => {
  const source = readFileSync(join(CLASSES, `${FIXTURE}.cls`), "utf8");
  assert.deepEqual(stubOnlyCalls(source, model), []);
});

test("the subscriber fixture writes no read-only global property", () => {
  const source = readFileSync(join(CLASSES, `${FIXTURE}.cls`), "utf8");
  assert.deepEqual(readOnlyWrites(source, model), []);
});

// ─── Packaged view: compile against the global API only ───────────────────

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

test("packaged view: the subscriber fixture compiles in a foreign namespace", (t) => {
  const why = apexLsMissing();
  if (why) {
    if (process.env.REQUIRE_APEX_LS) assert.fail(why);
    t.skip(why);
    return;
  }
  const classpath = apexLsClasspath();
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
      "WorkflowEngine.cancel(null); " + // positive control: global
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
    // Negative control: the packaged view rejects exactly the namespace-private
    // member and the namespace-private type. The global call has no error.
    assert.equal(probeErrors.length, 2, probeErrors.join(" | "));
    assert.match(
      probeErrors[0],
      /No matching method found for 'runStep' on 'rvn\.WorkflowEngine'/i,
    );
    assert.match(probeErrors[1], /'Builder'.*'rvn\.StepContext'/i);
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});
