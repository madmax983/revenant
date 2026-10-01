# Continuous Integration

Every check runs in GitHub Actions. Each one also runs on your machine.

| Workflow | Job | What it checks | Needs the Dev Hub |
|----------|-----|----------------|-------------------|
| `ci.yml` | Apex format | `prettier --check` of all Apex classes and triggers | No |
| `ci.yml` | LWC Jest | `npm run test:unit:coverage` | No |
| `ci.yml` | Global API | `npm run test:global-api`, with the packaged-view compile (`REQUIRE_APEX_LS=1`) | No |
| `ci.yml` | CI org script | `npm run test:ci-org`: tests for `scripts/ci-org` with a fake `sf` | No |
| `ci.yml` | Code Analyzer | `sf code-analyzer run`, rule selector `recommended` (PMD, ESLint, regex, retire-js, CPD, flow). Fails at High or worse | No |
| `ci.yml` | CI | One job that needs all of the above. Require this one in branch protection | No |
| `apex-tests.yml` | Apex tests and coverage (label `run-org-tests`, nightly, on demand) | The shared CI org (or a one-off org), deploy, all local Apex tests, org-wide coverage of at least `APEX_MIN_COVERAGE` (85) | Yes |
| `sfge.yml` | SFGE | The Code Analyzer graph engine (data-flow rules). Weekly, on main and on demand. Not on pull requests: it takes more than 10 minutes | No |
| `determinism-lint.yml` | Rust core, sf plugin | See `docs/determinism-lint.md` | No |
| `report-types.yml` | Static checks | See `docs/report-types.md` | No |
| `quickstart.yml` | Static checks, Scratch org smoke | See `docs/quickstart.md` | The smoke job |

## The secret

`apex-tests.yml` and the quickstart smoke use the repository secret `DEVHUB_SFDX_AUTH_URL`.
It is the only secret. Without it (for example on a fork pull request) those jobs skip
with a warning. The shared login step is `.github/actions/sf-devhub`.

## The shared CI org

The Dev Hub allows **6 scratch org signups a day**, so `apex-tests.yml` does not make one
org per run. Runs share one CI org. `scripts/ci-org/ci-org.mjs` does the work.

| Run | Mode | What it does |
|-----|------|--------------|
| Nightly on `main`, or "Run workflow" on `main` with `recreate` | keeper | Deletes the old CI org, makes a new one (3 days), saves its auth URL in the Actions cache. One signup. |
| Pull request with the label `run-org-tests`, or "Run workflow" on another branch | borrow | Restores the cache, logs in to the shared org, and checks it is connected with at least 1 day left. If it is not, the run makes a one-off org and deletes it after the tests. |

- **No secret to renew.** The auth URL is encrypted (AES-256-GCM) with a key derived from
  `DEVHUB_SFDX_AUTH_URL`, and the log masks it. A fork pull request has no secret, so it
  cannot decrypt the cache. If you change `DEVHUB_SFDX_AUTH_URL`, the old cache cannot be
  read. The next run makes a one-off org, and the next keeper run replaces the cache.
- **The keeper asks the Dev Hub, not the login.** It saves the org id with the URL. Next
  night it asks the Dev Hub (`ActiveScratchOrg`) whether that org is still active, and
  deletes the record if it is. A failed login cannot hide a live org. If the Dev Hub does
  not answer, or the delete fails, the keeper stops and keeps the old cache, so it does not
  strand an org.
- **No org is stranded by the cache.** The job looks up the new cache entry after the
  save. If the entry is missing (the save only warns on failure), or the run was cancelled
  before it, the last step deletes the new org.
- **The expiry is saved with the URL.** A login from an auth URL does not restore the scratch org's expiry date, so `sf org display` may show none. The keeper saves the expiry in the encrypted file, and a borrower uses it when `sf` shows none. With no expiry from either, the borrower does not trust the org and makes a one-off org.
- **Only `main` can share.** The cache is per branch. A pull request can read the cache
  that `main` saved, but a cache that a pull request saves is not visible to `main`
  or to other pull requests. So only the keeper saves.
- **One run at a time** on the shared org (the job concurrency group `apex-tests-ci-org`).
  A waiting run that a newer run replaces shows as cancelled.
- **The org drifts during the day.** A deploy does not delete a removed class, and a PR
  leaves its new classes in the org. The keeper makes a new org every night, so the
  drift lasts at most a day. To get a clean org now, run the workflow on `main` with
  `recreate`.
- **First run, a cache miss and an evicted cache** all work. The run makes a one-off org.
  GitHub removes a cache after 7 days without a read, and the nightly run reads it.
- **Cost.** About 1 signup a day for the keeper. A one-off org adds 1 for each run that
  finds no shared org. The quickstart smoke still makes 1 org for each PR push that
  touches the engine. Count it in the 6.
- A Dev Hub allows 3 active scratch orgs. The shared org uses 1. The keeper deletes the old org first, and stops (the old org and its cache stay, the next night retries) if the old org cannot be deleted. If `sf org delete scratch` cannot (the CLI knows the org only from an auth URL), it deletes the `ActiveScratchOrg` record through the Dev Hub.

## Run the checks locally

```sh
npm ci
npx prettier --check --plugin=prettier-plugin-apex "force-app/**/*.{cls,trigger}" "examples/**/*.{cls,trigger}"
npm run test:unit
npm run test:global-api
npm run test:ci-org
sf plugins install code-analyzer@5.16.0
sf code-analyzer run --workspace force-app --workspace examples --rule-selector recommended --severity-threshold 2
```

## Code Analyzer

- The config is `code-analyzer.yml`. It ignores `__tests__`, `lib/` and build output.
- The CI version is pinned (`CODE_ANALYZER_VERSION` in `ci.yml` and `sfge.yml`). New rules
  then cannot turn main red. Raise the version on purpose, and fix the new findings in the same pull request.
- The job fails at severity 2 (High) or worse. The Moderate and Low findings are many
  (about 980 today, mostly `ApexUnitTestClassShouldHaveRunAs`, complexity and
  `FieldDeclarationsShouldBeAtStart`). Read them in the `code-analyzer` artifact
  (`results.html`). To tighten the gate, lower `CODE_ANALYZER_FAIL_SEVERITY` to 3 after you fix them.
- Suppress a finding with `@SuppressWarnings('PMD.<Rule>')` on the method, with a reason.
  A trailing `// NOPMD` comment also works, but Prettier can move it to another line.
- SFGE (the graph engine) crashed on a `for` loop over a `??` expression. Put the
  expression in a local variable first.

## Formatting

Apex is formatted with `prettier-plugin-apex`. The parser fails on a variable named
`from`. Use another name.
