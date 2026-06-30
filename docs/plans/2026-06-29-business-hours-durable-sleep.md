# Codex PR Review Round 10 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the averaging fallback issue raised in the tenth Codex Pull Request review:
1. **Reject durations exceeding exact scan limit**: Replace the averaging fallback with an `IllegalArgumentException` if the day walk hits the loop cap before the requested business days are fully accumulated.

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify `getMillisecondsForDays` to reject walks that cannot complete exactly.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Throw Exception**: If `daysAdded < days` (and `daysAdded > 0`), throw an `IllegalArgumentException`:
  ```java
  if (daysAdded < days) {
      throw new IllegalArgumentException(
          'StepResult.sleep: requested business duration exceeds the maximum calendar scan limit of 10 years or the calendar has insufficient open days'
      );
  }
  ```

### 2. Add Regression Test in StepResultBusinessSleepTest.cls
Add a unit test verifying that the exception is thrown.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **`testLargeDurationExceedingScanLimitThrows`**:
  - Mock a `BusinessHours` record with only Monday open.
  - Call `StepResult.sleep(600, 'Days', 'mock_monday_only')` and assert that it throws an `IllegalArgumentException`.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
