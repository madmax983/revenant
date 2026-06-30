# Codex PR Review Round 3 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the P2 finding raised in the third Codex Pull Request review:
1. **Skip holidays while sizing business-day sleeps** (ensure that intermediate holidays are correctly skipped during day walks).

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the day-walking calculation to use native `BusinessHours.diff` for database-backed records.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Local Midnight Helper**: Add `@TestVisible private static DateTime getLocalMidnight(Date d, String tz)`:
  - Computes the GMT DateTime representing midnight of date `d` in the local timezone `tz`.
- **Integrate BusinessHours.diff**: Update `@TestVisible private static Long getWorkingMsForDay(BusinessHours selectedBusinessHours, DateTime dt)`:
  - If `selectedBusinessHours.Id != null` (database record), compute the 24-hour day boundaries using `getLocalMidnight()` and return `BusinessHours.diff(Id, dayStart, dayEnd)`.
  - This natively handles holidays, weekends, and variable day lengths.
  - If `Id` is null (in-memory mock SObject for unit tests), fallback to the raw weekday field switch.

### 2. Refactor StepResultBusinessSleepTest.cls
Add the requested holiday-skipping regression test.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Holiday Variable Spanning Test**: Add `testBusinessHoursHolidaySpanningWithVariableLengthDays` checking that sleeping `2 business days` starting on a Friday skips the holiday Monday and sums only Friday + Tuesday working hours.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
