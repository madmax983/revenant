# Codex PR Review Round 6 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the DST fall-back day walking loop finding raised in the sixth Codex Pull Request review:
1. **Rebuild the next day in the business-hours zone** (advance the day walk using calendar Date additions and reconstruct the next local midday DateTime rather than using GMT `DateTime.addDays(1)`).
2. **Add a regression test** covering this specific DST fall-back scenario.

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the day-walking logic in `getMillisecondsForDays`.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Calendar Date-based Walk**: In `getMillisecondsForDays`:
  - Convert `alignedStart` to a local `Date currentDate` using timezone `tz`.
  - Loop and advance using `currentDate = currentDate.addDays(1)`.
  - Inside the loop, construct a representative midday local DateTime `currentInstant`:
    ```java
    DateTime currentInstant = getLocalMidnight(currentDate, tz).addHours(12);
    ```
    This ensures that day walking is completely immune to DST-induced hour shifts (which typically occur at 02:00 local time).

### 2. Refactor StepResultBusinessSleepTest.cls
Add the requested DST fall-back regression test.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **America/Chicago DST Fallback Test**: Add `testDstFallbackDayWalkingRegression`:
  - Instantiates a mock `BusinessHours` record with `TimeZoneSidKey = 'America/Chicago'`, Sunday having 8 hours, and Monday having 10 hours.
  - Starts the day walk on Sunday, Nov 4, 2018 at 00:30:00 local time (before the DST transition).
  - Asserts that a 2-day walk correctly advances to Monday and returns 18 hours total (Sunday + Monday) rather than double-counting Sunday's 8 hours.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
