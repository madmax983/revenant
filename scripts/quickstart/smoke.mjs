#!/usr/bin/env node
// Quickstart smoke runner (issue #133). One command from an org to a verified run:
// deploy, assign the permission set, start HelloWorkflow, poll, verify, check the budget.
// The time is from the deploy start to the first `Completed` poll.
// Run: npm run quickstart -- [--target-org <alias>] [--max-seconds 600]
import { spawnSync } from "node:child_process";
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

/** The folders to deploy: the engine and the Hello example only. */
export const DEPLOY_SOURCES = ["force-app", "examples/quickstart"];
export const PERMISSION_SET = "Revenant_Admin";
const RUN_SCRIPT = "scripts/apex/run-hello.apex";
const VERIFY_SCRIPT = "scripts/apex/verify-hello.apex";

const DEFAULTS = {
  targetOrg: undefined,
  maxSeconds: 600,
  timeoutSeconds: 900,
  pollSeconds: 5,
  resultFile: undefined,
};
const FLAGS = {
  "--target-org": "targetOrg",
  "--max-seconds": "maxSeconds",
  "--timeout-seconds": "timeoutSeconds",
  "--poll-seconds": "pollSeconds",
  "--result-file": "resultFile",
};
const TEXT_FLAGS = new Set(["targetOrg", "resultFile"]);
// An alias or a username. No shell characters: on Windows, `sf` runs in cmd.exe.
const ORG_PATTERN = /^[\w.@+-]+$/;
const QUERY_ATTEMPTS = 3;
const USAGE = `Usage: node scripts/quickstart/smoke.mjs [options]
  --target-org <alias>     Org to use (default: the sf default org)
  --max-seconds <n>        Budget from deploy start to Completed (default ${DEFAULTS.maxSeconds})
  --timeout-seconds <n>    Stop the poll after this time (default ${DEFAULTS.timeoutSeconds})
  --poll-seconds <n>       Time between polls (default ${DEFAULTS.pollSeconds})
  --result-file <path>     Also write the result as JSON to this file`;

/** A smoke step failed. The message tells the user what to do. */
export class SmokeError extends Error {}

/** Reads the command-line flags. */
export function parseArgs(argv) {
  const options = { ...DEFAULTS };
  for (let i = 0; i < argv.length; i += 2) {
    const flag = argv[i];
    const key = FLAGS[flag];
    if (!key) throw new SmokeError(`Unknown option ${flag}\n${USAGE}`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith("--")) {
      throw new SmokeError(`${flag} needs a value`);
    }
    if (key === "targetOrg" && !ORG_PATTERN.test(value)) {
      throw new SmokeError(`${flag} has a character that is not permitted`);
    }
    if (TEXT_FLAGS.has(key)) {
      options[key] = value;
      continue;
    }
    const n = Number(value);
    if (!(n > 0)) throw new SmokeError(`${flag} needs a positive number`);
    options[key] = n;
  }
  return options;
}

/**
 * Gives the text after `marker` on the last USER_DEBUG line. Null if not found.
 * The log also echoes the source lines ("Execute Anonymous: ..."). They are ignored.
 */
export function debugValue(logs, marker) {
  const lines = (logs ?? "")
    .split(/\r?\n/)
    .filter((l) => l.includes("|USER_DEBUG|") && l.includes(marker));
  if (!lines.length) return null;
  const last = lines[lines.length - 1];
  return last.slice(last.indexOf(marker) + marker.length).trim();
}

/** Finds the instance Id that run-hello.apex prints. Null if not found. */
export function instanceIdFrom(logs) {
  const value = debugValue(logs, "HELLO_INSTANCE_ID=");
  return /^[a-zA-Z0-9]{15,18}$/.test(value ?? "") ? value : null;
}

/** Compares the elapsed time with the budget. */
export function checkBudget(elapsedMs, maxSeconds) {
  const ok = elapsedMs <= maxSeconds * 1000;
  const verdict = ok ? "is within" : "is over";
  return {
    ok,
    message: `${seconds(elapsedMs)} s ${verdict} the ${maxSeconds} s budget.`,
  };
}

