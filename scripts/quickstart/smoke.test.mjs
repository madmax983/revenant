// Tests for the quickstart smoke runner (issue #133). Run: npm run test:quickstart
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  DEPLOY_SOURCES,
  SmokeError,
  checkBudget,
  debugValue,
  instanceIdFrom,
  parseArgs,
  runSmoke,
  summaryMarkdown,
} from "./smoke.mjs";

const ID = "a015g00000ABCDEAA2";
const script = (name) =>
  readFileSync(new URL(`../apex/${name}`, import.meta.url), "utf8");

/**
 * A debug log like `sf apex run` gives. The log echoes each source line
 * ("Execute Anonymous: ...") before the USER_DEBUG line.
 */
function anonLog(source, debugText) {
  return [
    "67.0 APEX_CODE,DEBUG;APEX_PROFILING,INFO",
    ...source.split("\n").map((line) => `Execute Anonymous: ${line}`),
    `12:00:00.12 (1234)|USER_DEBUG|[4]|DEBUG|${debugText}`,
    "12:00:00.13 (1300)|CODE_UNIT_FINISHED|execute_anonymous_apex",
  ].join("\n");
}
const runLog = (id = ID) =>
  anonLog(script("run-hello.apex"), `HELLO_INSTANCE_ID=${id}`);
const verifyLog = (id = ID) =>
  anonLog(
    script("verify-hello.apex"),
    `HELLO_VERIFY: ${id} Completed in 4.0 s`,
  );

/** A fake `sf`. It records each call and answers from `script`. */
function fakeSf(script = {}) {
  const calls = [];
  const statuses = [...(script.statuses ?? ["Running", "Completed"])];
  const sf = (args) => {
    calls.push(args);
    const key = args.slice(0, 2).join(" ");
    const reply = script[key];
    if (reply) return typeof reply === "function" ? reply(args) : reply;
    switch (key) {
      case "project deploy":
        return ok({ status: "Succeeded" });
      case "org assign":
        return ok({ successes: [{ name: "Revenant_Admin" }], failures: [] });
      case "apex run":
        return args.some((a) => a.endsWith("run-hello.apex"))
          ? apexOk(runLog())
          : apexOk(verifyLog());
      case "data query": {
        const status = statuses.length > 1 ? statuses.shift() : statuses[0];
        const active = ["Pending", "Running"].includes(status);
        return ok({
          records: [
            {
              Status__c: status,
              Error_Message__c: "boom",
              Terminal_At__c: active ? null : "2026-09-29T12:00:00.000+0000",
            },
          ],
        });
      }
      default:
        throw new Error(`unexpected sf call: ${args.join(" ")}`);
    }
  };
  return { sf, calls };
}

function ok(result) {
  return { status: 0, stdout: JSON.stringify({ status: 0, result }) };
}

function apexOk(logs) {
  return ok({ success: true, compiled: true, logs });
}

/** A fake clock. `sleep` and `tick` move the time forward. */
function fakeClock() {
  let t = 1_000_000;
  return {
    now: () => t,
    sleep: async (ms) => {
      t += ms;
    },
    tick: (ms) => {
      t += ms;
    },
  };
}

function options(extra = {}) {
  return {
    targetOrg: undefined,
    maxSeconds: 600,
    timeoutSeconds: 900,
    pollSeconds: 5,
    resultFile: undefined,
    ...extra,
  };
}

async function smoke(sf, clock = fakeClock(), extra = {}) {
  return runSmoke({
    sf,
    now: clock.now,
    sleep: clock.sleep,
    log: () => {},
    options: options(extra),
  });
}

test("parseArgs: gives defaults", () => {
  assert.deepEqual(parseArgs([]), options());
});

test("parseArgs: reads each flag", () => {
  assert.deepEqual(
    parseArgs([
      "--target-org",
      "hello",
      "--max-seconds",
      "300",
      "--timeout-seconds",
      "120",
      "--poll-seconds",
      "2",
      "--result-file",
      "out/smoke.json",
    ]),
    options({
      targetOrg: "hello",
      maxSeconds: 300,
      timeoutSeconds: 120,
      pollSeconds: 2,
      resultFile: "out/smoke.json",
    }),
  );
});

test("parseArgs: accepts each alias and username on macOS and Linux", () => {
  for (const org of ["dev+1@example.com", "my alias", "o'brien@x.com", "a&b"]) {
    assert.equal(parseArgs(["--target-org", org], "linux").targetOrg, org);
  }
});

test("parseArgs: rejects cmd.exe characters in --target-org on Windows", () => {
  assert.equal(
    parseArgs(["--target-org", "o'brien+1@x.com"], "win32").targetOrg,
    "o'brien+1@x.com",
  );
  for (const bad of [
    'a"b',
    "a%PATH%",
    "a^b",
    "a!b",
    "a&b",
    "a|b",
    "a<b",
    "a>b",
  ]) {
    assert.throws(
      () => parseArgs(["--target-org", bad], "win32"),
      /--target-org has a character that cmd\.exe changes/,
      bad,
    );
  }
});

