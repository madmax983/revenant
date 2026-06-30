# Codex PR Review Round 4 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix the DST edge-case finding raised in the fourth Codex Pull Request review:
1. **Recompute dayEnd in the business-hours time zone** (ensure DST spring-forward/fall-back transitions do not cause 1-hour shifts in day boundaries).

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the timezone-aware day boundary calculations.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **DST-Safe Boundaries**: In `getWorkingMsForDay(selectedBusinessHours, dt)`, change the calculation of `dayEnd`:
  ```java
  Date localDate = Date.valueOf(dt.format('yyyy-MM-dd', tz));
  DateTime dayStart = getLocalMidnight(localDate, tz);
  DateTime dayEnd = getLocalMidnight(localDate.addDays(1), tz);
  ```
  - This ensures `dayEnd` is always evaluated as the local midnight of the subsequent day, adjusting automatically for DST shifts.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