/** A Markdown table for the CI job summary. */
export function summaryMarkdown(result, maxSeconds) {
  return [
    "### Quickstart smoke",
    "",
    "| Measure | Value |",
    "| --- | --- |",
    `| Deploy to \`Completed\` | ${seconds(result.elapsedMs)} s |`,
    `| Deploy | ${seconds(result.deployMs)} s |`,
    `| Budget | ${maxSeconds} s (${result.withinBudget ? "pass" : "FAIL"}) |`,
    `| Instance | \`${result.instanceId}\` |`,
    `| Verify | ${result.verifySummary} |`,
    "",
  ].join("\n");
}

/**
 * Runs the quickstart path. `sf(args)` returns `{ status, stdout, stderr }`.
 * Throws SmokeError when a step fails. Returns the times and the budget verdict.
 */
export async function runSmoke({ sf, now, sleep, log, options }) {
  const call = (args) => callSf(sf, args, options.targetOrg);
  const start = now();

  log(`1/5 Deploy ${DEPLOY_SOURCES.join(" and ")}`);
  const deploy = call([
    "project",
    "deploy",
    "start",
    ...DEPLOY_SOURCES.flatMap((s) => ["--source-dir", s]),
    "--wait",
    "30",
  ]);
  if (deploy.code !== 0) {
    throw new SmokeError(`Deploy failed: ${deployProblems(deploy)}`);
  }
  const deployMs = now() - start;
  log(`    Deploy done in ${seconds(deployMs)} s`);

  log(`2/5 Assign ${PERMISSION_SET}`);
  assignPermissionSet(
    call(["org", "assign", "permset", "--name", PERMISSION_SET]),
  );

  log(`3/5 Start HelloWorkflow (${RUN_SCRIPT})`);
  const instanceId = instanceIdFrom(apexLogs(call, RUN_SCRIPT));
  if (!instanceId) {
    throw new SmokeError(`${RUN_SCRIPT} printed no HELLO_INSTANCE_ID`);
  }
  log(`    Instance ${instanceId}`);

  log("4/5 Wait for a terminal status");
  const pollStart = now();
  let failedQueries = 0;
  for (;;) {
    const res = queryInstance(call, instanceId);
    if (res.code !== 0) {
      // A short network or org error must not stop a long run.
      failedQueries++;
      if (failedQueries >= QUERY_ATTEMPTS) {
        throw new SmokeError(
          `The status query failed ${QUERY_ATTEMPTS} times: ${errorText(res)}`,
        );
      }
      log(`    The status query failed. Try again: ${errorText(res)}`);
      await sleep(options.pollSeconds * 1000);
      continue;
    }
    failedQueries = 0;
    const run = res.json?.result?.records?.[0];
    if (!run) throw new SmokeError(`No Workflow_Instance__c ${instanceId}`);
    if (run.Terminal_At__c) {
      if (run.Status__c !== "Completed") {
        const why = run.Error_Message__c ? `: ${run.Error_Message__c}` : ".";
        throw new SmokeError(`Run ${instanceId} ended ${run.Status__c}${why}`);
      }
      break;
    }
    if (now() - pollStart >= options.timeoutSeconds * 1000) {
      throw new SmokeError(
        `Run ${instanceId} is not terminal after ${options.timeoutSeconds} s. ` +
          `Status: ${run.Status__c}.`,
      );
    }
    await sleep(options.pollSeconds * 1000);
  }
  const elapsedMs = now() - start;

  log(`5/5 Verify (${VERIFY_SCRIPT})`);
  const verifySummary = debugValue(
    apexLogs(call, VERIFY_SCRIPT),
    "HELLO_VERIFY: ",
  );
  if (!verifySummary) {
    throw new SmokeError(`${VERIFY_SCRIPT} printed no HELLO_VERIFY`);
  }
  if (!verifySummary.includes(instanceId)) {
    throw new SmokeError(
      `The verify read another instance: ${verifySummary}. Expected ${instanceId}.`,
    );
  }
  log(`    ${verifySummary}`);

  const budget = checkBudget(elapsedMs, options.maxSeconds);
  return {
    instanceId,
    deployMs,
    elapsedMs,
    verifySummary,
    withinBudget: budget.ok,
    budgetMessage: budget.message,
  };
}

