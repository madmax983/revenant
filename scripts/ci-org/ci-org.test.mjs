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
  readAuthFile,
  withExpiry,
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

/** The cache text that the keeper writes: the auth URL and its expiry, encrypted. */
const ORG_ID = "00DgL00000KS7MPUA1";
function cacheText(authUrl, expirationDate = "2026-10-04", secret = SECRET, orgId = ORG_ID) {
  return encrypt(JSON.stringify({ authUrl, expirationDate, orgId }), secret);
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
    markerFile: undefined,
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
  seed(authFile, cacheText(ORG_URL));
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
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL, id: ORG_ID } } },
  });
  const result = prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: (l) => lines.push(l), now: NOW } });
  assert.deepEqual(result, { source: "created", save: true });
  assert.ok(existsSync(authFile));
  const onDisk = readFileSync(authFile, "utf8");
  assert.ok(!onDisk.includes("scratch-refresh-token"), "the file is encrypted");
  const saved = JSON.parse(decrypt(onDisk, SECRET));
  assert.equal(saved.authUrl, ORG_URL);
  assert.equal(saved.orgId, ORG_ID, "the org id is saved for the next keeper run");
  assert.equal(saved.expirationDate, "2026-10-04", "3 days after the creation time, when sf shows none");
  assert.ok(lines.includes(`::add-mask::${ORG_URL}`), "the URL is masked in the log");
  assert.ok(!sf.calls.some((c) => c[1] === "delete"), "there is no old org to delete");
});

const NEW_ORG_PLAN = {
  "org create scratch": { status: 0, json: {} },
  "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL, id: "00DgL00000NEW0000A" } } },
};
const ACTIVE = { status: 0, json: { result: { records: [{ Id: "2SRxx0000004CAFGA2" }] } } };

test("keeper: the Dev Hub ends the old org by its saved id, with no login, before the new org", () => {
  const authFile = tmpAuthFile();
  seed(authFile, cacheText("force://old"));
  const sf = fakeSf({
    ...NEW_ORG_PLAN,
    "data query --query": ACTIVE,
    "data delete record": { status: 0, json: {} },
  });
  const result = prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.equal(result.source, "created");
  const names = sf.calls.map((c) => c.slice(0, 3).join(" "));
  assert.ok(names.indexOf("data delete record") !== -1);
  assert.ok(names.indexOf("data delete record") < names.indexOf("org create scratch"));
  assert.ok(!names.includes("org login sfdx-url"), "a failing login cannot block the keeper");
  assert.ok(sf.calls.find((c) => c[1] === "query").some((a) => a.includes("ScratchOrg = '00DgL00000KS7MP'")));
  assert.equal(readAuthFile(authFile, SECRET).orgId, "00DgL00000NEW0000A", "the cache now holds the new org");
});

test("keeper: it stops, creates nothing and keeps the cache when the Dev Hub cannot answer or the delete fails", () => {
  for (const plan of [
    { "data query --query": { status: 1, json: { message: "network" } } },
    { "data query --query": ACTIVE, "data delete record": { status: 1, json: {} } },
  ]) {
    const authFile = tmpAuthFile();
    const before = cacheText("force://old");
    seed(authFile, before);
    const sf = fakeSf({ ...NEW_ORG_PLAN, ...plan });
    assert.throws(
      () => prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } }),
      /next keeper run tries again/,
    );
    assert.ok(!sf.calls.some((c) => c[1] === "create"), "no new org is created");
    assert.equal(readFileSync(authFile, "utf8"), before, "the cache file is unchanged");
  }
});

test("keeper: it creates an org when the Dev Hub shows the old one is gone", () => {
  const authFile = tmpAuthFile();
  seed(authFile, cacheText("force://old"));
  const sf = fakeSf({
    ...NEW_ORG_PLAN,
    "data query --query": { status: 0, json: { result: { records: [] } } },
  });
  const result = prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.equal(result.source, "created");
  assert.ok(!sf.calls.some((c) => c[1] === "delete"), "there is nothing to delete");
});

test("keeper: a cache from before the org id was saved uses the login and the sf delete", () => {
  const authFile = tmpAuthFile();
  seed(authFile, cacheText("force://old", "2026-10-04", SECRET, null));
  const sf = fakeSf({
    ...NEW_ORG_PLAN,
    "org login sfdx-url": { status: 0, json: {} },
    "org display --target-org": { status: 0, json: { result: { id: ORG_ID } } },
    "org delete scratch": { status: 0, json: {} },
  });
  prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  const names = sf.calls.map((c) => c.slice(0, 3).join(" "));
  assert.ok(names.indexOf("org delete scratch") < names.indexOf("org create scratch"));

  // Stop when that delete fails.
  seed(authFile, cacheText("force://old", "2026-10-04", SECRET, null));
  const stuck = fakeSf({
    ...NEW_ORG_PLAN,
    "org login sfdx-url": { status: 0, json: {} },
    "org delete scratch": { status: 1, json: {} },
  });
  assert.throws(
    () => prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: stuck.run, log: quiet, now: NOW } }),
    /could not be deleted/,
  );
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

