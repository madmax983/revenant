# Codex PR Review Round 5 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the positive-offset DST boundary transition finding raised in the fifth Codex Pull Request review:
1. **Compute local midnight with the offset at local midnight** (refine the timezone offset calculation to avoid 1-hour shifts for positive-offset DST transitions like Australia/Sydney).
2. **Add a regression test** covering this specific positive-offset DST transition Sunday.

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify `getLocalMidnight` to use a 1-step timezone offset refinement check.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Offset Refinement Step**: In `getLocalMidnight(Date d, String tz)`:
  - First, query the offset at GMT midnight (`offsetMs1`).
  - Compute a candidate local midnight by subtracting `offsetMs1`.
  - Query the offset at the computed candidate (`offsetMs2`).
  - If the offsets differ (meaning GMT midnight and local midnight fall on opposite sides of a DST transition), adjust the candidate to use `offsetMs2`.

### 2. Refactor StepResultBusinessSleepTest.cls
Add the requested DST-skipping regression test.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Sydney DST Spring-Forward Test**: Add `testPositiveOffsetDstMidnightRefinement` checking that the local midnight for `Australia/Sydney` on October 4, 2026 correctly resolves to October 3, 14:00:00 GMT (using the pre-transition UTC+10 offset).

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
