# Codex PR Review Round 9 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the standard BusinessHours calendar expectation failures raised in the ninth Codex Pull Request review:
1. **Derive standard business-hours expectation dynamically** (change the hard-coded `432000` seconds assertion in `testBusinessHoursHolidaySpanning` and holiday skipping assertions to be calculated dynamically from the queried standard `BusinessHours` configuration and holiday treatment).

---

## Proposed Changes

### 1. Refactor StepResultBusinessSleepTest.cls
Modify the standard and default BusinessHours tests to derive expectations dynamically.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Dynamic expectation in `testBusinessHoursDaysSleep`**:
  - Recompute the expected sleep duration seconds using `StepResult.getMillisecondsForDays` instead of assuming equal daily working lengths.
- **Dynamic expectation in `testBusinessHoursHolidaySpanning`**:
  - Recompute the expected sleep duration seconds dynamically via `StepResult.getMillisecondsForDays` and `BusinessHours.add` for standard business hours, avoiding the hardcoded `432000` seconds.
- **Dynamic holiday logic in `testBusinessHoursHolidaySpanningWithVariableLengthDays`**:
  - Query if Monday June 29, 2026 is actually open or closed on the default BusinessHours calendar, and dynamically configure the expected milliseconds as Friday + Tuesday (if closed/holiday) or Friday + Monday (if open/normal day).

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
