# Codex PR Review Round 11 Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Address and fix PMD static analysis warnings:
1. **ApexCRUDViolation**: Enforce `WITH USER_MODE` in `BusinessHours` SOQL queries in `StepResult.cls`.
2. **EmptyCatchBlock**: Add a debug statement in the exception handler of `isJsonLike` validation in `StepResult.cls`.

---

## Proposed Changes

### 1. Refactor StepResult.cls
Modify the BusinessHours queries and empty catch blocks.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **`WITH USER_MODE`**: Add `WITH USER_MODE` to the two queries in `getBusinessHours()`.
- **Catch block**: Add `System.debug(LoggingLevel.FINEST, ...)` to the catch block in `serializeHandoffPayload()`.

---

## Verification Plan

### Automated Tests
- Run test suites and verify all pass:
  `sf apex run test -n StepResultBusinessSleepTest,StepResultValidationTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
