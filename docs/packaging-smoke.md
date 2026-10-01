# Packaging Smoke Test

This test installs a 2GP beta in a scratch org. Then subscriber Apex uses the
`global` API. Issue #255.

## Needs

- A Dev Hub with the package namespace linked.
- A package named `revenant` (`sf package create`) and a scratch org.
- `sf` CLI and `node`.

## Run

```sh
scripts/packaging/smoke.sh <devhub-alias> <scratch-alias> <namespace>
```

The script does these steps:

1. Creates a beta package version.
2. Installs it in the scratch org.
3. Deploys `scripts/packaging/subscriber/`. `__NS__` becomes the namespace.
4. Runs `SmokeRun.run()`. It throws when a call fails.

`SmokeRun` starts and signals a workflow, reads its status, round-trips a
`PayloadCodec`, and uses a `WorkflowArchiveSink` and `WorkflowArchive`. The
subscriber classes implement `WorkflowDefinition`, `WorkflowStep`,
`PayloadCodec` and `WorkflowArchiveSink`.

## Without an org

`npm run test:global-api` compiles the same subscriber sources against a stub
that has only the `global` members. It does not install a package.
