# Hello Quickstart Funnel (Issue #133)

## Goal

Give a new author a verified path from a fresh org to a first `Completed` workflow in less than 10 minutes. Add no engine change.

## Facts About The Repo

- `WorkflowEngine.start(name, key, input)` is global. It is get-or-start on the correlation key. It runs the steps in async Queueables.
- The `WorkflowInstanceTrigger` sets `Terminal_At__c` when an instance becomes terminal.
- `Revenant_Admin` grants FLS on the engine objects. A source deploy grants no FLS.
- `config/project-scratch-def.json` asks for Einstein features. Many Dev Hubs cannot make that org.
- The repo has no CI. `apex-ls` (Java) can compile Apex locally.
- There is no `sf` CLI and no org in the dev container. Apex tests run only in an org.

## Brainstorming (options)

| #   | Idea                                                                                 | Keep?                                                                      |
| --- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| B1  | `HelloWorkflow` with two steps: greet, then sign off.                                | Yes. Shows step output handoff. No callout, saga or signal.                |
| B2  | One step only.                                                                       | No. Two steps show the durable hop between Queueables.                     |
| B3  | Put the Hello files in `examples/quickstart/`.                                       | Yes. One `--source-dir` deploys them. It is in the `examples` package.     |
| B4  | `run-hello.apex` calls `WorkflowEngine.start` directly.                              | Yes. The reader sees the real public API.                                  |
| B5  | Verify logic in an Apex class (`HelloWorkflowCheck`), called by `verify-hello.apex`. | Yes. Apex tests cover it. The script stays one line.                       |
| B6  | Verify finds the latest `HelloWorkflow` instance.                                    | Yes. No Id copy and paste.                                                 |
| B7  | Elapsed time = `Terminal_At__c - CreatedDate`.                                       | Yes. Both fields exist. Read only.                                         |
| B8  | A Node runner (`smoke.mjs`) does deploy, permset, run, poll, verify and the budget.  | Yes. Works on Windows, macOS, Linux. Node tests cover it with a fake `sf`. |
| B9  | A Bash runner.                                                                       | No. Not on Windows.                                                        |
| B10 | A minimal scratch definition for the quickstart.                                     | Yes. No Einstein features. More Dev Hubs can make it.                      |
| B11 | CI: one static job (Node tests, apex-ls compile) and one scratch-org job.            | Yes. The static job runs without secrets.                                  |
| B12 | Scratch job fails when the secret is missing.                                        | No. Forks have no secrets. Skip with a warning.                            |
| B13 | Add a `Hello` LWC or dashboard walkthrough.                                          | No. Out of scope.                                                          |

## Reverse Brainstorming (how can this fail?)

| Way to fail                                                     | Prevention                                                                             |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| A second run returns the old instance (get-or-start).           | `run-hello.apex` uses a new key each run.                                              |
| Verify passes on an old instance from an earlier run.           | Verify reads the latest instance by `CreatedDate`. The smoke runner checks the new Id. |
| Verify runs before the Queueables finish and fails.             | Verify says "still running, run again". The runner polls until terminal.               |
| The user has no FLS. User-mode queries fail.                    | The doc and the runner assign `Revenant_Admin`.                                        |
| `Revenant_Admin` is already assigned. The CLI returns an error. | The runner accepts "Duplicate" as success.                                             |
| The scratch org cannot be made (Einstein features).             | Use `config/quickstart-scratch-def.json`.                                              |
| The instance ends `Failed`. The user sees no cause.             | Verify prints the status and `Error_Message__c`.                                       |
| The poll loop hangs.                                            | A poll timeout. Then exit 1.                                                           |
| The path gets slower and nobody sees it.                        | CI records the time and fails over the budget (600 s).                                 |
| The doc drifts from the scripts.                                | A Node test checks the command order and that each named file exists.                  |
| The scripts stop compiling after an engine change.              | The static job compiles the Hello classes and the `.apex` scripts with apex-ls.        |
| The Hello example grows (callouts, signals).                    | A Node test checks at most 2 steps and no callout, signal, sleep, split or saga.       |
| An engine class changes in this PR.                             | Review the diff: no file under `force-app/` changes.                                   |

## Six Thinking Hats

- **White (facts):** The engine has a public start API and a terminal timestamp. It has no quickstart, no run script and no CI.
- **Red (feelings):** A new author fears a long setup. One command and a green line remove that fear.
- **Black (risks):** Scratch orgs need a Dev Hub secret. Forks cannot run that job. Scratch org time varies. Keep the budget at 600 s and record the real number.
- **Yellow (benefits):** A first success in minutes. The first CI in the repo. A regression gate for the start path.
- **Green (ideas):** The runner is also the one-command local path (`npm run quickstart`).
- **Blue (process):** Plan. RED: Node tests and Apex tests. GREEN: the code. REFACTOR. Then a review from many angles.

## TDD Order

1. RED: `scripts/quickstart/*.test.mjs` (runner and static checks). Apex tests `HelloWorkflowTest`, `HelloWorkflowCheckTest`. apex-ls shows the missing classes.
2. GREEN: `HelloWorkflow`, `HelloWorkflowCheck`, the two `.apex` scripts, `smoke.mjs`, the doc, the README link, the CI file.
3. REFACTOR: remove duplication. Format with Prettier.