test("keeper: it saves the expiry that sf shows", () => {
  const authFile = tmpAuthFile();
  const sf = fakeSf({
    "org create scratch": { status: 0, json: {} },
    "org display --verbose": { status: 0, json: { result: { sfdxAuthUrl: ORG_URL, expirationDate: "2026-10-09", id: ORG_ID } } },
  });
  prepare({ mode: "keeper", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
  assert.deepEqual(readAuthFile(authFile, SECRET), { authUrl: ORG_URL, expirationDate: "2026-10-09", orgId: ORG_ID });
});

test("borrow: sf shows no expirationDate after an auth URL login, so the saved expiry counts", () => {
  const noExpiry = { status: 0, json: { status: 0, result: { connectedStatus: "Connected", status: "Active" } } };
  for (const [saved, expected] of [
    ["2026-10-04", "shared"],
    ["2026-10-01", "oneoff"], // under a day left
    [null, "oneoff"], // nothing to count from: do not trust the org
  ]) {
    const authFile = tmpAuthFile();
    seed(authFile, cacheText(ORG_URL, saved));
    const sf = fakeSf({
      "org login sfdx-url": { status: 0, json: {} },
      "org display --target-org": noExpiry,
      "org create scratch": { status: 0, json: {} },
    });
    const result = prepare({ mode: "borrow", authFile, secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } });
    assert.equal(result.source, expected, `saved expiry ${saved}`);
  }
});

test("withExpiry fills only a missing expiry; readAuthFile rejects what is not a credential", () => {
  const shown = { status: 0, result: { connectedStatus: "Connected" } };
  assert.equal(withExpiry(shown, "2026-10-04").result.expirationDate, "2026-10-04");
  assert.equal(withExpiry({ status: 0, result: { expirationDate: "2026-10-09" } }, "2026-10-04").result.expirationDate, "2026-10-09");
  assert.equal(withExpiry(null, "2026-10-04"), null);
  assert.equal(withExpiry(shown, undefined), shown);

  const authFile = tmpAuthFile();
  assert.equal(readAuthFile(authFile, SECRET), null, "no file");
  seed(authFile, encrypt(ORG_URL, SECRET)); // a bare URL, not the payload
  assert.equal(readAuthFile(authFile, SECRET), null, "not a payload");
  seed(authFile, encrypt(JSON.stringify({ authUrl: "  " }), SECRET));
  assert.equal(readAuthFile(authFile, SECRET), null, "empty URL");
  seed(authFile, cacheText(ORG_URL));
  assert.equal(readAuthFile(authFile, "another"), null, "wrong secret");
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

test("the marker file exists while the org is made and is gone after, on every path", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-org-marker-"));
  const markerFile = join(dir, ".ci-org-creating");
  const seen = [];
  const watching = (plan) => (args) => {
    if (args[1] === "create") seen.push(existsSync(markerFile));
    return fakeSf(plan).run(args);
  };

  // One-off org (a borrower with no cache).
  prepare({ mode: "borrow", authFile: tmpAuthFile(), markerFile, secret: SECRET, deps: { run: watching({ "org create scratch": { status: 0, json: {} } }), log: quiet, now: NOW } });
  // Keeper.
  prepare({ mode: "keeper", authFile: tmpAuthFile(), markerFile, secret: SECRET, deps: { run: watching(NEW_ORG_PLAN), log: quiet, now: NOW } });
  assert.deepEqual(seen, [true, true], "the marker is there when sf creates the org");
  assert.ok(!existsSync(markerFile), "and it is gone when the org is accounted for");

  // A failed create, and a new org that cannot be shared, also remove it.
  assert.throws(() => prepare({ mode: "borrow", authFile: tmpAuthFile(), markerFile, secret: SECRET, deps: { run: watching({ "org create scratch": { status: 1, json: {} } }), log: quiet, now: NOW } }));
  assert.ok(!existsSync(markerFile));
  assert.throws(() => prepare({ mode: "keeper", authFile: tmpAuthFile(), markerFile, secret: SECRET, deps: { run: watching({ "org create scratch": { status: 0, json: {} }, "org display --verbose": { status: 0, json: { result: {} } }, "org delete scratch": { status: 0, json: {} } }), log: quiet, now: NOW } }));
  assert.ok(!existsSync(markerFile));

  // A process that is killed leaves the marker (simulated: the run never returns).
  class Killed extends Error {}
  const killed = (args) => {
    if (args[1] === "create") throw new Killed();
    return { status: 0, json: {} };
  };
  assert.throws(() => prepare({ mode: "borrow", authFile: tmpAuthFile(), markerFile, secret: SECRET, deps: { run: killed, log: quiet, now: NOW } }), Killed);
  assert.ok(!existsSync(markerFile), "an exception cleans up; only a killed process leaves the marker");
});

test("keeper: it deletes the new org when the auth file cannot be written", () => {
  const dir = mkdtempSync(join(tmpdir(), "ci-org-blocked-"));
  const blocker = join(dir, "blocker");
  writeFileSync(blocker, "a file, not a folder");
  const sf = fakeSf({ ...NEW_ORG_PLAN, "org delete scratch": { status: 0, json: {} } });
  assert.throws(() => prepare({ mode: "keeper", authFile: join(blocker, "auth.enc"), secret: SECRET, deps: { run: sf.run, log: quiet, now: NOW } }));
  assert.ok(sf.calls.some((c) => c[1] === "delete"), "the org that cannot be cached is deleted");
});

test("parseArgs takes a marker file", () => {
  assert.equal(parseArgs(["prepare", "--mode", "keeper", "--auth-file", "a", "--marker-file", "m"]).markerFile, "m");
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
