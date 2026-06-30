# Codex PR Review Round 8 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the default BusinessHours test expectation failure raised in the eighth Codex Pull Request review:
1. **Derive default business-hours expectation dynamically** (change the hard-coded 172800 seconds assertion to be calculated dynamically from the org's active default `BusinessHours` configuration).

---

## Proposed Changes

### 1. Refactor StepResultBusinessSleepTest.cls
Modify `testBusinessHoursDefaultExplicit` to derive expectations dynamically.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Dynamic Expected Seconds**: In `testBusinessHoursDefaultExplicit`:
  - Query the active default `BusinessHours` in the org.
  - Replicate the start datetime alignment and dynamic day walk + `BusinessHours.add` milliseconds calculation to compute the expected seconds dynamically.
  - Assert that the calculated sleep seconds matches `sleepDurationSeconds`.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
