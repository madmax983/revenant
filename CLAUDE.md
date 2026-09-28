# Revenant - Durable Execution Engine for Salesforce

Revenant brings durable execution, sagas, and event-driven orchestration to Apex on the Salesforce Platform.

## Development Workflow

### Commands
- **Deploy changes to default Scratch Org**: `sf project deploy start`
- **Run all Apex tests**: `sf apex run test -w 10`
- **Run specific Apex test class**: `sf apex run test -n <TestClassName> -w 5`
- **Check the frozen global API**: `npm run test:global-api` (packaged-view compile needs Java and apex-ls; with Maven, run `scripts/global-api/fetch-apex-ls.sh` one time)
- **Format Apex files**: `npx prettier --write --plugin=prettier-plugin-apex "force-app/main/default/classes/<ClassName>.cls"`

## Architecture Summary
Revenant defines `WorkflowDefinition` DAGs comprised of `WorkflowStep` execution units. The engine preserves step state transitions and event emissions effectively-once via the durable `StepContext`.

### Test Fixtures
- **Integration Tests**: `WorkflowTestHarness` drives multi-step E2E orchestrations.
- **Unit Tests**: `StepContextTestBuilder` assembles `StepContext` fluently in memory (0 DML, 0 SOQL) for isolated step-level unit testing.

### Global API
Only the members in `docs/global-api.md` are `global`. A change to a `global` declaration must change that manifest in the same commit. Do not add `global` to engine internals.