test("parseArgs: rejects an unknown flag and a bad number", () => {
  assert.throws(() => parseArgs(["--nope"]), /Unknown option --nope/);
  assert.throws(
    () => parseArgs(["--max-seconds", "abc"]),
    /--max-seconds needs a positive number/,
  );
  assert.throws(
    () => parseArgs(["--max-seconds", "0"]),
    /--max-seconds needs a positive number/,
  );
  assert.throws(
    () => parseArgs(["--target-org"]),
    /--target-org needs a value/,
  );
});

test("instanceIdFrom: finds the Id in the debug log", () => {
  assert.equal(instanceIdFrom(runLog()), ID);
  assert.equal(instanceIdFrom("no marker here"), null);
  assert.equal(instanceIdFrom(undefined), null);
});

test("debugValue: reads the USER_DEBUG line, not the source echo", () => {
  assert.equal(
    debugValue(verifyLog(), "HELLO_VERIFY: "),
    `${ID} Completed in 4.0 s`,
  );
  // The echo of the source line alone gives nothing.
  assert.equal(
    debugValue(anonLog(script("verify-hello.apex"), "other"), "HELLO_VERIFY: "),
    null,
  );
});

test("checkBudget: passes at the limit and fails over it", () => {
  assert.equal(checkBudget(600_000, 600).ok, true);
  const over = checkBudget(600_001, 600);
  assert.equal(over.ok, false);
  assert.match(over.message, /600\.0 s is over the 600 s budget/);
});

test("runSmoke: deploys, assigns, runs, polls and verifies in order", async () => {
  const { sf, calls } = fakeSf();
  const result = await smoke(sf);

  assert.deepEqual(
    calls.map((c) => c.slice(0, 2).join(" ")),
    [
      "project deploy",
      "org assign",
      "apex run",
      "data query",
      "data query",
      "apex run",
    ],
  );
  assert.equal(result.instanceId, ID);
  assert.equal(result.withinBudget, true);
  assert.equal(result.verifySummary, `${ID} Completed in 4.0 s`);
});

test("runSmoke: deploys only the engine and the quickstart example", async () => {
  const { sf, calls } = fakeSf();
  await smoke(sf);
  const deploy = calls[0];
  const sources = deploy.flatMap((a, i) =>
    deploy[i - 1] === "--source-dir" ? [a] : [],
  );
  assert.deepEqual(sources, DEPLOY_SOURCES);
  assert.deepEqual(DEPLOY_SOURCES, ["force-app", "examples/quickstart"]);
});

test("runSmoke: passes --target-org to each sf call", async () => {
  const { sf, calls } = fakeSf();
  await smoke(sf, fakeClock(), { targetOrg: "hello" });
  for (const call of calls) {
    const i = call.indexOf("--target-org");
    assert.ok(i >= 0 && call[i + 1] === "hello", call.join(" "));
  }
});

test("runSmoke: measures from deploy start to the Completed poll", async () => {
  const clock = fakeClock();
  const { sf } = fakeSf({
    "project deploy": () => {
      clock.tick(90_000);
      return ok({ status: "Succeeded" });
    },
    statuses: ["Pending", "Running", "Completed"],
  });
  const result = await smoke(sf, clock);
  // 90 s deploy + 2 polls of 5 s.
  assert.equal(result.deployMs, 90_000);
  assert.equal(result.elapsedMs, 100_000);
});

test("runSmoke: fails the budget when the path is too slow", async () => {
  const clock = fakeClock();
  const { sf } = fakeSf({
    "project deploy": () => {
      clock.tick(700_000);
      return ok({ status: "Succeeded" });
    },
  });
  const result = await smoke(sf, clock);
  assert.equal(result.withinBudget, false);
  assert.match(result.budgetMessage, /over the 600 s budget/);
});

test("runSmoke: accepts an assignment that already exists", async () => {
  const { sf } = fakeSf({
    "org assign": {
      status: 1,
      stdout: JSON.stringify({
        status: 1,
        result: {
          successes: [],
          failures: [
            {
              name: "Revenant_Admin",
              message: "Duplicate PermissionSetAssignment",
            },
          ],
        },
      }),
    },
  });
  const result = await smoke(sf);
  assert.equal(result.instanceId, ID);
});

function failedDeploy(result) {
  return {
    status: 1,
    stdout: JSON.stringify({
      status: 1,
      result: { status: "Failed", ...result },
    }),
  };
}

test("runSmoke: puts a root cause before the dependent failures", async () => {
  const dependent = {
    fullName: "AClass",
    problem: "Dependent class is invalid and needs recompilation:",
  };
  const root = { fullName: "ZClass", problem: "Invalid type: Foo" };
  const { sf } = fakeSf({
    "project deploy": failedDeploy({
      details: { componentFailures: [dependent, root] },
    }),
  });
  await assert.rejects(
    smoke(sf),
    /Deploy failed: ZClass: Invalid type: Foo; AClass: Dependent class/,
  );
});

