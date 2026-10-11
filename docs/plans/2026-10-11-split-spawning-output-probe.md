# SPLIT Spawning Step Output Probe (Issue #332)

## Goal

For a `SPLIT`, the overlay probes the spawning step with its stored output, as
`WorkflowParallelJoin.proceedToJoin` routes it. The overlay then shows the real
step after the join.

## Facts before this change

- The overlay gives the spawning step two synthetic `COMPLETE` results:
  null output and `{}`.
- The engine reads `Output__c` of the spawning row. It calls
  `WorkflowPayloadOffload.resolvePayload` (offload and codec decode). It gives
  the text to `StepResult.complete(null, output)`. That call serializes the
  text again, so `outputJson` is a JSON string.
- The overlay step query reads up to 201 rows. It does not read `Output__c`.
- ADR 0002 point 8: the dashboard does not decode. `resolveControlPayload`
  resolves an offload file and gives null for an encoded value. It never
  calls the codec. `resolveControlPayloadWithin` also skips a large file.
- Both topology endpoints are cacheable. The docs give 2 SOQL for the overlay.
- The author has no org. Apex tests run in CI. The apex-ls compile check runs
  here.

## Brainstorm

| #   | Idea                                                               | Keep?                                                 |
| --- | ------------------------------------------------------------------ | ----------------------------------------------------- |
| B1  | Add `Output__c` to the 201-row step query.                         | No. Up to 201 large values in the heap.               |
| B2  | Read `Output__c` of the spawning row only, by `Id`.                | Yes. 1 SOQL, one value.                               |
| B3  | Resolve the value with `resolvePayload`, as the engine does.       | No. It decodes. ADR 0002 point 8 forbids it.          |
| B4  | Resolve with `resolveControlPayloadWithin`.                        | Yes. Offload file, owner check, size cap, no decode.  |
| B5  | Add a third probe `StepResult.complete(null, output)`.             | Yes. Same object as the engine gives.                 |
| B6  | Use only the real output. Drop the synthetic probes.               | No. The issue keeps the "?" rules.                    |
| B7  | Decode an encoded value after a user-mode access check (ADR 0020). | No. Codec code in a dashboard read. Outside the ADR.  |
| B8  | Add a `NEXT_` reason when the overlay cannot read the output.      | No. The synthetic probes still give a hint. Less API. |
| B9  | `probeStep` gets an output argument. The serial path gives null.   | Yes. One method, no new probe class.                  |

## Reverse Brainstorm (failure modes)

| Way to fail                                              | Prevention                                                           |
| -------------------------------------------------------- | -------------------------------------------------------------------- |
| A large file fills the heap. The read fails.             | Size cap before the read (`ContentSize`). Too large: no third probe. |
| A forged marker reads the file of another instance.      | The owner check in `resolveControlPayloadWithin`. A marker stays.    |
| The dashboard decodes ciphertext.                        | No codec call. An encoded value gives no third probe. Test.          |
| A codec error fails the graph read.                      | No codec call, so no codec error. Test with a codec that throws.     |
| A serial run gets more SOQL.                             | Read the output only for a `SPLIT` with a spawning row. Test.        |
| The probe output differs from the engine output.         | Give the same `String` to `StepResult.complete`. Test.               |
| A blank output adds a probe that the engine does not do. | Blank is the null probe. No third probe.                             |
| The SOQL cost grows with history.                        | One row by `Id`. Offload: 3 SOQL. Fixed bound. Test.                 |

## Six Thinking Hats

- **White (facts):** see "Facts before this change".
- **Red (feeling):** an operator trusts a hint with no "?". A hint that hides
  the real route is worse than "?".
- **Black (risks):** heap, codec code in a cacheable read, ADR 0002, more
  SOQL. The table above gives each prevention.
- **Yellow (benefits):** the real route for each plaintext output. No schema.
  Reuse of an existing resolve seam with an owner check and a size cap.
- **Green (other ways):** B7 can come later if operators need it for encoded
  output. It needs an ADR change.
- **Blue (process):** red tests, minimal code, refactor, docs, agent review,
  pull request with the `run-org-tests` label.

## Decision

- Read `Output__c` of the spawning row by `Id` (1 SOQL).
- Resolve it with `resolveControlPayloadWithin`, cap 500 000 bytes.
- No third probe when the value is blank, encoded or still a marker.
- Else probe with `StepResult.complete(null, output)` and the two synthetic
  probes. The "?" and `canEnd` rules do not change.
- Docs: the overlay adds 1 SOQL for a `SPLIT`, and 3 more for an output in a
  file.

## Steps

1. Write failing tests in `WorkflowTopologyTest`: inline output, offloaded
   output, encoded output with a codec that throws (no decode), output above
   the cap, SOQL bound.
2. Make the tests pass: `probeStep` output argument, spawning row `Id`,
   output read.
3. Clean up. Update `docs/topology-graph.md`.
4. Review the code with agents. Fix each finding.
