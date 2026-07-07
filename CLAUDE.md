# Revenant - Durable Execution Engine for Salesforce

Revenant brings durable execution, sagas, and event-driven orchestration to Apex on the Salesforce Platform.

## Development Workflow

### Commands

- **Deploy changes to default Scratch Org**: `sf project deploy start`
- **Run all Apex tests**: `sf apex run test -w 10`
- **Run specific Apex test class**: `sf apex run test -n <TestClassName> -w 5`
- **Format Apex files**: `npx prettier --write --plugin=prettier-plugin-apex "force-app/main/default/classes/<ClassName>.cls"`

## Architecture Summary

Revenant defines `WorkflowDefinition` DAGs comprised of `WorkflowStep` execution units. The engine preserves step state transitions and event emissions effectively-once via the durable `StepContext`.

- **Durable Patching & Upgrades**: Allows safe step-level upgrades via `ctx.patched()` and `ctx.deprecated()`. Brand-new instances route to the new branch, while pre-existing in-flight instances default to the legacy branch. Decisions are cached and replayed consistently. See [docs/patch-markers.md](file:///c:/Users/markm/revenant/docs/patch-markers.md).

### Test Fixtures

- **Integration Tests**: `WorkflowTestHarness` drives multi-step E2E orchestrations.
- **Unit Tests**: `StepContextTestBuilder` assembles `StepContext` fluently in memory (0 DML, 0 SOQL) for isolated step-level unit testing.
