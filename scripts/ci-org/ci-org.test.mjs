// Tests for the shared CI scratch org script. Run: npm run test:ci-org
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  ALIAS,
  CiOrgError,
  daysLeft,
  decrypt,
  deleteOrg,
  encrypt,
  isUsable,
  main,
  parseArgs,
  prepare,
} from "./ci-org.mjs";

const NOW = Date.parse("2026-10-01T12:00:00Z");
const SECRET = "force://PlatformCLI::devhub-refresh-token@example.my.salesforce.com";
const ORG_URL = "force://PlatformCLI::scratch-refresh-token::abc@scratch.my.salesforce.com";

function display(expirationDate, extra = {}) {
  return {
    status: 0,
    json: {
      status: 0,
      result: { expirationDate, connectedStatus: "Connected", status: "Active", ...extra },
    },
  };
}

/** A fake `sf`. `plan` maps "org login" style prefixes to a response or a function. */
function fakeSf(plan) {
  const calls = [];
  const run = (args) => {
    calls.push(args);
    const key = args.slice(0, 3).join(" ");
    const hit = Object.entries(plan).find(([k]) => key.startsWith(k));
    if (!hit) return { status: 1, json: { message: `no plan for ${key}` } };
    return typeof hit[1] === "function" ? hit[1](args) : hit[1];
  };
  return { run, calls };
}

function tmpAuthFile() {
  return join(mkdtempSync(join(tmpdir(), "ci-org-test-")), "sub", "auth.enc");
}

/** Writes an auth file, and its folder. */
function seed(authFile, text) {
  mkdirSync(dirname(authFile), { recursive: true });
  writeFileSync(authFile, text);
}

const quiet = () => {};

test("encrypt then decrypt returns the text", () => {
  const text = encrypt(ORG_URL, SECRET);
  assert.equal(decrypt(text, SECRET), ORG_URL);
});

test("the encrypted text does not hold the auth URL and differs each time", () => {
  const a = encrypt(ORG_URL, SECRET);
  const b = encrypt(ORG_URL, SECRET);
  assert.ok(!a.includes("scratch-refresh-token"));
  assert.notEqual(a, b);
});

test("decrypt fails with another secret, with changed data and with a bad format", () => {
  const text = encrypt(ORG_URL, SECRET);
  assert.throws(() => decrypt(text, "another"), CiOrgError);
  const o = JSON.parse(text);
  o.data = Buffer.from("tampered").toString("base64");
  assert.throws(() => decrypt(JSON.stringify(o), SECRET), CiOrgError);
  assert.throws(() => decrypt("not json", SECRET), CiOrgError);
  assert.throws(() => decrypt(JSON.stringify({ v: 9 }), SECRET), CiOrgError);
  assert.throws(() => encrypt(ORG_URL, ""), CiOrgError);
  assert.throws(() => decrypt(text, ""), CiOrgError);
});

test("daysLeft and isUsable", () => {
  assert.equal(daysLeft({ expirationDate: "2026-10-04" }, NOW).toFixed(1), "2.5");
  assert.ok(Number.isNaN(daysLeft({}, NOW)));
  assert.ok(isUsable(display("2026-10-04").json, NOW));
  assert.ok(!isUsable(display("2026-10-01").json, NOW), "expires within a day");
  assert.ok(!isUsable(display("2026-09-30").json, NOW), "expired");
  assert.ok(!isUsable(display(undefined).json, NOW), "no expiry date");
  assert.ok(!isUsable(display("2026-10-04", { connectedStatus: "RefreshTokenAuthError" }).json, NOW));
  assert.ok(!isUsable(display("2026-10-04", { status: "Deleted" }).json, NOW));
  assert.ok(!isUsable({ status: 1, result: {} }, NOW));
  assert.ok(!isUsable(null, NOW));
});

test("parseArgs", () => {
  assert.deepEqual(parseArgs(["prepare", "--mode", "borrow", "--auth-file", "x"]), {
    command: "prepare",
    mode: "borrow",
    authFile: "x",
  });
  assert.throws(() => parseArgs(["prepare", "--nope", "1"]), CiOrgError);
  assert.throws(() => parseArgs(["prepare", "--mode"]), CiOrgError);
});

