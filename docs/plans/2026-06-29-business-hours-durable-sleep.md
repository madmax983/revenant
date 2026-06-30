# Codex PR Review Round 2 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the two P2 findings raised in the second Codex Pull Request review:
1. **Use locale-independent weekday keys** (ensure user locales like French do not break the day-of-week switch matching).
2. **Base business-day length on the next open day** (ensure start times falling after business hours or on holidays base their duration on the next active day).

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the day-walking alignment and day-of-week lookup methods.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Aligned Walk Start**: In `getMillisecondsForDays(selectedBusinessHours, start, days)`, align the starting DateTime `current` using:
  ```java
  DateTime current = BusinessHours.isWithin(selectedBusinessHours.Id, start)
    ? start
    : BusinessHours.nextStartDate(selectedBusinessHours.Id, start);
  ```
- **Locale-Independent Day of Week**: Create a private helper method `getDayOfWeek(DateTime dt, String tz)`:
  - Formats `dt` into a locale-independent `'yyyy-MM-dd'` string in the target timezone.
  - Converts that to a local `Date` object.
  - Uses mathematically sound day-difference against a known Sunday reference date (`Date.newInstance(1900, 1, 7)`) to calculate the integer day of the week (0 = Sunday, 1 = Monday, ..., 6 = Saturday).
- **Match switch on Integer**: Update `getWorkingMsForDay` to switch on the integer `dayOfWeekNum` (0 to 6) instead of the localized day string `'Monday'`, `'Tuesday'`.

### 2. Refactor StepResultBusinessSleepTest.cls
Add unit tests for the specific Codex edge cases.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Walk After Hours Test**: Add a test simulating a sleep starting after business hours on Friday (Friday 18:00) with a 4-hour Friday and 8-hour Monday to verify it correctly wakes on Monday at 17:00.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