test("runSmoke: stops with each component failure of a deploy", async () => {
  const one = { fullName: "HelloWorkflow", problem: "Invalid type: Foo" };
  const two = { fullName: "HelloWorkflowCheck", problem: "Bad field" };
  for (const [failures, expected] of [
    [one, /Deploy failed: HelloWorkflow: Invalid type: Foo$/],
    [
      [one, two],
      /HelloWorkflow: Invalid type: Foo; HelloWorkflowCheck: Bad field/,
    ],
  ]) {
    const { sf, calls } = fakeSf({
      "project deploy": failedDeploy({
        details: { componentFailures: failures },
      }),
    });
    await assert.rejects(smoke(sf), (e) => {
      assert.ok(e instanceof SmokeError);
      assert.match(e.message, expected);
      return true;
    });
    assert.equal(calls.length, 1);
  }
});

test("runSmoke: stops with the deploy error when no component failed", async () => {
  const { sf } = fakeSf({
    "project deploy": failedDeploy({ errorMessage: "The org is locked" }),
  });
  await assert.rejects(smoke(sf), /Deploy failed: The org is locked/);
});

test("runSmoke: stops when the permission set is not assigned", async () => {
  const { sf } = fakeSf({
    "org assign": {
      status: 1,
      stdout: JSON.stringify({
        status: 1,
        result: {
          successes: [],
          failures: [{ name: "Revenant_Admin", message: "Not found" }],
        },
      }),
    },
  });
  await assert.rejects(smoke(sf), /Revenant_Admin.*Not found/);
});

test("runSmoke: stops when the start script prints no Id", async () => {
  const { sf } = fakeSf({ "apex run": apexOk("nothing") });
  await assert.rejects(smoke(sf), /HELLO_INSTANCE_ID/);
});

test("runSmoke: stops with the Apex error when a script throws", async () => {
  const { sf } = fakeSf({
    "apex run": {
      status: 1,
      stdout: JSON.stringify({
        status: 1,
        name: "executeRuntimeFailure",
        message: "Execution failed at this code:\n\nNope",
      }),
    },
  });
  await assert.rejects(smoke(sf), /run-hello\.apex failed: [\s\S]*Nope/);
});

test("runSmoke: stops with the status and error of a failed run", async () => {
  const { sf } = fakeSf({ statuses: ["Running", "Failed"] });
  await assert.rejects(smoke(sf), /Failed.*boom/);
});

test("runSmoke: stops when the run is not terminal before the timeout", async () => {
  const { sf, calls } = fakeSf({ statuses: ["Running"] });
  await assert.rejects(
    smoke(sf, fakeClock(), { timeoutSeconds: 20, pollSeconds: 5 }),
    /not terminal after 20 s.*Running/,
  );
  // Polls at 0, 5, 10, 15 and 20 s.
  assert.equal(calls.filter((c) => c[0] === "data").length, 5);
});

/** A `data query` that fails `failures` times, then gives Completed. */
function flakyQuery(failures) {
  let n = 0;
  return () =>
    n++ < failures
      ? { status: 1, stdout: JSON.stringify({ status: 1, message: "503" }) }
      : ok({
          records: [
            { Status__c: "Completed", Terminal_At__c: "2026-09-29T12:00:00Z" },
          ],
        });
}

test("runSmoke: tries a failed status query again", async () => {
  const { sf } = fakeSf({ "data query": flakyQuery(2) });
  const result = await smoke(sf);
  assert.equal(result.instanceId, ID);
});

test("runSmoke: stops after 3 failed status queries in a row", async () => {
  const { sf, calls } = fakeSf({ "data query": flakyQuery(3) });
  await assert.rejects(smoke(sf), /status query failed 3 times: 503/);
  assert.equal(calls.filter((c) => c[0] === "data").length, 3);
});

test("runSmoke: stops when verify reads another instance", async () => {
  const { sf } = fakeSf({
    "apex run": (args) =>
      args.some((a) => a.endsWith("run-hello.apex"))
        ? apexOk(runLog())
        : apexOk(verifyLog("a015g00000ZZZZZAA2")),
  });
  await assert.rejects(smoke(sf), /verify read another instance/);
});

test("summaryMarkdown: gives a table with the times and the budget", () => {
  const md = summaryMarkdown(
    {
      instanceId: ID,
      deployMs: 90_000,
      elapsedMs: 100_000,
      withinBudget: true,
      verifySummary: `${ID} Completed in 4.0 s`,
    },
    600,
  );
  assert.match(md, /Deploy to `Completed` \| 100\.0 s/);
  assert.match(md, /Deploy \| 90\.0 s/);
  assert.match(md, /Budget \| 600 s \(pass\)/);
  assert.match(md, new RegExp(ID));
});

test("runSmoke: gives no 'null' when an ended run has no error", async () => {
  const { sf } = fakeSf({
    "data query": ok({
      records: [
        { Status__c: "Cancelled", Terminal_At__c: "2026-09-29T12:00:00Z" },
      ],
    }),
  });
  await assert.rejects(smoke(sf), /ended Cancelled\.$/);
});