// ─── sf calls ──────────────────────────────────────────────────────────────

function callSf(sf, args, targetOrg) {
  const org = targetOrg ? ["--target-org", targetOrg] : [];
  const run = sf([...args, "--json", ...org]);
  const text = run.stdout ?? "";
  let json = null;
  try {
    json = JSON.parse(text.slice(text.indexOf("{")));
  } catch {
    json = null;
  }
  return { code: run.status, json, stderr: run.stderr ?? "" };
}

function errorText(res) {
  return (
    res.json?.result?.errorMessage ||
    res.json?.message ||
    res.stderr.trim() ||
    `sf exit code ${res.code}`
  );
}

function deployProblems(res) {
  const failures = [res.json?.result?.details?.componentFailures ?? []].flat();
  const lines = failures.map((f) => `${f.fullName}: ${f.problem}`);
  return lines.length ? lines.join("; ") : errorText(res);
}

function assignPermissionSet(res) {
  const failures = res.json?.result?.failures ?? [];
  const real = failures.filter((f) => !/duplicate/i.test(f.message ?? ""));
  if (real.length || (res.code !== 0 && failures.length === 0)) {
    const why = real.map((f) => f.message).join("; ") || errorText(res);
    throw new SmokeError(`Cannot assign ${PERMISSION_SET}: ${why}`);
  }
}

function apexLogs(call, script) {
  const res = call(["apex", "run", "--file", script]);
  if (res.code !== 0 || res.json?.result?.success !== true) {
    throw new SmokeError(`${script} failed: ${errorText(res)}`);
  }
  return res.json.result.logs ?? "";
}

/** The instanceId is safe in the SOQL: instanceIdFrom accepts only letters and digits. */
function queryInstance(call, instanceId) {
  return call([
    "data",
    "query",
    "--query",
    "SELECT Status__c, Error_Message__c, Terminal_At__c " +
      `FROM Workflow_Instance__c WHERE Id = '${instanceId}'`,
  ]);
}

function seconds(ms) {
  return (ms / 1000).toFixed(1);
}

// ─── CLI ───────────────────────────────────────────────────────────────────

/** Runs the real `sf`. On Windows, `sf` is a .cmd file, so it needs a shell. */
function realSf(args) {
  const opts = {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, SF_AUTOUPDATE_DISABLE: "true" },
  };
  const run =
    process.platform === "win32"
      ? spawnSync(`sf ${args.map(quoteForCmd).join(" ")}`, {
          ...opts,
          shell: true,
        })
      : spawnSync("sf", args, opts);
  if (run.error) {
    throw new SmokeError(
      `Cannot run sf (${run.error.message}). ` +
        "Install the Salesforce CLI: npm install --global @salesforce/cli",
    );
  }
  return run;
}

/** No argument has a double quote or a %: parseArgs and instanceIdFrom prevent it. */
function quoteForCmd(arg) {
  return /^[\w./:=@+-]+$/.test(arg) ? arg : `"${arg}"`;
}

function writeSummary(text) {
  if (process.env.GITHUB_STEP_SUMMARY) {
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${text}\n`);
  }
}

async function main(argv) {
  if (argv.includes("--help") || argv.includes("-h")) {
    console.log(USAGE);
    return 0;
  }
  const options = parseArgs(argv);
  const result = await runSmoke({
    sf: realSf,
    now: Date.now,
    sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
    log: console.log,
    options,
  });
  writeSummary(summaryMarkdown(result, options.maxSeconds));
  if (options.resultFile) {
    const file = resolve(options.resultFile);
    mkdirSync(dirname(file), { recursive: true });
    const record = { ...result, maxSeconds: options.maxSeconds };
    writeFileSync(file, `${JSON.stringify(record, null, 2)}\n`);
  }
  console.log(`Deploy to Completed: ${result.budgetMessage}`);
  return result.withinBudget ? 0 : 1;
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      const message =
        error instanceof SmokeError ? error.message : (error.stack ?? error);
      console.error(`Quickstart smoke failed: ${message}`);
      writeSummary(`### Quickstart smoke\n\nFAILED: ${message}\n`);
      process.exit(1);
    },
  );
}
