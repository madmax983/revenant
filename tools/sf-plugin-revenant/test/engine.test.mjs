// Wasm bridge: the Rust core through rl_alloc / rl_lint / rl_free.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { EngineMissingError, loadEngine } from "../src/engine.js";

const step = (body) =>
  `public class S implements WorkflowStep {\n  public StepResult execute(StepContext ctx) {\n${body}\n  return null; }\n}`;

test("lint returns the Rust report", async () => {
  const engine = await loadEngine();
  const report = engine.lint([{ path: "S.cls", source: step("Datetime.now();") }]);
  assert.equal(report.version, 1);
  assert.equal(report.filesScanned, 1);
  assert.equal(report.stepClassesScanned, 1);
  assert.equal(report.defects.length, 1);
  assert.deepEqual(
    {
      code: report.defects[0].code,
      rule: report.defects[0].rule,
      severity: report.defects[0].severity,
      line: report.defects[0].line,
    },
    { code: "NON_DETERMINISTIC_SOURCE", rule: "CLOCK_READ", severity: "HIGH", line: 3 },
  );
});

test("comments, strings and producers give no defect", async () => {
  const engine = await loadEngine();
  const producer =
    "Object v = ctx.captures().once('k', new P());\n}\n" +
    "class P implements CaptureProducer { public Object produce() { return Datetime.now(); } }\n" +
    "void unused() {";
  const report = engine.lint([
    { path: "S.cls", source: step("// Datetime.now()\nString s = 'Math.random()';") },
    { path: "T.cls", source: step(producer).replace("class S ", "class T ") },
  ]);
  assert.equal(report.stepClassesScanned, 2);
  assert.deepEqual(report.defects, []);
});

test("non-ASCII text round-trips through wasm memory", async () => {
  const engine = await loadEngine();
  const report = engine.lint([
    { path: "Ünï/S.cls", source: step("String s = 'héllo ✓';\nDatetime.now();") },
  ]);
  assert.equal(report.defects[0].file, "Ünï/S.cls");
  assert.equal(report.defects[0].line, 4);
});

test("a large project lints and memory stays bounded", async () => {
  const engine = await loadEngine();
  const files = Array.from({ length: 50 }, (_, i) => ({
    path: `S${i}.cls`,
    source: step("Datetime.now();\n" + "Integer x = 1;\n".repeat(2000)).replace(
      "class S ",
      `class S${i} `,
    ),
  }));
  const started = performance.now();
  const first = engine.lint(files);
  assert.ok(performance.now() - started < 2000, "under 2 s for 50 steps");
  assert.equal(first.defects.length, 50);
  const pages = engine.memoryBytes();
  for (let i = 0; i < 20; i++) engine.lint(files);
  assert.equal(engine.memoryBytes(), pages, "no leak across calls");
});

test("a core error is thrown", async () => {
  const engine = await loadEngine();
  assert.throws(() => engine.lintRaw("{"), /revenant-lint core:/);
});

test("a missing wasm file gives a build hint", async () => {
  await assert.rejects(
    loadEngine(new URL("file:///no/such/revenant_lint.wasm")),
    (e) => e instanceof EngineMissingError && /npm run build/.test(e.message),
  );
});

test("after a trap the engine uses a new instance", async () => {
  // A hand-made module. rl_lint traps on its first call and sets a flag. With
  // the flag set, it returns {"ok":1}. A new instance has no flag, so it traps again.
  const dir = mkdtempSync(join(tmpdir(), "rl-trap-"));
  const file = join(dir, "trap.wasm");
  writeFileSync(file, Buffer.from("0061736d0100000001110360017f017f60027f7f017e60027f7f0003040300010205030100010606017f0141000b072904066d656d6f7279020008726c5f616c6c6f63000007726c5f6c696e74000107726c5f6672656500020a200305004180080b15002300044042888080808080020f0b41012400000b02000b0b0f01004180100b087b226f6b223a317d", "hex"));
  const engine = await loadEngine(pathToFileURL(file));
  assert.throws(() => engine.lintRaw("{}"), WebAssembly.RuntimeError);
  assert.throws(() => engine.lintRaw("{}"), WebAssembly.RuntimeError);
});
