# Determinism Lint

Issue #135. The lint finds replay-unsafe calls in step classes before deploy. It points to `once()`. Use it as a CI gate.

The engine runs a step again after a wait, `RETRY`, `SLEEP` or `YIELD`. A call that gives a new value on each run can change what the step does. [Strict determinism mode](strict-determinism.md) finds this at run time. The lint finds it in the source, before the first run.

## Install

The core is Rust, compiled to WebAssembly. The `sf` plugin and the native CLI use the same core.

Build and link the `sf` plugin (Node 22, Rust with the `wasm32-unknown-unknown` target):

```bash
rustup target add wasm32-unknown-unknown
cd tools/sf-plugin-revenant
npm ci
npm run build            # writes lib/revenant_lint.wasm
sf plugins link .
```

Or build the native CLI:

```bash
cargo build --release --manifest-path tools/revenant-lint/Cargo.toml
# binary: tools/revenant-lint/target/release/revenant-lint
```

## Run

```bash
sf revenant lint determinism                      # package directories of sfdx-project.json
sf revenant lint determinism -d force-app -d examples
sf revenant lint determinism --fail-on medium --json

revenant-lint force-app examples                  # native CLI
revenant-lint --json --fail-on never force-app
```

| Flag | Value |
|------|-------|
| `-d`, `--source-dir` | File or directory. Use more than one. Default: the package directories. (Native CLI: positional paths.) |
| `--fail-on` | `high` (default), `medium`, `low`, `never`. |
| `--json` | Print the report as JSON. The `sf` envelope `status` is the exit code. |

| Exit code | Meaning |
|-----------|---------|
| 0 | No defect at or above `--fail-on`. |
| 1 | A defect at or above `--fail-on`. |
| 2 | Usage error or a path that does not exist. |

## What the lint scans

- The body of each step class: a class that implements `WorkflowStep` or `CompensatableStep`. A base class or a sub-interface in the scanned source also counts. Namespaced names (`rvn.WorkflowStep`) also count.
- A class that a `getSteps()` string literal names. Thus a step with a base class in a package is also scanned.
- Nested classes in a step class, except capture producers.

The lint does not scan:

- The body of a class that implements `CaptureProducer`. `once()` runs `produce()` only one time.
- Comments and string literals.
- Files whose top-level class name ends with `Test` (any case).
- Classes that are not steps, and helper classes that a step calls.

## Rules

| Rule | Severity | Calls |
|------|----------|-------|
| `CLOCK_READ` | HIGH | `Datetime.now()`, `System.now()`, `System.today()`, `Date.today()`, `System.currentTimeMillis()` |
| `RANDOM_VALUE` | HIGH | `Math.random()`, `Crypto.getRandom*()`, `Crypto.generateAesKey()`, `UUID.randomUUID()` |
| `USER_CONTEXT` | HIGH | `UserInfo.*()` |
| `ASYNC_ENQUEUE` | HIGH | `System.enqueueJob()`, `System.schedule()`, `System.scheduleBatch()`, `Database.executeBatch()` |
| `SOQL_READ` | MEDIUM | `[SELECT ...]`, `[FIND ...]`, `Database.query*()`, `Database.countQuery*()`, `Database.getQueryLocator*()`, `Search.query()` |

Names match without case. A `System.` prefix also matches (`System.Math.random()`). A member path does not match (`this.userInfo.getName()`).

## Defect codes

| Code | Severity | Meaning |
|------|----------|---------|
| `NON_DETERMINISTIC_SOURCE` | Rule severity | A step class calls a rule API. |
| `STEP_SOURCE_NOT_FOUND` | LOW | `getSteps()` names a class that is not in the scan. The lint did not scan it. |
| `SOURCE_UNREADABLE` | HIGH | A string literal or a block comment has no end. The lint did not scan the file. |

Codes and rule names are stable. Each defect has `code`, `rule` (for `NON_DETERMINISTIC_SOURCE`), `severity`, `className`, `file`, `line`, `column`, `api`, `message` and `remedy`. The report has `version`, `filesScanned`, `stepClassesScanned`, `suppressed` and `defects`, sorted by file and position.

## Correct a defect

Put the call in a `CaptureProducer`. Read the value with `once()`:

```apex
public class ReserveStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    String reservedAt = (String) ctx.captures().once('reservedAt', new NowProducer());
    return StepResult.complete(null, reservedAt);
  }

  private class NowProducer implements CaptureProducer {
    public Object produce() {
      return String.valueOf(Datetime.now().getTime()); // safe: once() replays it
    }
  }
}
```

Return a JSON-native value from `produce()`. See `StepCaptures.once()`.

## Suppress a finding

Examine the call first. If it is safe, add a comment with a reason:

```apex
System.debug(Datetime.now()); // revenant-lint-disable-line: debug output only

// revenant-lint-disable-next-line: the id is only in a log
String trace = String.valueOf(Crypto.getRandomInteger());
```

The comment removes each finding on its line. The report counts suppressed findings.

## CI gate

`.github/workflows/determinism-lint.yml` runs the Rust and plugin tests. To gate your project, add a step before the deploy:

```bash
sf revenant lint determinism --fail-on high
```

## Limits

- The lint reads tokens and class scopes. It is not a type checker. A call through a variable, a helper class or dynamic Apex is not found.
- A supertype name resolves only in the scanned source. A step with a packaged base class is found only through `getSteps()`.
- `getSteps()` names are read from string literals only. A name in a constant is not read.
- Strict determinism mode (#102) is still necessary. It finds divergence that the lint cannot see.