test("borrow: a cached, connected org with days left is shared and nothing is created", () => {
  const authFile = tmpAuthFile();
  const keeper = fakeSf({
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: keeper.run, log: quiet, now: NOW } });

  const sf = fakeSf({
    "org login sfdx-url": { status: 0, json: {} },
    "org display --target-org": display("2026-10-03"),
  });
  const result = prepare({ mode: "borrow", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.deepEqual(result, { source: "shared", save: false });
  assert.ok(!sf.calls.some((c) => c[1] === "create"), "no org is created");
});

test("borrow: no cache file makes a one-off org", () => {
  const sf = fakeSf({ "org create scratch": { status: 0, json: {} } });
  const result = prepare({ mode: "borrow", authFile: tmpAuthFile(), secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.deepEqual(result, { source: "oneoff", save: false });
  assert.equal(sf.calls.length, 1);
  assert.ok(sf.calls[0].includes("--definition-file"));
});

test("borrow: a cache that another secret wrote makes a one-off org", () => {
  const authFile = tmpAuthFile();
  const keeper = fakeSf({
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  prepare({ mode: "keeper", authFile, secret: "old secret", deps: { run: keeper.run, log: quiet, now: NOW } });
  const sf = fakeSf({ "org create scratch": { status: 0, json: {} } });
  const result = prepare({ mode: "borrow", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.equal(result.source, "oneoff");
  assert.ok(!sf.calls.some((c) => c[1] === "login"), "it does not log in");
});

test("borrow: a failed login, an expired org or a near-expiry org make a one-off org", () => {
  const authFile = tmpAuthFile();
  seed(authFile, encrypt(ORG_URL, SECRET));
  for (const plan of [
    { "org login sfdx-url": { status: 1, json: {} } },
    { "org login sfdx-url": { status: 0, json: {} }, "org display --target-org": display("2026-09-30") },
    { "org login sfdx-url": { status: 0, json: {} }, "org display --target-org": display("2026-10-01") },
    { "org login sfdx-url": { status: 0, json: {} }, "org display --target-org": { status: 1, json: { status: 1 } } },
  ]) {
    const sf = fakeSf({ ...plan, "org create scratch": { status: 0, json: {} } });
    const result = prepare({ mode: "borrow", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
    assert.equal(result.source, "oneoff");
  }
});

test("borrow: a failed create throws with the reason", () => {
  const sf = fakeSf({ "org create scratch": { status: 1, json: { message: "LIMIT_EXCEEDED" } } });
  assert.throws(
    () => prepare({ mode: "borrow", authFile: tmpAuthFile(), secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } }),
    /LIMIT_EXCEEDED/,
  );
});

test("keeper: with no old org it creates an org and writes an encrypted auth file", () => {
  const authFile = tmpAuthFile();
  const lines = [];
  const sf = fakeSf({
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  const result = prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: (l) => lines.push(l), now: NOW } });
  assert.deepEqual(result, { source: "created", save: true });
  assert.ok(existsSync(authFile));
  const onDisk = readFileSync(authFile, "utf8");
  assert.ok(!onDisk.includes("scratch-refresh-token"), "the file is encrypted");
  assert.equal(decrypt(onDisk, SECRET), ORG_URL);
  assert.ok(lines.includes(`::add-mask::${ORG_URL}`), "the URL is masked in the log");
  assert.ok(!sf.calls.some((c) => c[1] === "delete"), "there is no old org to delete");
});

test("keeper: it deletes the old org before it creates a new one", () => {
  const authFile = tmpAuthFile();
  seed(authFile, encrypt("force://old", SECRET));
  const sf = fakeSf({
    "org login sfdx-url": { status: 0, json: {} },
    "org delete scratch": { status: 0, json: {} },
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  const names = sf.calls.map((c) => c.slice(0, 3).join(" "));
  assert.ok(names.indexOf("org delete scratch") < names.indexOf("org create scratch"));
  assert.equal(decrypt(readFileSync(authFile, "utf8"), SECRET), ORG_URL);
});

test("keeper: it still creates an org when the old one is gone", () => {
  const authFile = tmpAuthFile();
  seed(authFile, encrypt("force://old", SECRET));
  const sf = fakeSf({
    "org login sfdx-url": { status: 1, json: {} },
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  const result = prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.equal(result.source, "created");
});

test("keeper: it fails when the new org has no auth URL, and keeps no file", () => {
  const authFile = tmpAuthFile();
  const sf = fakeSf({
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: {} } },
    "org delete scratch": { status: 0, json: {} },
  });
  assert.throws(
    () => prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } }),
    /sfdxAuthUrl/,
  );
  assert.ok(!existsSync(authFile));
  assert.ok(sf.calls.some((c) => c[1] === "delete"), "the unusable org is deleted");
});

test("deleteOrg: sf delete works, or the Dev Hub deletes the ActiveScratchOrg record", () => {
  const ok = fakeSf({ "org delete scratch": { status: 0, json: {} } });
  assert.equal(deleteOrg({ run: ok.run }), true);
  assert.ok(!ok.calls.some((c) => c[0] === "data"), "no fallback when sf delete works");

  const fallback = fakeSf({
    "org display --target-org": { status: 0, json: { result: { id: "00DgL00000KS7MPUA1" } } },
    "org delete scratch": { status: 1, json: { message: "not a scratch org" } },
    "data query --query": { status: 0, json: { result: { records: [{ Id: "2SRxx0000004CAFGA2" }] } } },
    "data delete record": { status: 0, json: {} },
  });
  assert.equal(deleteOrg({ run: fallback.run }), true);
  const query = fallback.calls.find((c) => c[1] === "query");
  assert.ok(query.some((a) => a.includes("ScratchOrg = '00DgL00000KS7MP'")), "15-character org id");
  assert.ok(fallback.calls.find((c) => c[1] === "delete" && c[2] === "record").includes("2SRxx0000004CAFGA2"));
  assert.ok(fallback.calls.every((c) => !c.includes("--target-org") || c[c.indexOf("--target-org") + 1] === "ci" || c[c.indexOf("--target-org") + 1] === "devhub"));

  const noRecord = fakeSf({
    "org display --target-org": { status: 0, json: { result: { id: "00DgL00000KS7MPUA1" } } },
    "org delete scratch": { status: 1, json: {} },
    "data query --query": { status: 0, json: { result: { records: [] } } },
  });
  assert.equal(deleteOrg({ run: noRecord.run }), false);
  const noId = fakeSf({ "org delete scratch": { status: 1, json: {} } });
  assert.equal(deleteOrg({ run: noId.run }), false);
});

test("keeper: it falls back to the Dev Hub when sf cannot delete the old org", () => {
  const authFile = tmpAuthFile();
  seed(authFile, encrypt("force://old", SECRET));
  const sf = fakeSf({
    "org login sfdx-url": { status: 0, json: {} },
    "org display --target-org": { status: 0, json: { result: { id: "00DgL00000KS7MPUA1" } } },
    "org delete scratch": { status: 1, json: {} },
    "data query --query": { status: 0, json: { result: { records: [{ Id: "2SRxx0000004CAFGA2" }] } } },
    "data delete record": { status: 0, json: {} },
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL } } },
  });
  assert.equal(prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } }).source, "created");
  const names = sf.calls.map((c) => c.slice(0, 3).join(" "));
  assert.ok(names.indexOf("data delete record") !== -1 && names.indexOf("data delete record") < names.indexOf("org create scratch"));
});

