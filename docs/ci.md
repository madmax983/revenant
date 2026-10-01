# Continuous Integration

Every check runs in GitHub Actions. Each one also runs on your machine.

| Workflow | Job | What it checks | Needs the Dev Hub |
|----------|-----|----------------|-------------------|
| `ci.yml` | Apex format | `prettier --check` of all Apex classes and triggers | No |
| `ci.yml` | LWC Jest | `npm run test:unit:coverage` | No |
| `ci.yml` | Global API | `npm run test:global-api`, with the packaged-view compile (`REQUIRE_APEX_LS=1`) | No |
| `ci.yml` | Code Analyzer | `sf code-analyzer run`, rule selector `recommended` (PMD, ESLint, regex, retire-js, CPD, flow). Fails at High or worse | No |
| `ci.yml` | CI | One job that needs all of the above. Require this one in branch protection | No |
| `apex-tests.yml` | Apex tests and coverage | A new scratch org, deploy, all local Apex tests, org-wide coverage of at least `APEX_MIN_COVERAGE` (85) | Yes |
| `sfge.yml` | SFGE | The Code Analyzer graph engine (data-flow rules). Weekly, on main and on demand. Not on pull requests: it takes more than 10 minutes | No |
| `determinism-lint.yml` | Rust core, sf plugin | See `docs/determinism-lint.md` | No |
| `report-types.yml` | Static checks | See `docs/report-types.md` | No |
| `quickstart.yml` | Static checks, Scratch org smoke | See `docs/quickstart.md` | The smoke job |

## The secret

`apex-tests.yml` and the quickstart smoke use the repository secret `DEVHUB_SFDX_AUTH_URL`.
Without it (for example on a fork pull request) those jobs skip with a warning. The shared
login step is `.github/actions/sf-devhub`. Each run uses one scratch org from the daily
Dev Hub limit, so both workflows run only when the engine or its inputs change, and
a new push to a pull request cancels the old run.

## Run the checks locally

```sh
npm ci
npx prettier --check --plugin=prettier-plugin-apex "force-app/**/*.{cls,trigger}" "examples/**/*.{cls,trigger}"
npm run test:unit
npm run test:global-api
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
