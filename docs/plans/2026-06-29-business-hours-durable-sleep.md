# Codex Code Review Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the two P2 findings raised in the Codex Pull Request review:
1. **Preserve valid scalar JSON handoff payloads** (prevent double-serialization of `"true"`, `"123"`, `"null"`).
2. **Avoid averaging unequal business-day lengths** (prevent early wake-ups on days with shorter schedules, e.g. Friday afternoons).

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the day-walking calculation and JSON parsing heuristic.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **TimeZoneSidKey in Query**: Add `TimeZoneSidKey` to the SOQL queries in `getBusinessHours(String name)`.
- **Day-by-Day Walking**: Replace the average daily working-milliseconds calculation in `getMillisecondsInBusinessDay(selectedBusinessHours)` with a day-by-day walking method `getMillisecondsForDays(selectedBusinessHours, start, days)`.
  - This method will start at the mock/current DateTime, get the day of week in the BusinessHours' local timezone, sum the working milliseconds for active days, and return the exact total interval.
- **Robust JSON Heuristic**: Enhance `serializeInputIfNeeded(input)` to identify and preserve pre-serialized JSON scalar strings (e.g. numbers, booleans, null, quoted strings) using a fast regex and string heuristic, avoiding exceptions for non-JSON strings.

### 2. Refactor StepResultBusinessSleepTest.cls
Add unit tests for the specific Codex edge cases.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Unequal Days Test Case**: Add a test method simulating a Business Hours config with unequal working hours per day to verify that sleeping `1 Day` resolves to the correct duration for that specific day.
- **Scalar JSON Test Case**: Add a test verifying that pre-serialized JSON scalar strings passed to `startChild` are not double-serialized.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
