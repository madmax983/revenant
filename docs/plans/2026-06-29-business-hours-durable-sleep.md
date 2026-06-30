# Code Review & Refactoring Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor the business-hours-aware sleep implementation in `StepResult.cls` and `StepResultBusinessSleepTest.cls` to resolve all findings from security, performance, and clean code subagent reviews.

**Architecture:** We will clean up the code by extracting constants, applying `switch on`, and extracting time-to-millisecond conversion. We will optimize performance by caching daily business-day calculations and caching default BusinessHours under both names. We will enhance safety by validating parameters, checking for integer overflow, and dynamically adjusting tests to avoid hardcoded metadata dependencies.

**Tech Stack:** Apex (Standard BusinessHours and Holiday APIs).

---

## Proposed Changes

### 1. Refactor StepResult.cls
Apply clean code, caching optimization, and parameter validation.

**Files:**
- Modify: [StepResult.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResult.cls)

#### Code Changes:
- **Constants Definition**: Add static final Long constants for conversion factors (seconds, minutes, hours, days).
- **Time Conversion Helper**: Add `getMillisecondsSinceMidnight(Time t)`.
- **SOQL Consolidating**: Use boolean bind variable to run a single unified SOQL query in `getBusinessHours(String name)`.
- **Dual-Name Caching & Trimming**: Trim input names and cache default BusinessHours under both `'default'` and its actual name.
- **Math Caching**: Add `msPerBusinessDayByBhId` static map to cache milliseconds per day.
- **Unit Parsing**: Use `switch on` instead of chain of `if/else`.
- **Overflow Prevention**: Check if calculated `sleepSeconds` exceeds `Integer.MAX_VALUE` and cap it safely.
- **Safety Validation**: Check for null/negative inputs in sleep factories.

### 2. Refactor StepResultBusinessSleepTest.cls
Apply Assert class, add caching effectiveness tests, and make tests metadata-independent.

**Files:**
- Modify: [StepResultBusinessSleepTest.cls](file:///c:/Users/markm/revenant/force-app/main/default/classes/StepResultBusinessSleepTest.cls)

#### Code Changes:
- **Use Assert Class**: Replace legacy `System.assertEquals` and `System.assert` with Winter '23 `Assert` methods.
- **Dynamic Metadata Handling**: Query active BusinessHours dynamically and calculate expected sleep duration dynamically in the test so that it runs correctly on any org.
- **Conditional Holiday-Spanning Test**: Only execute the holiday test case if `"Standard Business Hours"` is present, preventing test failures in environments where examples metadata is not deployed.
- **Caching Test Case**: Add `testBusinessHoursCachingEffectiveness()` to verify caching of SOQL queries.

---

## Verification Plan

### Automated Tests
- Run new and local tests:
  `sf apex run test -n StepResultBusinessSleepTest -w 5 -r human`
  `sf apex run test --test-level RunLocalTests -w 10 -r human`
