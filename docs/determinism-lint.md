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

A linked plugin makes `sf` show a "linked ESM module" warning. To stop it, set `OCLIF_DISABLE_LINKED_ESM_WARNING=1`.

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
| `-d`, `--source-dir` | File or directory. You can use this flag more than one time. Default: the package directories. (Native CLI: positional paths.) |
| `--fail-on` | `high` (default), `medium`, `low`, `never`. The native CLI also accepts `--fail-on=<level>`. |
| `--json` | Print the report as JSON. The `sf` envelope `status` is the exit code. |

| Exit code | Meaning |
|-----------|---------|
| 0 | No defect at or above `--fail-on`. |
| 1 | A defect at or above `--fail-on`. |
| 2 | Usage error, a path that does not exist, a file that the tool cannot read, no `.cls` files to scan, an invalid `sfdx-project.json`, or a lint core that is not built. |

A gate that scans no file fails with exit code 2. Thus a typing error in a path cannot make the gate pass. A file with bytes that are not UTF-8 is scanned. Each bad byte becomes U+FFFD.

## What the lint scans

- The body of each step class: a class that implements `WorkflowStep` or `CompensatableStep`. The lint also finds a step through a base class or a sub-interface in the scanned source, and through a namespaced name (`rvn.WorkflowStep`).
- A class that a `getSteps()` string literal names. Thus the lint also scans a step whose base class is in a package.
- Nested classes in a step class, except capture producers.

A supertype name resolves as in Apex: first a nested type of each enclosing class, then a top-level type.

The lint scans all step classes in the given paths as one project. It does not group defects by definition.

The lint does not scan:

- The body of `produce()` in a class that implements `CaptureProducer`. `once()` runs `produce()` only one time. The lint scans the constructor and the field initializers of a producer, because `new Producer()` runs on each replay.
- Comments and string literals.
- Test files: the top-level class has `@IsTest`, or its name ends with `Test`, or it ends with `_test` (any case). A name such as `FetchLatest` or `Contest` is not a test name.
- Classes that are not steps, and helper classes that a step calls.

## Rules

| Rule | Severity | Calls |
|------|----------|-------|
| `CLOCK_READ` | HIGH | `Datetime.now()`, `System.now()`, `System.today()`, `Date.today()`, `System.currentTimeMillis()` |
| `RANDOM_VALUE` | HIGH | `Math.random()`, `Crypto.getRandom*()`, `Crypto.generateAesKey()`, `UUID.randomUUID()` |
| `USER_CONTEXT` | HIGH | Each `UserInfo` method, for example `UserInfo.getUserId()` |
| `ASYNC_ENQUEUE` | HIGH | `System.enqueueJob()`, `System.schedule()`, `System.scheduleBatch()`, `Database.executeBatch()` |
| `EVENT_PUBLISH` | HIGH | `EventBus.publish()`. Use `ctx.events().emit(event)`. |
| `SOQL_READ` | MEDIUM | `[SELECT ...]`, `[FIND ...]`, `Database.query*()`, `Database.countQuery*()`, `Database.getQueryLocator*()`, `Database.getCursor*()`, `Search.query()`, `Search.find()` |

The lint ignores the case of names. A `System.` prefix also matches (`System.Math.random()`). A member path does not match (`this.userInfo.getName()`). A local map named `userInfo` does not match, because `get()` is not a `UserInfo` method.

## Defect codes

| Code | Severity | Meaning |
|------|----------|---------|
| `NON_DETERMINISTIC_SOURCE` | Rule severity | A step class calls a rule API. |
| `STEP_SOURCE_NOT_FOUND` | LOW | `getSteps()` names a class that is not in the scan. The lint did not scan it. |
| `SOURCE_UNREADABLE` | HIGH | A string literal or a block comment has no end. The lint did not scan the file. |

Codes and rule names are stable. Each defect has `code`, `rule` (for `NON_DETERMINISTIC_SOURCE`), `severity`, `className`, `file`, `line`, `column`, `api`, `message` and `remedy`. The report has `version`, `filesScanned`, `stepClassesScanned`, `suppressed` and `defects`. The lint sorts the defects by file and position.

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

`revenant-lint-disable-line` removes all findings on each line of its comment. `revenant-lint-disable-next-line` removes all findings on the line after its comment. A call or a query that continues on more lines, up to its closing `)` or `]`, is removed when a marker covers one of its lines. The marker must end at a word boundary: `revenant-lint-disable-lines` is not a marker. The lint does not check the reason. The report counts the removed findings.

## CI gate

`.github/workflows/determinism-lint.yml` runs the Rust and plugin tests. To stop a deploy that has a HIGH defect, add this step before the deploy step:

```bash
sf revenant lint determinism --fail-on high
```

## Limits

- The lint reads tokens and class scopes. It is not a type checker. The lint does not find a call through a variable, a helper class or dynamic Apex.
- A supertype name resolves only in the scanned source. The lint finds a step with a packaged base class only through `getSteps()`.
- The lint reads `getSteps()` names only from string literals. It does not read a name in a constant.
- In a producer, the lint scans each method other than `produce()`. A helper method that only `produce()` calls can give a finding. Examine it, then suppress it with a reason.
- For a `getSteps()` name `a.B`, the lint first looks for the class `a.B`. If it is not in the scan, the lint reads `a` as a namespace and looks for the class `B`. Thus, when the outer class `a` is not in the scan, the lint can scan an unrelated top-level class `B`.
- Strict determinism mode (#102) is still necessary. It finds divergence that the lint cannot see.
