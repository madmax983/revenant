#!/usr/bin/env node
// Shared CI scratch org. The Dev Hub allows 6 scratch org signups a day, so CI cannot
// make one org per run. One "keeper" run makes an org and keeps its auth URL in the
// GitHub Actions cache, encrypted with a key from DEVHUB_SFDX_AUTH_URL. The other
// runs "borrow" that org. The only secret is DEVHUB_SFDX_AUTH_URL.
//
//   keeper  (nightly on main): delete the old org, make a new one, write the encrypted auth file.
//   borrow  (pull request, manual): log in with the cached auth file. If that fails, make
//           a one-off org. The workflow deletes a one-off org after the tests.
//
// Run: node scripts/ci-org/ci-org.mjs prepare --mode keeper|borrow --auth-file <path> [--marker-file <path>]
// Env: DEVHUB_SFDX_AUTH_URL (the key), GITHUB_OUTPUT (optional).
import { spawnSync } from "node:child_process";
import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
  scryptSync,
} from "node:crypto";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ALIAS = "ci";
export const SCRATCH_DEF = "config/project-scratch-def.json";
/** A shared org with fewer days left than this is not used. */
export const MIN_DAYS_LEFT = 1;
/** The keeper makes an org for this many days. It makes a new one every night. */
export const KEEPER_DURATION_DAYS = 3;
const FORMAT_VERSION = 1;
const DAY_MS = 86_400_000;

export class CiOrgError extends Error {}

/** Encrypts text with AES-256-GCM. The key comes from the secret and a random salt. */
export function encrypt(plain, secret) {
  if (!secret) throw new CiOrgError("The encryption secret is empty.");
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", scryptSync(secret, salt, 32), iv);
  const data = Buffer.concat([cipher.update(plain, "utf8"), cipher.final()]);
  return JSON.stringify({
    v: FORMAT_VERSION,
    salt: salt.toString("base64"),
    iv: iv.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
    data: data.toString("base64"),
  });
}

/** Decrypts the output of `encrypt`. Throws when the secret is wrong or the text changed. */
export function decrypt(text, secret) {
  if (!secret) throw new CiOrgError("The encryption secret is empty.");
  let o;
  try {
    o = JSON.parse(text);
  } catch {
    throw new CiOrgError("The auth file is not JSON.");
  }
  if (!o || o.v !== FORMAT_VERSION) {
    throw new CiOrgError("The auth file has an unknown format.");
  }
  try {
    const key = scryptSync(secret, Buffer.from(o.salt, "base64"), 32);
    const decipher = createDecipheriv(
      "aes-256-gcm",
      key,
      Buffer.from(o.iv, "base64"),
    );
    decipher.setAuthTag(Buffer.from(o.tag, "base64"));
    return Buffer.concat([
      decipher.update(Buffer.from(o.data, "base64")),
      decipher.final(),
    ]).toString("utf8");
  } catch {
    throw new CiOrgError("The auth file cannot be decrypted with this secret.");
  }
}

/** Days from `now` to the org expiry. NaN when the org has no expiry date. */
export function daysLeft(result, now = Date.now()) {
  const expires = Date.parse(result?.expirationDate ?? "");
  return (expires - now) / DAY_MS;
}

/** True when `sf org display --json` shows a connected org with enough life left. */
export function isUsable(display, now = Date.now(), minDays = MIN_DAYS_LEFT) {
  if (!display || display.status !== 0 || !display.result) return false;
  const r = display.result;
  if (r.connectedStatus && r.connectedStatus !== "Connected") return false;
  if (r.status && r.status !== "Active") return false;
  return daysLeft(r, now) >= minDays;
}

/** Runs `sf`. Returns { status, json }. It does not return stdout: that can hold tokens. */
export function runSf(args) {
  const r = spawnSync("sf", args, { encoding: "utf8" });
  let json = null;
  try {
    json = JSON.parse(r.stdout);
  } catch {
    // Some commands print no JSON when they fail.
  }
  return { status: r.status ?? 1, json };
}

function maskLine(secretValue) {
  return `::add-mask::${secretValue}`;
}

/**
 * Logs in to the CI org with an auth URL. The URL goes through a 0600 file, not argv.
 * Returns true when the login worked.
 */
