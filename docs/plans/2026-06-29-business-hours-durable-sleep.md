# Codex PR Review Round 7 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the 365-day walk cap limitation raised in the seventh Codex Pull Request review:
1. **Continue walking remaining business days exactly** (make the calendar walk loop limit dynamic based on the requested duration rather than a static 365-day cap, avoiding incorrect averaging fallbacks).
2. **Add a regression test** covering the 106 business days walk on a Monday (8h) / Tuesday (16h) calendar.

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the loop limit in `getMillisecondsForDays`.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Dynamic Walk Limit**: In `getMillisecondsForDays`:
  - Calculate `maxDays = Math.min(3650, days * 7 + 366)`.
  - Update the loop condition to use `maxDays` instead of `365`:
    ```java
    for (Integer i = 0; i < maxDays && daysAdded < days; i++) {
    ```

### 2. Refactor StepResultBusinessSleepTest.cls
Add the requested 106 business days regression test.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Unequal Day Walk Regression Test**: Add `testUnequalDayWalkLargeDurationRegression`:
  - Instantiates a mock `BusinessHours` record with `TimeZoneSidKey = 'America/Chicago'`, Monday having 8 hours, Tuesday having 16 hours, and all other days closed.
  - Walks 106 business days starting on a Monday.
  - Asserts that it returns exactly the sum of 53 Mondays and 53 Tuesdays (4,579,200,000 ms) instead of using the average daily working milliseconds fallback.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
