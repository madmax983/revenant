# Packaging Smoke Test

This test installs a 2GP beta in a scratch org. Then subscriber Apex uses the
`global` API. Issue #255.

## Needs

- A Dev Hub with the package namespace linked.
- A managed 2GP package from `sf package create`. Use its 0Ho Id.
- A scratch org.
- `sf` CLI and `node`.

## Run

```sh
scripts/packaging/smoke.sh <devhub> <scratch-org> <namespace> <package-id>
```

The script does these steps:

1. Makes a temporary project with the namespace. It creates a beta package
   version from it.
2. Installs it in the scratch org.
3. Deploys `scripts/packaging/subscriber/`. `__NS__` becomes the namespace.
4. Runs `SmokeRun.run()`. It throws when a call fails.

`SmokeRun` starts and signals a workflow, reads its status, round-trips a
`PayloadCodec`, and calls a `WorkflowArchiveSink`, `hashCorrelationKey` and
`getArchivedHistory(null)`. The
subscriber classes implement `WorkflowDefinition`, `WorkflowStep`,
`PayloadCodec` and `WorkflowArchiveSink`.

## Without an org

`npm run test:global-api` compiles the same subscriber sources against a stub
that has only the `global` members. It does not install a package.