function login(authUrl, { run, log }) {
  log(maskLine(authUrl));
  const dir = mkdtempSync(join(tmpdir(), "ci-org-"));
  const file = join(dir, "auth.txt");
  try {
    writeFileSync(file, authUrl, { mode: 0o600 });
    return (
      run([
        "org",
        "login",
        "sfdx-url",
        "--sfdx-url-file",
        file,
        "--alias",
        ALIAS,
        "--json",
      ]).status === 0
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * Reads the cached credential: { authUrl, expirationDate, orgId }. Returns null when there is no
 * file, the secret is wrong, or the content is not a credential. The expiry is saved
 * with the URL because a login from an auth URL does not restore it: `sf org display`
 * can then show no expirationDate.
 */
export function readAuthFile(authFile, secret) {
  if (!existsSync(authFile)) return null;
  try {
    const payload = JSON.parse(decrypt(readFileSync(authFile, "utf8"), secret));
    if (typeof payload?.authUrl !== "string" || !payload.authUrl.trim()) return null;
    return {
      authUrl: payload.authUrl.trim(),
      expirationDate: payload.expirationDate,
      orgId: typeof payload.orgId === "string" ? payload.orgId : undefined,
    };
  } catch {
    return null;
  }
}

/** `display` with the saved expiry, when `sf org display` shows none. */
export function withExpiry(display, savedExpiration) {
  if (!display?.result || display.result.expirationDate || !savedExpiration) {
    return display;
  }
  return { ...display, result: { ...display.result, expirationDate: savedExpiration } };
}

/**
 * Asks the Dev Hub whether an org is still active. Returns { ok, recordId }. ok is false
 * when the Dev Hub did not answer. recordId is the ActiveScratchOrg Id, or undefined
 * when the org is not active (it expired or it was deleted).
 */
function findActiveOrg(orgId, { run }) {
  const found = run([
    "data",
    "query",
    "--query",
    `SELECT Id FROM ActiveScratchOrg WHERE ScratchOrg = '${orgId.slice(0, 15)}'`,
    "--target-org",
    "devhub",
    "--json",
  ]);
  if (found.status !== 0) return { ok: false };
  return { ok: true, recordId: found.json?.result?.records?.[0]?.Id };
}

/** Deletes an ActiveScratchOrg record through the Dev Hub. That ends the org. */
function deleteActiveOrg(recordId, { run }) {
  return (
    run([
      "data",
      "delete",
      "record",
      "--sobject",
      "ActiveScratchOrg",
      "--record-id",
      recordId,
      "--target-org",
      "devhub",
      "--json",
    ]).status === 0
  );
}

/**
 * Deletes the CI org that is logged in under the alias `ci`. `sf org delete scratch` can
 * fail for an org that the CLI knows only from an auth URL. Then the Dev Hub deletes it.
 * Returns true when the org is gone.
 */
export function deleteOrg({ run }) {
  const orgId = run(["org", "display", "--target-org", ALIAS, "--json"]).json?.result?.id;
  const deleted = run(["org", "delete", "scratch", "--target-org", ALIAS, "--no-prompt", "--json"]);
  if (deleted.status === 0) return true;
  if (!orgId) return false;
  const found = findActiveOrg(orgId, { run });
  return found.ok && found.recordId ? deleteActiveOrg(found.recordId, { run }) : false;
}

/**
 * Ends the previous shared org before the keeper makes a new one. The Dev Hub is the
 * authority on whether the org is still active, so the saved org id decides, not a
 * login: a failed login does not show that the org is gone. It stops (throws) when the
 * Dev Hub does not answer or the org stays. The old cache stays, and the next run retries.
 */
function retireOldOrg(cached, ctx) {
  if (!cached) return;
  const keep = (why) =>
    new CiOrgError(`${why} The old org stays in the cache, and the next keeper run tries again.`);
  if (cached.orgId) {
    const found = findActiveOrg(cached.orgId, ctx);
    if (!found.ok) throw keep("The Dev Hub did not answer about the previous shared CI org.");
    if (!found.recordId) return; // It expired or was deleted.
    if (!deleteActiveOrg(found.recordId, ctx)) {
      throw keep("The previous shared CI org could not be deleted.");
    }
    return;
  }
  // A cache without an org id: the login is all that is left to find the org.
  if (login(cached.authUrl, ctx) && !deleteOrg(ctx)) {
    throw keep("The previous shared CI org could not be deleted.");
  }
}

/**
 * The creation marker: a file that exists from before `sf org create` until the org is
 * accounted for. The org is accounted for when `main()` has written the step outputs, or
 * when the org is confirmed deleted, or when the create failed (there is no org). A run
 * that is killed in between, or a delete that failed, leaves the marker, and the workflow
 * deletes the org under the alias `ci`. The workflow cannot use its step outputs for this:
 * a killed step may write none.
 */
export function markCreating(markerFile) {
  if (markerFile) writeFileSync(markerFile, `${ALIAS}\n`);
}

export function clearMarker(markerFile) {
  if (markerFile) rmSync(markerFile, { force: true });
}

/**
 * Makes the org with the marker in place. `sf` reporting a failed create means there is no
 * org, so the marker goes. Any other error (not a CiOrgError) may have left an org.
 */
function createMarked(markerFile, durationDays, ctx) {
  markCreating(markerFile);
  try {
    createOrg(durationDays, ctx);
  } catch (error) {
    if (error instanceof CiOrgError) clearMarker(markerFile);
    throw error;
  }
}

function createOrg(durationDays, { run }) {
  const created = run([
    "org",
    "create",
    "scratch",
    "--definition-file",
    SCRATCH_DEF,
    "--alias",
    ALIAS,
    "--duration-days",
    String(durationDays),
    "--wait",
    "30",
    "--json",
  ]);
  if (created.status !== 0) {
    const reason = created.json?.message ?? "no message";
    throw new CiOrgError(`Creating the scratch org failed: ${reason}`);
  }
}

/**
 * Gets a CI org logged in under the alias `ci`.
 * Returns { source, save }: source is "shared" (borrowed), "created" (the keeper made it)
 * or "oneoff" (made for this run only, delete it after). save is true when the encrypted
 * auth file was written and the workflow must cache it.
 */
export function prepare({
  mode,
  authFile,
  secret,
  markerFile,
  durationDays = KEEPER_DURATION_DAYS,
  deps = {},
}) {
  const run = deps.run ?? runSf;
  const log = deps.log ?? ((line) => console.log(line));
  const now = deps.now ?? Date.now();
  if (mode !== "keeper" && mode !== "borrow") {
    throw new CiOrgError(`Unknown mode "${mode}". Use keeper or borrow.`);
  }
  const ctx = { run, log };
  const cached = readAuthFile(authFile, secret);

  if (mode === "borrow") {
    if (cached && login(cached.authUrl, ctx)) {
      const shown = run(["org", "display", "--target-org", ALIAS, "--json"]);
      if (isUsable(withExpiry(shown.json, cached.expirationDate), now)) {
        return { source: "shared", save: false };
      }
      log("The shared CI org is not usable. Making a one-off org.");
      // The alias `ci` must not point at the shared org while the new org is made: a
      // killed run would then delete the shared org.
      run(["org", "logout", "--target-org", ALIAS, "--no-prompt", "--json"]);
    } else {
      log("No usable shared CI org in the cache. Making a one-off org.");
    }
    createMarked(markerFile, durationDays, ctx);
    return { source: "oneoff", save: false };
  }

  // keeper: free the active slot first, then make a new org.
  retireOldOrg(cached, ctx);
  createMarked(markerFile, durationDays, ctx);
  const shown = run(["org", "display", "--verbose", "--target-org", ALIAS, "--json"]);
  const authUrl = shown.json?.result?.sfdxAuthUrl;
  if (shown.status !== 0 || !authUrl) {
    // Do not leave an org that nobody can borrow. It would hold one of the 3 active slots.
    // The marker stays unless the delete is confirmed, so that the workflow tries again.
    if (deleteOrg(ctx)) clearMarker(markerFile);
    throw new CiOrgError("The new org shows no sfdxAuthUrl, so it cannot be shared.");
  }
  log(maskLine(authUrl));
  // Keep the expiry with the URL. Without the display value, count from the creation time.
  const expirationDate =
    shown.json?.result?.expirationDate ??
    new Date(now + durationDays * DAY_MS).toISOString().slice(0, 10);
  // Keep the org id too: the next keeper run asks the Dev Hub about this org by id.
  const orgId = shown.json?.result?.id;
  try {
    mkdirSync(dirname(authFile), { recursive: true });
    writeFileSync(authFile, encrypt(JSON.stringify({ authUrl, expirationDate, orgId }), secret), {
      mode: 0o600,
    });
  } catch (error) {
    if (deleteOrg(ctx)) clearMarker(markerFile); // An org that is not cached cannot be reused.
    throw error;
  }
  return { source: "created", save: true };
}

export function parseArgs(argv) {
  const [command, ...rest] = argv;
  const out = { command, mode: undefined, authFile: undefined, markerFile: undefined };
  for (let i = 0; i < rest.length; i += 2) {
    const key = {
      "--mode": "mode",
      "--auth-file": "authFile",
      "--marker-file": "markerFile",
    }[rest[i]];
    if (!key || rest[i + 1] === undefined) {
      throw new CiOrgError(`Bad argument: ${rest[i]}`);
    }
    out[key] = rest[i + 1];
  }
  return out;
}

export function main(argv, env = process.env) {
  const args = parseArgs(argv);
  if (args.command !== "prepare" || !args.mode || !args.authFile) {
    throw new CiOrgError(
      "Usage: ci-org.mjs prepare --mode keeper|borrow --auth-file <path>",
    );
  }
  const result = prepare({
    mode: args.mode,
    authFile: args.authFile,
    markerFile: args.markerFile,
    secret: env.DEVHUB_SFDX_AUTH_URL,
  });
  console.log(`CI org: ${result.source}${result.save ? " (to be cached)" : ""}`);
  if (env.GITHUB_OUTPUT) {
    appendFileSync(
      env.GITHUB_OUTPUT,
      `source=${result.source}\nsave=${result.save}\n`,
    );
  }
  // Now the workflow can see the org through the outputs. The marker is no longer needed.
  clearMarker(args.markerFile);
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exit(1);
  }
}
