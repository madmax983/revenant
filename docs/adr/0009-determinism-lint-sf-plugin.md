# ADR 0009: Determinism lint as a Rust core in an `sf` plugin

- **Status:** Accepted
- **Date:** 2026-09-29
- **Issue:** #135

## Context

A step that calls `Datetime.now()`, `Math.random()`, `UserInfo` or `System.enqueueJob()` gets a different result when the engine runs it again. Strict determinism mode (#102) finds this at run time, in production. The issue asks for a check before deploy.

The issue proposes an Apex analyzer that reads `ApexClass.Body`. Problems:

- `WorkflowValidator` is `public`. A subscriber org cannot call it. A new entry point must be `global`, a permanent contract (ADR 0006).
- Apex has no parser. A regex scan must remove comments and strings. Governor limits restrict its CPU time and heap.
- It runs only in an org, after the deploy starts.

## Decision

1. Build the lint as a Rust crate, `tools/revenant-lint`. A lexer makes comments and string literals their own tokens. A scope pass finds class bodies and supertypes. Rules match short token patterns.
2. Compile the crate to `wasm32-unknown-unknown`. The `sf` plugin `tools/sf-plugin-revenant` loads it and adds `sf revenant lint determinism`. The ABI is three C exports: `rl_alloc`, `rl_lint`, `rl_free`. The request and the response are JSON. No wasm-bindgen.
3. The same crate builds the native `revenant-lint` binary for CI and hooks without Node.
4. Find steps by supertype closure in the scanned source, and by `getSteps()` string literals.
5. Exempt only the body of `produce()` in a `CaptureProducer`. That is the `once()` remedy. The constructor and the field initializers of a producer run on each replay, so the lint scans them.
6. HIGH: clock, random, user context, async start, event publish. MEDIUM: SOQL and SOSL. The gate fails on HIGH by default.
7. Fail closed: a file that the lexer cannot read is a HIGH defect. A run that scans no file exits with code 2.
8. Find test files by `@IsTest` on the top-level class, or by a name that ends with `Test` or `_test`. The issue asks for "ends with Test/test". A plain `test` suffix also matches `FetchLatest` and `Contest`, and would hide real steps.

## Consequences

- No Apex change. No `global` change. No schema change. The global API manifest does not change.
- The lint runs on local source, before deploy, in under 1 s for this repo (529 files).
- One `.wasm` file works on each OS. The plugin build needs Rust. `npm run build` makes the file. `prepack` runs it.
- The lint does not satisfy "an Apex deploy-gate test" literally. The CI step `sf revenant lint determinism` is the gate. A later release can add an org-side check that uses the Tooling API, with no new `global` Apex.
- The issue asks for the hazards "across the definition's steps". The lint scans all step classes in the given paths as one project. A defect names its class, not its definition. A step that no definition uses is also scanned.
- The lint does not follow calls into helper classes (out of scope, issue #135).
- Verus was not available in the build container. The invariants are property tests (`tests/properties.rs`).
