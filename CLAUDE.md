# Revenant - Durable Execution Engine for Salesforce

Revenant brings durable execution, sagas, and event-driven orchestration to Apex on the Salesforce Platform.

## Development Workflow

### Commands
- **Deploy changes to default Scratch Org**: `sf project deploy start`
- **Run all Apex tests**: `sf apex run test -w 10`
- **Run specific Apex test class**: `sf apex run test -n <TestClassName> -w 5`
- **Check the frozen global API**: `npm run test:global-api` (packaged-view compile needs Java and apex-ls; with Maven, run `scripts/global-api/fetch-apex-ls.sh` one time)
- **Check the shared CI org script**: `npm run test:ci-org` (see `docs/ci.md`)
- **Compile all Apex without an org**: `npm run check:apex-compile` (needs Java, apex-ls and the submodule; see `docs/ci.md`)
- **Check the quickstart runner, doc and scripts**: `npm run test:quickstart`
- **Check the Custom Report Types**: `npm run test:report-types` (see `docs/report-types.md`)
- **Run the quickstart on the default org**: `npm run quickstart` (see `docs/quickstart.md`)
- **Check the determinism lint (Rust core and sf plugin)**: `npm run test:determinism-lint` (needs Rust and the `wasm32-unknown-unknown` target)
- **Lint step code for replay safety**: `sf revenant lint determinism` after `npm ci`, `npm run build` and `sf plugins link .` in `tools/sf-plugin-revenant` (see `docs/determinism-lint.md`)
- **Check Apex formatting (as CI does)**: `npx prettier --check --plugin=prettier-plugin-apex "force-app/**/*.{cls,trigger}" "examples/**/*.{cls,trigger}"`
- **Run Code Analyzer (as CI does)**: `sf code-analyzer run --workspace force-app --workspace examples --rule-selector recommended --severity-threshold 2` (see `docs/ci.md`)
- **Format Apex files**: `npx prettier --write --plugin=prettier-plugin-apex "force-app/main/default/classes/<ClassName>.cls"`

## Architecture Summary
Revenant defines `WorkflowDefinition` DAGs comprised of `WorkflowStep` execution units. The engine preserves step state transitions and event emissions effectively-once via the durable `StepContext`.

### Test Fixtures
- **Integration Tests**: `WorkflowTestHarness` drives multi-step E2E orchestrations.
- **Unit Tests**: `StepContextTestBuilder` assembles `StepContext` fluently in memory (0 DML, 0 SOQL) for isolated step-level unit testing.

### Global API
Only the members in `docs/global-api.md` are `global`. A change to a `global` declaration must change that manifest in the same commit. Do not add `global` to engine internals.