test("an unknown mode throws, and the alias is ci", () => {
  assert.throws(() => prepare({ mode: "x", authFile: "a", secret: SECRET }), /Unknown mode/);
  assert.equal(ALIAS, "ci");
});

test("main with a fake sf on PATH: the keeper writes the outputs and the borrower reuses the org", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-org-bin-"));
  const trace = join(dir, "calls.log");
  const fake = join(dir, "sf");
  // The fake sf records each call. It prints the JSON that the real sf prints.
  writeFileSync(
    fake,
    `#!/usr/bin/env bash
echo "$*" >> "${trace}"
case "$1 $2 $3" in
  "org display --verbose") echo '{"status":0,"result":{"sfdxAuthUrl":"${ORG_URL}"}}' ;;
  "org display --target-org") echo '{"status":0,"result":{"connectedStatus":"Connected","status":"Active","expirationDate":"2999-01-01"}}' ;;
  *) echo '{"status":0,"result":{}}' ;;
esac
`,
  );
  chmodSync(fake, 0o755);
  const authFile = join(dir, "cache", "auth.enc");
  const outputs = join(dir, "output.txt");
  const env = { DEVHUB_SFDX_AUTH_URL: SECRET, GITHUB_OUTPUT: outputs };
  const log = console.log;
  const path = process.env.PATH;
  console.log = () => {};
  process.env.PATH = `${dir}:${path}`; // runSf starts `sf` from the process PATH
  try {
    assert.deepEqual(main(["prepare", "--mode", "keeper", "--auth-file", authFile], env), {
      source: "created",
      save: true,
    });
    assert.deepEqual(main(["prepare", "--mode", "borrow", "--auth-file", authFile], env), {
      source: "shared",
      save: false,
    });
  } finally {
    console.log = log;
    process.env.PATH = path;
  }
  const out = readFileSync(outputs, "utf8");
  assert.equal(out, "source=created\nsave=true\nsource=shared\nsave=false\n");
  assert.ok(!out.includes("scratch-refresh-token"), "the outputs hold no auth URL");
  assert.equal(readFileSync(trace, "utf8").split("\n").filter((l) => l.includes("org create scratch")).length, 1);
  assert.throws(() => main(["prepare"], env), CiOrgError);
});
