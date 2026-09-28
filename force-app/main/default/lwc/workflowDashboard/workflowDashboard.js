/* eslint-disable @lwc/lwc/no-async-operation */
// This file keeps three intentional timers that have no behavior-preserving,
// platform-native replacement in LWC:
//  - handleSearchChange: 300ms debounce over SERVER-SIDE search (SOQL LIKE across
//    Name/Correlation_Key__c/Workflow_Name__c/Error_Message__c, paginated) — no timer-free debounce exists.
//  - startPolling: short self-terminating burst poll (2s x10) for immediate feedback after an operator action.
//  - startAutoRefresh: steady 5s refresh of list + stats + stalled/unrouted counts, including NON-terminal
//    changes the Workflow_Lifecycle__e (terminal-only, config-toggleable) and Workflow_Event__e (internal
//    control-plane) platform events do not emit. An empApi migration would change behavior and needs a live org.
// The requestAnimationFrame scroll-restore that this disable also covered was replaced by renderedCallback.
import { LightningElement, api, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getFilteredInstances from "@salesforce/apex/WorkflowDashboardController.getFilteredInstances";
import getWorkflowStats from "@salesforce/apex/WorkflowDashboardController.getWorkflowStats";
import getInstanceDetails from "@salesforce/apex/WorkflowDashboardController.getInstanceDetails";
import getInstanceChain from "@salesforce/apex/WorkflowDashboardController.getInstanceChain";
import getDefinitions from "@salesforce/apex/WorkflowDashboardController.getDefinitions";
import getWorkflowCatalog from "@salesforce/apex/WorkflowDashboardController.getWorkflowCatalog";
import startWorkflow from "@salesforce/apex/WorkflowDashboardCommandController.startWorkflow";
import retryWorkflowInstance from "@salesforce/apex/WorkflowDashboardCommandController.retryWorkflowInstance";
import getRedriveEligibleCount from "@salesforce/apex/WorkflowDashboardController.getRedriveEligibleCount";
import redriveMatchingInstances from "@salesforce/apex/WorkflowDashboardCommandController.redriveMatchingInstances";
import getCancelEligibleCount from "@salesforce/apex/WorkflowDashboardController.getCancelEligibleCount";
import cancelMatchingInstances from "@salesforce/apex/WorkflowDashboardCommandController.cancelMatchingInstances";
import resumeWorkflowInstance from "@salesforce/apex/WorkflowDashboardCommandController.resumeWorkflowInstance";
import resumeCompensationInstance from "@salesforce/apex/WorkflowDashboardCommandController.resumeCompensationInstance";
import releaseDefinitionChangedInstance from "@salesforce/apex/WorkflowDashboardCommandController.releaseDefinitionChangedInstance";
import holdInstance from "@salesforce/apex/WorkflowDashboardCommandController.holdInstance";
import releaseHeldInstance from "@salesforce/apex/WorkflowDashboardCommandController.releaseHeldInstance";
import cancelWorkflow from "@salesforce/apex/WorkflowDashboardCommandController.cancelWorkflow";
import submitApproval from "@salesforce/apex/WorkflowDashboardCommandController.submitApproval";
import getWatchdogStatus from "@salesforce/apex/WorkflowDashboardController.getWatchdogStatus";
import enqueueWatchdog from "@salesforce/apex/WorkflowDashboardCommandController.enqueueWatchdog";
import getStalledInstances from "@salesforce/apex/WorkflowDashboardController.getStalledInstances";
import getStalledCount from "@salesforce/apex/WorkflowDashboardController.getStalledCount";
import getVersionDrain from "@salesforce/apex/WorkflowDashboardController.getVersionDrain";
import getUnroutedSignals from "@salesforce/apex/WorkflowDashboardController.getUnroutedSignals";
import getUnroutedSignalCount from "@salesforce/apex/WorkflowDashboardController.getUnroutedSignalCount";
import redeliverSignal from "@salesforce/apex/WorkflowDashboardCommandController.redeliverSignal";
import pauseDefinition from "@salesforce/apex/WorkflowDashboardCommandController.pauseDefinition";
import resumeDefinition from "@salesforce/apex/WorkflowDashboardCommandController.resumeDefinition";
import getConcurrencyStatus from "@salesforce/apex/WorkflowDashboardController.getConcurrencyStatus";
import getStorageFootprint from "@salesforce/apex/WorkflowDashboardController.getStorageFootprint";
import getReadinessChecks from "@salesforce/apex/WorkflowReadinessController.getReadinessChecks";
import getRateLimitStatus from "@salesforce/apex/WorkflowRateLimitController.getRateLimitStatus";
import getFleetHealth from "@salesforce/apex/WorkflowFleetHealthController.getFleetHealth";
import getDefinitionTrends from "@salesforce/apex/WorkflowDashboardController.getDefinitionTrends";
import getWorkflowFailureBreakdown from "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown";
import getDefinitionLatency from "@salesforce/apex/WorkflowDashboardController.getDefinitionLatency";
import compensateWorkflow from "@salesforce/apex/WorkflowDashboardCommandController.compensateWorkflow";
import injectSignal from "@salesforce/apex/WorkflowDashboardCommandController.injectSignal";
import resumePastStepInstance from "@salesforce/apex/WorkflowDashboardCommandController.resumePastStepInstance";
import LightningConfirm from "lightning/confirm";

// Rate Limits panel: status code to glyph, word and colour. Unknown is its own state.
const RATE_LIMIT_STATUS = {
  THROTTLING: {
    label: "Throttling",
    badgeClass: "badge badge-orange",
    icon: "utility:warning",
    iconClass: "slds-m-right_xx-small text-orange-icon",
  },
  INVALID: {
    label: "Invalid config",
    badgeClass: "badge badge-red",
    icon: "utility:error",
    iconClass: "slds-m-right_xx-small text-red-icon",
  },
  AVAILABLE: { label: "Available", badgeClass: "badge badge-green" },
  IDLE: { label: "Idle", badgeClass: "badge badge-grey" },
};
const RATE_LIMIT_UNKNOWN = {
  label: "Unknown",
  badgeClass: "badge badge-grey",
  icon: "utility:question",
  iconClass: "slds-m-right_xx-small text-weak-icon",
};

// Readiness panel (#114). Each status has a word and an icon, not only a colour.
const READINESS_STATUS = {
  Fail: {
    label: "Fail",
    badgeClass: "badge badge-red",
    icon: "utility:error",
    iconClass: "slds-m-right_xx-small text-red-icon",
  },
  Warn: {
    label: "Warn",
    badgeClass: "badge badge-orange",
    icon: "utility:warning",
    iconClass: "slds-m-right_xx-small text-orange-icon",
  },
  Pass: {
    label: "Pass",
    badgeClass: "badge badge-green",
    icon: "utility:success",
    iconClass: "slds-m-right_xx-small text-green-icon",
  },
};
const READINESS_UNKNOWN = {
  label: "Unknown",
  badgeClass: "badge badge-grey",
  icon: "utility:question",
  iconClass: "slds-m-right_xx-small text-weak-icon",
};
// Watchdog liveness (#113): state code to word and colour.
const LIVENESS_STATUS = {
  HEALTHY: { label: "Healthy", badgeClass: "badge badge-green" },
  STALE: { label: "Stale", badgeClass: "badge badge-red" },
};
const LIVENESS_UNKNOWN = { label: "Unknown", badgeClass: "badge badge-grey" };

// Platform Event allocation (#120). Defaults match PlatformEventHeadroom.cls.
const PE_DEFAULT_WARNING_PERCENT = 80;
const PE_DEFAULT_CRITICAL_PERCENT = 95;
const PE_STATUS = {
  HEALTHY: { label: "Healthy", badgeClass: "badge badge-green", rank: 1 },
  WARNING: { label: "Warning", badgeClass: "badge badge-orange", rank: 2 },
  CRITICAL: { label: "Critical", badgeClass: "badge badge-red", rank: 3 },
};
const PE_UNAVAILABLE = {
  label: "Not available",
  badgeClass: "badge badge-grey",
  rank: 0,
};
const PE_INTRO =
  "The Platform Event allocation of the org is almost full. All apps in the org share this allocation.";
// Consequence for each impact, in display order. A key with no known impact
// uses PUBLISH, the most severe text.
const PE_IMPACT_TEXT = [
  {
    key: "PUBLISH",
    text:
      "Suspended workflows can stay suspended. Child-to-parent resumes and parallel fan-in can stop. " +
      "The engine can fail to publish lifecycle events.",
  },
  {
    key: "DELIVERY",
    text:
      "External subscribers (CometD, Pub/Sub API, empApi) can stop receiving events, for example Workflow_Lifecycle__e. " +
      "Delivery to Apex triggers does not use this allocation.",
  },
  {
    key: "STANDARD_VOLUME",
    text:
      "Standard-volume events of other apps can fail. " +
      "Revenant events are high-volume and do not use this allocation.",
  },
];
const PE_IGNORED_TEXT =
  "Page settings ignored: Warning must be more than 0 and less than Critical. Critical must be 100 or less.";

// Same rule as PlatformEventHeadroom.classify: exact ratio, no rounding.
function classifyHeadroom(value, limit, warningPercent, criticalPercent) {
  if (!(limit > 0) || value === null || value === undefined) {
    return "UNAVAILABLE";
  }
  const scaledUsed = value * 100;
  if (scaledUsed >= criticalPercent * limit) {
    return "CRITICAL";
  }
  if (scaledUsed >= warningPercent * limit) {
    return "WARNING";
  }
  return "HEALTHY";
}

function isThresholdSet(value) {
  return value !== undefined && value !== null && value !== "";
}

// Resolves the thresholds. Valid App Builder values replace the server
// values. If the App Builder values are not valid, the server values apply.
function resolvePeThresholds(data, warningSetting, criticalSetting) {
  const base = {
    warning: isThresholdSet(data.platformEventWarningPercent)
      ? Number(data.platformEventWarningPercent)
      : PE_DEFAULT_WARNING_PERCENT,
    critical: isThresholdSet(data.platformEventCriticalPercent)
      ? Number(data.platformEventCriticalPercent)
      : PE_DEFAULT_CRITICAL_PERCENT,
    overridden: false,
    ignored: false,
  };
  const warnSet = isThresholdSet(warningSetting);
  const critSet = isThresholdSet(criticalSetting);
  if (!warnSet && !critSet) {
    return base;
  }
  const warning = warnSet ? Number(warningSetting) : base.warning;
  const critical = critSet ? Number(criticalSetting) : base.critical;
  const valid =
    Number.isFinite(warning) &&
    Number.isFinite(critical) &&
    warning > 0 &&
    warning < critical &&
    critical <= 100;
  return valid
    ? { warning, critical, overridden: true, ignored: false }
    : { ...base, ignored: true };
}

function formatCount(value) {
  return Number(value).toLocaleString();
}

// Builds the panel model one time for each data or setting change.
function buildPeView(data, warningSetting, criticalSetting) {
  const source = data || {};
  const thresholds = resolvePeThresholds(
    source,
    warningSetting,
    criticalSetting,
  );
  const rows = (source.platformEventLimits || [])
    .map((row) => {
      const state = thresholds.overridden
        ? classifyHeadroom(
            row.value,
            row.limit,
            thresholds.warning,
            thresholds.critical,
          )
        : row.state;
      const status = PE_STATUS[state] || PE_UNAVAILABLE;
      return {
        ...row,
        key: row.name,
        state,
        rank: status.rank,
        stateLabel: status.label,
        badgeClass: status.badgeClass,
        usageLabel: `${formatCount(row.value)} / ${formatCount(row.limit)}`,
        usedLabel: `${row.percentUsed}% used`,
        remainingLabel: `${formatCount(row.remaining)} remaining (${row.percentRemaining}%)`,
      };
    })
    .filter((row) => row.rank > PE_UNAVAILABLE.rank);
  const status = rows.reduce(
    (worst, row) =>
      row.rank > worst.rank ? PE_STATUS[row.state] || worst : worst,
    PE_UNAVAILABLE,
  );
  const atRiskImpacts = new Set(
    rows
      .filter((row) => row.rank >= PE_STATUS.WARNING.rank)
      .map((row) =>
        PE_IMPACT_TEXT.some((i) => i.key === row.impact)
          ? row.impact
          : "PUBLISH",
      ),
  );
  const critical = status.rank >= PE_STATUS.CRITICAL.rank;
  let thresholdsLabel = `Warning at ${thresholds.warning}% · Critical at ${thresholds.critical}%`;
  if (thresholds.overridden) {
    thresholdsLabel += " (page setting)";
  }
  if (thresholds.ignored) {
    thresholdsLabel += `. ${PE_IGNORED_TEXT}`;
  }
  return {
    rows,
    hasRows: rows.length > 0,
    status,
    atRisk: status.rank >= PE_STATUS.WARNING.rank,
    consequenceClass: `slds-scoped-notification slds-media slds-media_center slds-m-bottom_small ${
      critical ? "slds-theme_error" : "slds-theme_warning"
    }`,
    consequenceIcon: critical ? "utility:error" : "utility:warning",
    consequenceIntro: PE_INTRO,
    consequenceLines: PE_IMPACT_TEXT.filter((i) => atRiskImpacts.has(i.key)),
    thresholdsLabel,
  };
}

const FAILURE_CATEGORY_LABELS = {
  STEP_EXCEPTION: "Step Exception",
  RETRIES_EXHAUSTED: "Retries Exhausted",
  TIMEOUT: "Timeout",
  COMPENSATION_FAILED: "Compensation Failed",
  EXPLICIT_FAIL: "Explicit Step Failure",
  STEP_NON_DETERMINISM: "Step Non-Determinism",
  STEP_HISTORY_LIMIT: "Step History Limit",
  UNKNOWN: "Unknown",
};

// Rolling windows shared by Definition Health and Fleet Health.
const ROLLING_WINDOW_OPTIONS = [
  { label: "Last 1 hour", value: "1h" },
  { label: "Last 24 hours", value: "24h" },
  { label: "Last 7 days", value: "7d" },
];

const ASYNC_LIMITS = {
  CPU: 60000,
  SOQL: 200,
  HEAP: 12000000,
};

export default class WorkflowDashboard extends LightningElement {
  // App Builder settings for the Platform Event thresholds (#120). If a value
  // is blank or not valid, the component uses the server values.
  @api
  get platformEventWarningPercent() {
    return this._peWarningSetting;
  }
  set platformEventWarningPercent(value) {
    this._peWarningSetting = value;
    this.refreshPeView();
  }

  @api
  get platformEventCriticalPercent() {
    return this._peCriticalSetting;
  }
  set platformEventCriticalPercent(value) {
    this._peCriticalSetting = value;
    this.refreshPeView();
  }

  _peWarningSetting;
  _peCriticalSetting;
  peView = buildPeView(null);

  instances = [];
  filteredInstances = [];
  definitions = [];
  stats = { total: 0, active: 0, completed: 0, failed: 0 };

  // UI state
  selectedInstanceId;
  selectedInst = {};
  steps = [];
  childInstances = [];
  loadingDetails = false;
  successor = null;

  // Continue-As-New chain (issue #116). chainAnchorId is the instance that
  // loaded the first page; older pages use the same anchor.
  chainActive = false;
  chainLoading = false;
  chainError = null;
  chainGenerations = [];
  chainTotal = 0;
  chainTotalCapped = false;
  chainNextCursor = null;
  chainAnchorId = null;
  chainRequestSeq = 0;
  _pendingChainScrollTop = null;
  approvalComments = "";
  // Issue #119: reason typed before Hold, and the instance it is for.
  holdReason = "";
  holdReasonInstanceId = null;
  modalOpen = false;
  searchTerm = "";
  viewingDoctor = false;
  loadingDoctor = false;
  doctorData = { config: {} };
  concurrencyRows = [];

  // Storage Footprint panel state (System Doctor). storageData holds the shaped
  // per-object rows and allowance metrics returned by getStorageFootprint.
  storageData = null;
  storageObjectRows = [];

  // Readiness panel state (System Doctor, #114).
  readinessRows = [];
  readinessError = null;
  readinessLoaded = false;
  readinessElapsedMs = null;
  readinessRunning = false;
  readinessRequestSeq = 0;

  // Rate Limits panel state (System Doctor, #61).
  rateLimitRows = [];
  rateLimitAsOfMs = null;
  rateLimitError = null;
  rateLimitLoaded = false;
  rateLimitRequestSeq = 0;

  // Schedules view state (renders the standalone workflowScheduleManager component)
  viewingSchedules = false;

  // Version Drain state
  viewingDrain = false;
  loadingDrain = false;
  drainRows = [];
  drainWorkflow = "";

  // Unrouted Signals state
  viewingUnrouted = false;
  loadingUnrouted = false;
  unroutedSignals = [];
  unroutedCountData = { count: 0, capped: false };
  redelivering = {};

  // Pause / resume state
  pauseModalOpen = false;
  pauseModalTarget = ""; // definition name or * for all
  pauseModalReason = "";
  pauseModalIsResume = false; // true when confirming a resume
  loadingPause = false;

  get pauseModalTitle() {
    return this.pauseModalIsResume ? "Resume Definition" : "Pause Definition";
  }

  // Launch Modal Fields
  launchName = "";
  launchKey = "";
  launchInputJson = "";
  executingLaunch = false;
  launchError = "";

  // Send Signal Action State
  signalModalOpen = false;
  signalName = "";
  signalPayload = "";

  // Pagination & Filters State
  selectedWorkflow = "";
  selectedStatus = "";
  selectedFailureCategory = "";
  limitSize = 50;
  offsetSize = 0;

  // Attribute Filters
  attributeFilters = {};
  newAttrKey = "";
  newAttrValue = "";
  hasMore = true;
  loadingMore = false;
  cacheBuster = "";
  redriving = false;

  // Stalled-instance filter
  showingStalled = false;
  stalledCountData = { count: 0, capped: false };

  // Per-definition health trends (success rate & throughput over a window)
  trendWindow = "24h";
  trendRows = [];
  loadingTrends = false;
  // Incremented on every fetchTrends() call; the .then() callback checks its
  // captured snapshot against the current value and discards stale responses.
  _trendRequestId = 0;
  _instanceRequestId = 0;
  _isConnected = false;
  _restoreScroll = false;
  _pendingScrollTop = 0;
  // Stable option array (see note above workflowOptions on why getters are avoided).
  trendWindowOptions = ROLLING_WINDOW_OPTIONS;

  // Fleet Health view state (#111): read-only, one row per definition.
  viewingHealth = false;
  loadingHealth = false;
  healthWindow = "24h";
  healthThreshold = 95;
  healthData = null;
  healthRows = [];
  healthError = "";
  // Only the latest request updates the view. The component discards a stale response.
  _healthRequestId = 0;
  healthWindowOptions = ROLLING_WINDOW_OPTIONS;

  // Catalog view state (read-only deployed-workflow catalog with live health)
  viewingCatalog = false;
  loadingCatalog = false;
  catalogRows = [];

  // Failure Breakdown view state
  viewingFailureBreakdown = false;
  loadingFailureBreakdown = false;
  breakdownWorkflow = "";
  breakdownTimeWindow = "24h";
  breakdownData = null;
  breakdownTimeWindowOptions = [
    { label: "Last 1 hour", value: "1h" },
    { label: "Last 24 hours", value: "24h" },
    { label: "Last 7 days", value: "7d" },
    { label: "All Time", value: "all" },
  ];

  // Latency view state (end-to-end percentiles + slowest-step ranking, wall-clock)
  viewingLatency = false;
  loadingLatency = false;
  latencyWorkflow = "";
  latencyTimeWindow = "24h";
  latencyData = null;
  // Monotonic request counter: latest-request-wins guard so a slow, stale
  // latency response cannot overwrite a newer selection's data/spinner.
  _latencyRequestSeq = 0;
  latencyTimeWindowOptions = [
    { label: "Last 1 hour", value: "1h" },
    { label: "Last 24 hours", value: "24h" },
    { label: "Last 7 days", value: "7d" },
    { label: "All Time", value: "all" },
  ];

  // Confirmation modals
  redriveModalOpen = false;
  redriveCount = 0;
  cancelModalOpen = false;
  compensateModalOpen = false;
  redriveSnapshotName;
  redriveSnapshotStatus;
  redriveSnapshotSearchTerm;
  cancelMatchingModalOpen = false;
  cancellingMatching = false;
  cancelMatchingCount = 0;
  cancelSnapshotName;
  cancelSnapshotStatus;
  cancelSnapshotSearchTerm;

  wiredDefinitionsResult;
  pollingInterval;
  autoRefreshInterval;
  searchTimeout;

  // Stable option arrays — only rebuilt when source data changes, not on every render.
  // Getter forms would return a new array reference every render cycle, which causes
  // lightning-combobox to re-initialize (closing the dropdown and resetting its scroll).
  workflowOptions = [{ label: "-- All Definitions --", value: "" }];
  definitionOptions = [];
  statusOptions = [
    { label: "-- All Statuses --", value: "" },
    { label: "Running", value: "Running" },
    { label: "Pending", value: "Pending" },
    { label: "Suspended", value: "Suspended" },
    { label: "Retrying", value: "Retrying" },
    { label: "Compensating", value: "Compensating" },
    { label: "Compensated", value: "Compensated" },
    { label: "Rollback Incomplete", value: "CompensationFailed" },
    { label: "Completed", value: "Completed" },
    { label: "Failed", value: "Failed" },
    { label: "Cancelling", value: "Cancelling" },
    { label: "Cancelled", value: "Cancelled" },
    { label: "ContinuedAsNew", value: "ContinuedAsNew" },
    { label: "Paused", value: "Paused" },
    { label: "Definition Changed", value: "DefinitionChanged" },
    { label: "Held", value: "Held" },
  ];

  failureCategoryOptions = [
    { label: "-- All Categories --", value: "" },
    { label: "Step Exception", value: "STEP_EXCEPTION" },
    { label: "Retries Exhausted", value: "RETRIES_EXHAUSTED" },
    { label: "Timeout", value: "TIMEOUT" },
    { label: "Compensation Failed", value: "COMPENSATION_FAILED" },
    { label: "Explicit Step Failure", value: "EXPLICIT_FAIL" },
    { label: "Step Non-Determinism", value: "STEP_NON_DETERMINISM" },
    { label: "Step History Limit", value: "STEP_HISTORY_LIMIT" },
    { label: "Unknown", value: "UNKNOWN" },
  ];

  connectedCallback() {
    this._isConnected = true;
    this.fetchInstances(false);
    this.startAutoRefresh();
  }

  disconnectedCallback() {
    this._isConnected = false;
    this.stopPolling(false);
    this.stopAutoRefresh();
    if (this.searchTimeout) {
      clearTimeout(this.searchTimeout);
    }
  }

  renderedCallback() {
    this.restoreChainScroll();
    if (!this._restoreScroll) {
      return;
    }
    this._restoreScroll = false;
    const el = this.template.querySelector(".slds-scrollable_y");
    if (el) {
      el.scrollTop = this._pendingScrollTop;
    }
  }

  restoreChainScroll() {
    if (this._pendingChainScrollTop === null) {
      return;
    }
    const list = this.template.querySelector('[data-id="chain-scroll"]');
    if (list) {
      list.scrollTop = this._pendingChainScrollTop;
      this._pendingChainScrollTop = null;
    }
  }

  @wire(getDefinitions)
  wiredDefinitions(result) {
    this.wiredDefinitionsResult = result;
    if (result.data) {
      this.definitions = result.data;
      this.workflowOptions = [
        { label: "-- All Definitions --", value: "" },
        ...result.data.map((def) => ({ label: def, value: def })),
      ];
      this.definitionOptions = result.data.map((def) => ({
        label: def,
        value: def,
      }));
    }
  }

  get hasFilteredInstances() {
    return this.filteredInstances.length > 0;
  }

  get hasSteps() {
    return this.steps.length > 0;
  }

  get hasChildren() {
    return this.childInstances && this.childInstances.length > 0;
  }

  // Generation rows with the selected-row class. shapeGeneration formats
  // each row once, when it arrives.
  get chainRows() {
    return this.chainGenerations.map((g) => {
      const selected = g.instanceId === this.selectedInstanceId;
      return {
        ...g,
        rowClass: `slds-p-around_small list-item chain-row ${
          selected ? "item-selected" : ""
        }`,
        ariaCurrent: selected ? "true" : null,
      };
    });
  }

  get hasChainRows() {
    return this.chainGenerations.length > 0;
  }

  get showChainSpinner() {
    return this.chainLoading && !this.hasChainRows;
  }

  get chainCountLabel() {
    const total = `${this.chainTotal}${this.chainTotalCapped ? "+" : ""}`;
    return `Showing ${this.chainGenerations.length} of ${total} generations`;
  }

  get hasOlderGenerations() {
    return !!this.chainNextCursor;
  }

  shapeGeneration(g) {
    return {
      ...g,
      generationLabel: `Generation ${g.generation ?? "—"}`,
      formattedStartedAt: this.formatDateTime(g.startedAt),
      formattedEndedAt: this.formatDateTime(g.endedAt),
      statusBadgeClass: this.getStatusBadgeClass(g.status),
      failureCategoryLabel: g.failureCategory
        ? FAILURE_CATEGORY_LABELS[g.failureCategory] || g.failureCategory
        : null,
    };
  }

  // Loads the chain only for an instance with a predecessor or a successor.
  // - Same chain (row in the list, or same anchor): refresh page 1 on each
  //   load, so a poll shows new generations. Older pages stay. After an error,
  //   only "Try again" reads again.
  // - Other instance: load its chain and clear the old rows.
  syncChain(instanceId, inst, successor) {
    if (!inst.Previous_Instance__c && !successor) {
      this.resetChain();
      return;
    }
    const sameChain =
      instanceId === this.chainAnchorId ||
      this.chainGenerations.some((g) => g.instanceId === instanceId);
    if (!sameChain) {
      this.loadChain(instanceId, null, true);
    } else if (!this.chainError && !this.chainLoading) {
      this.loadChain(this.chainAnchorId, null, false);
    }
  }

  resetChain() {
    this.chainRequestSeq++;
    this.chainActive = false;
    this.chainLoading = false;
    this.chainError = null;
    this.chainGenerations = [];
    this.chainTotal = 0;
    this.chainTotalCapped = false;
    this.chainNextCursor = null;
    this.chainAnchorId = null;
  }

  // clear: remove the old rows first (a different chain).
  loadChain(instanceId, cursor, clear) {
    const seq = ++this.chainRequestSeq;
    if (!cursor) {
      this.chainAnchorId = instanceId;
    }
    if (clear) {
      this.chainGenerations = [];
      this.chainTotal = 0;
      this.chainTotalCapped = false;
      this.chainNextCursor = null;
    }
    this.chainActive = true;
    this.chainLoading = true;
    this.chainError = null;
    getInstanceChain({ instanceId, cursor })
      .then((page) => {
        if (seq !== this.chainRequestSeq) {
          return;
        }
        if (!page) {
          this.resetChain();
          return;
        }
        const rows = (page.generations || []).map((g) =>
          this.shapeGeneration(g),
        );
        const pageCursor = page.hasMore ? page.nextCursor : null;
        if (cursor) {
          this.chainGenerations = [...this.chainGenerations, ...rows];
          this.chainNextCursor = pageCursor;
        } else {
          // A refresh of page 1 keeps the loaded older rows only when the lists
          // join exactly. Page 1 must contain a cached row. Then each row of
          // page 1 that is not cached is a new generation, so with no purge
          // the new total is the old total plus those rows. Else (a purge, or
          // a capped total) paging starts again from page 1.
          const pageIds = new Set(rows.map((g) => g.instanceId));
          const older = this.chainGenerations.filter(
            (g) => !pageIds.has(g.instanceId),
          );
          const cachedOnPage = this.chainGenerations.length - older.length;
          const added = rows.length - cachedOnPage;
          const exact =
            cachedOnPage > 0 &&
            !page.isTotalCapped &&
            !this.chainTotalCapped &&
            page.totalCount === this.chainTotal + added;
          const keep = exact ? older : [];
          this.chainGenerations = [...rows, ...keep];
          this.chainNextCursor = keep.length
            ? this.chainNextCursor
            : pageCursor;
        }
        this.chainTotal = page.totalCount;
        this.chainTotalCapped = !!page.isTotalCapped;
      })
      .catch((error) => {
        if (seq === this.chainRequestSeq) {
          this.chainError = this.reduceErrors(error);
        }
      })
      .finally(() => {
        if (seq === this.chainRequestSeq) {
          this.chainLoading = false;
        }
      });
  }

  handleLoadOlderGenerations() {
    if (this.chainNextCursor && !this.chainLoading) {
      this.loadChain(this.chainAnchorId, this.chainNextCursor, false);
    }
  }

  handleRetryChain() {
    if (this.chainAnchorId && !this.chainLoading) {
      this.loadChain(this.chainAnchorId, null, true);
    }
  }

  // Opens the step timeline of a generation. The detail spinner rebuilds the
  // list, so keep its scroll position.
  handleSelectGeneration(event) {
    const list = this.template.querySelector('[data-id="chain-scroll"]');
    this._pendingChainScrollTop = list ? list.scrollTop : null;
    this.handleSelectRelatedInstance(event);
  }

  get hasBreakdownRows() {
    return (
      this.breakdownData &&
      this.breakdownData.steps &&
      this.breakdownData.steps.length > 0
    );
  }

  get hasCatalogRows() {
    return this.catalogRows && this.catalogRows.length > 0;
  }

  get breakdownRows() {
    if (!this.breakdownData || !this.breakdownData.steps) {
      return [];
    }
    return this.breakdownData.steps.map((step) => ({
      ...step,
      stepAccordionLabel: `${step.stepName} (${step.failureCount} failure${step.failureCount === 1 ? "" : "s"})`,
    }));
  }

  get breakdownIsCapped() {
    return this.breakdownData ? this.breakdownData.isCapped : false;
  }

  // Formats a wall-clock duration in milliseconds into a compact human-readable string
  // (e.g. "1h 2m", "3m 4s", "500ms"). Returns an em dash for null/undefined.
  formatDuration(ms) {
    if (ms === null || ms === undefined) {
      return "—";
    }
    if (ms < 1000) {
      return `${ms}ms`;
    }
    const totalSeconds = Math.floor(ms / 1000);
    const hours = Math.floor(totalSeconds / 3600);
    const minutes = Math.floor((totalSeconds % 3600) / 60);
    const seconds = totalSeconds % 60;
    if (hours > 0) {
      return `${hours}h ${minutes}m`;
    }
    if (minutes > 0) {
      return `${minutes}m ${seconds}s`;
    }
    return `${seconds}s`;
  }

  get hasLatencyData() {
    return !!(this.latencyData && this.latencyData.sampleSize > 0);
  }

  get latencyIsCapped() {
    return this.latencyData ? this.latencyData.isCapped : false;
  }

  get latencySampleSize() {
    return this.latencyData ? this.latencyData.sampleSize : 0;
  }

  // Formatted p50/p95/p99/max tiles for the percentile row.
  get latencyPercentiles() {
    const d = this.latencyData;
    return [
      { key: "p50", label: "p50", value: this.formatDuration(d && d.p50Ms) },
      { key: "p95", label: "p95", value: this.formatDuration(d && d.p95Ms) },
      { key: "p99", label: "p99", value: this.formatDuration(d && d.p99Ms) },
      { key: "max", label: "Max", value: this.formatDuration(d && d.maxMs) },
    ];
  }

  get hasLatencySteps() {
    return !!(
      this.latencyData &&
      this.latencyData.steps &&
      this.latencyData.steps.length > 0
    );
  }

  // Slowest-first step ranking rows with the median wall-clock pre-formatted for display.
  get latencyStepRows() {
    if (!this.latencyData || !this.latencyData.steps) {
      return [];
    }
    return this.latencyData.steps.map((step) => ({
      stepName: step.stepName,
      sampleCount: step.sampleCount,
      medianDisplay: this.formatDuration(step.medianMs),
    }));
  }

  get isFailed() {
    return this.selectedInst && this.selectedInst.Status__c === "Failed";
  }

  get isRollbackIncomplete() {
    return (
      this.selectedInst && this.selectedInst.Status__c === "CompensationFailed"
    );
  }

  // Issue #89: parked because the definition step list changed in flight.
  get isDefinitionChanged() {
    return (
      this.selectedInst && this.selectedInst.Status__c === "DefinitionChanged"
    );
  }

  // Issue #119: a hold is recorded, or the gate parked the instance.
  get isHeld() {
    return (
      !!this.selectedInst &&
      (this.selectedInst.Held__c === true ||
        this.selectedInst.Status__c === "Held")
    );
  }

  // The hold waits for the next step boundary.
  get isHoldWaiting() {
    return this.isHeld && this.selectedInst.Status__c !== "Held";
  }

  get holdReasonLabel() {
    return (this.selectedInst && this.selectedInst.Hold_Reason__c) || "None";
  }

  // A hold on a Paused or DefinitionChanged instance does not end that park.
  get isHeldWithOtherPark() {
    return (
      this.isHeld &&
      (this.selectedInst.Status__c === "Paused" ||
        this.selectedInst.Status__c === "DefinitionChanged")
    );
  }

  // The engine decides: forward path only, no rollback, no engine workflow.
  get canHold() {
    return !!this.selectedInst && !this.isHeld && this.selectedInst.holdable;
  }

  get definitionChange() {
    return this.selectedInst ? this.selectedInst.definitionChange : null;
  }

  // A park reason is not a failure, so the panel above shows it instead.
  get showFailureMessage() {
    return (
      !!this.selectedInst &&
      !!this.selectedInst.Error_Message__c &&
      !this.isDefinitionChanged
    );
  }

  // Release is safe only when every current step is still in the live list.
  get isReleaseDisabled() {
    const change = this.definitionChange;
    return !change || !change.liveAvailable || !change.currentStepInLive;
  }

  get pendingCompensationCount() {
    return this.selectedInst ? this.selectedInst.pendingCompensationCount : 0;
  }

  get pendingCompensations() {
    const names =
      this.selectedInst && this.selectedInst.pendingCompensations
        ? this.selectedInst.pendingCompensations
        : [];
    // The compensation stack can legitimately contain the same step name more
    // than once (a workflow that loops or reuses a compensatable step class), so
    // the step name alone is not a unique list key. Pair it with the stack index
    // to give LWC a stable, unique key per entry and keep list diffing correct.
    return names.map((name, index) => ({
      key: `${index}_${name}`,
      name,
    }));
  }

  get isCompensatable() {
    if (!this.selectedInst) return false;
    const status = this.selectedInst.Status__c;
    return status === "Completed" && this.pendingCompensationCount > 0;
  }

  get isCancelable() {
    if (!this.selectedInst) return false;
    const status = this.selectedInst.Status__c;
    // CompensationFailed is included so operators can force-cancel a stalled rollback:
    // the cancel dialog's "without compensations" choice drives it terminal and releases
    // its key when the remaining compensation keeps failing.
    return (
      status === "Pending" ||
      status === "Running" ||
      status === "Suspended" ||
      status === "Paused" ||
      status === "DefinitionChanged" ||
      status === "Held" ||
      status === "CompensationFailed"
    );
  }

  get isSuspended() {
    return this.selectedInst && this.selectedInst.Status__c === "Suspended";
  }

  get isSendSignalDisabled() {
    return !this.signalName || !this.signalName.trim() || this.loadingDetails;
  }

  // Builds the shared stats/count promises and settles them alongside the
  // caller-supplied instances query. Used by both fetchInstances and
  // refreshInstances so the query construction lives in one place.
  _loadStatsAndCounts(instancesPromise) {
    const statsPromise = getWorkflowStats({
      criteria: {
        workflowName: this.selectedWorkflow,
        status: this.selectedStatus,
        searchTerm: this.searchTerm,
        attributesFilterJson: this.attributesFilterJson,
      },
    });

    const stalledCountPromise = getStalledCount({
      criteria: {
        workflowName: this.selectedWorkflow,
        searchTerm: this.searchTerm,
        thresholdMinutes: null,
        attributesFilterJson: this.attributesFilterJson,
      },
    }).catch((error) => {
      console.error("Stalled count query failed:", error);
      return { count: 0, capped: false };
    });

    const unroutedCountPromise = getUnroutedSignalCount({
      searchTerm: null,
    }).catch((error) => {
      console.error("Unrouted signal count query failed:", error);
      return { count: 0, capped: false };
    });

    return Promise.all([
      instancesPromise,
      statsPromise,
      stalledCountPromise,
      unroutedCountPromise,
    ]);
  }

  fetchInstances(isAppend, targetOffset) {
    const requestId = ++this._instanceRequestId;
    if (!isAppend) {
      this.offsetSize = 0;
      this.hasMore = true;
      this.loadingMore = false;
      this.cacheBuster = Date.now().toString();
    }

    const currentOffset = isAppend ? targetOffset || this.offsetSize : 0;
    const currentLimit = this.limitSize;

    if (isAppend) {
      this.loadingMore = true;
    } else {
      this.loadingDetails = true;
    }

    const instancesPromise = this.showingStalled
      ? getStalledInstances({
          criteria: {
            workflowName: this.selectedWorkflow,
            searchTerm: this.searchTerm,
            thresholdMinutes: null,
            limitSize: currentLimit,
            offsetSize: currentOffset,
            cacheBuster: this.cacheBuster,
            attributesFilterJson: this.attributesFilterJson,
          },
        })
      : getFilteredInstances({
          criteria: {
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm,
            failureCategory: this.selectedFailureCategory,
            limitSize: currentLimit,
            offsetSize: currentOffset,
            cacheBuster: this.cacheBuster,
            attributesFilterJson: this.attributesFilterJson,
          },
        });

    if (isAppend) {
      return instancesPromise
        .then((result) => {
          if (!this._isConnected || requestId !== this._instanceRequestId)
            return;
          const formatted = result.map((inst) => this.formatInstance(inst));
          this.instances = [...this.instances, ...formatted];

          this.offsetSize = currentOffset;

          // Guard against SOQL 2000 offset limit
          if (
            result.length < currentLimit ||
            this.offsetSize + result.length >= 2000
          ) {
            this.hasMore = false;
          } else {
            this.hasMore = true;
          }

          this.filterInstancesList();
        })
        .catch((error) => {
          if (!this._isConnected || requestId !== this._instanceRequestId)
            return;
          this.showToast(
            "Error",
            "Failed to retrieve workflow instances: " +
              this.reduceErrors(error),
            "error",
          );
        })
        .finally(() => {
          if (this._isConnected && requestId === this._instanceRequestId) {
            this.loadingMore = false;
            this.loadingDetails = false;
          }
        });
    }

    return this._loadStatsAndCounts(instancesPromise)
      .then(([result, statsResult, stalledResult, unroutedResult]) => {
        if (!this._isConnected || requestId !== this._instanceRequestId) return;
        const formatted = result.map((inst) => this.formatInstance(inst));
        this.instances = formatted;

        // Guard against SOQL 2000 offset limit
        if (
          result.length < currentLimit ||
          this.offsetSize + result.length >= 2000
        ) {
          this.hasMore = false;
        } else {
          this.hasMore = true;
        }

        this.stats = statsResult;
        this.stalledCountData = stalledResult || { count: 0, capped: false };
        this.unroutedCountData = unroutedResult || { count: 0, capped: false };
        this.filterInstancesList();

        // Auto-refresh detail view if selected instance is currently loaded
        if (this.selectedInstanceId) {
          this.loadDetails(false);
        }
      })
      .catch((error) => {
        if (!this._isConnected || requestId !== this._instanceRequestId) return;
        this.showToast(
          "Error",
          "Failed to retrieve workflow instances: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        if (this._isConnected && requestId === this._instanceRequestId) {
          this.loadingMore = false;
          this.loadingDetails = false;
        }
      });
  }

  refreshInstances() {
    const requestId = ++this._instanceRequestId;
    const currentSize =
      this.instances.length > 0 ? this.instances.length : this.limitSize;
    this.cacheBuster = Date.now().toString();

    const listEl = this.template.querySelector(".slds-scrollable_y");
    const savedScrollTop = listEl ? listEl.scrollTop : 0;

    const instancesPromise = this.showingStalled
      ? getStalledInstances({
          criteria: {
            workflowName: this.selectedWorkflow,
            searchTerm: this.searchTerm,
            thresholdMinutes: null,
            limitSize: currentSize,
            offsetSize: 0,
            cacheBuster: this.cacheBuster,
            attributesFilterJson: this.attributesFilterJson,
          },
        })
      : getFilteredInstances({
          criteria: {
            workflowName: this.selectedWorkflow,
            status: this.selectedStatus,
            searchTerm: this.searchTerm,
            failureCategory: this.selectedFailureCategory,
            limitSize: currentSize,
            offsetSize: 0,
            cacheBuster: this.cacheBuster,
            attributesFilterJson: this.attributesFilterJson,
          },
        });

    return this._loadStatsAndCounts(instancesPromise)
      .then(([result, statsResult, stalledResult, unroutedResult]) => {
        if (!this._isConnected || requestId !== this._instanceRequestId) return;
        this.instances = result.map((inst) => this.formatInstance(inst));
        this.stats = statsResult;
        this.stalledCountData = stalledResult || { count: 0, capped: false };
        this.unroutedCountData = unroutedResult || { count: 0, capped: false };
        this.filterInstancesList();

        if (this.selectedInstanceId) {
          this.loadDetails(false);
        }

        // Restore scroll position after LWC reconciles the list DOM
        this._pendingScrollTop = savedScrollTop;
        this._restoreScroll = true;
      })
      .catch((error) => {
        if (!this._isConnected || requestId !== this._instanceRequestId) return;
        console.error("Error refreshing instances:", this.reduceErrors(error));
      });
  }

  handleSearchChange(event) {
    this.searchTerm = event.target.value;
    if (this.searchTimeout) {
      clearTimeout(this.searchTimeout);
    }
    this.searchTimeout = setTimeout(() => {
      this.fetchInstances(false);
    }, 300);
  }

  handleWorkflowFilterChange(event) {
    this.selectedWorkflow = event.detail
      ? event.detail.value
      : event.target.value;
    this.fetchInstances(false);
  }

  handleStatusFilterChange(event) {
    this.selectedStatus = event.target.value;
    this.selectedFailureCategory = "";
    this.fetchInstances(false);
  }

  handleFailureCategoryFilterChange(event) {
    this.selectedFailureCategory = event.target.value;
    this.fetchInstances(false);
  }

  get showFailureCategoryFilter() {
    return (
      !this.selectedStatus ||
      this.selectedStatus === "Failed" ||
      this.selectedStatus === "CompensationFailed"
    );
  }

  handleToggleStalledFilter() {
    this.showingStalled = !this.showingStalled;
    this.offsetSize = 0;
    this.instances = [];
    this.fetchInstances(false);
  }

  handleNewAttrKeyChange(event) {
    this.newAttrKey = event.target.value;
    event.target.setCustomValidity("");
    event.target.reportValidity();
  }

  handleNewAttrValueChange(event) {
    this.newAttrValue = event.target.value;
    event.target.setCustomValidity("");
    event.target.reportValidity();
  }

  handleAddAttribute() {
    const keyInput = this.template.querySelector('[data-id="attr-key-input"]');
    const valueInput = this.template.querySelector(
      '[data-id="attr-val-input"]',
    );

    const key = this.newAttrKey ? this.newAttrKey.trim() : "";
    const value = this.newAttrValue ? this.newAttrValue.trim() : "";

    let isValid = true;

    if (!key) {
      keyInput.setCustomValidity("Please enter an attribute key.");
      keyInput.reportValidity();
      isValid = false;
    } else {
      keyInput.setCustomValidity("");
      keyInput.reportValidity();
    }

    if (!value) {
      valueInput.setCustomValidity("Please enter an attribute value.");
      valueInput.reportValidity();
      isValid = false;
    } else {
      valueInput.setCustomValidity("");
      valueInput.reportValidity();
    }

    if (isValid) {
      if (Object.keys(this.attributeFilters).length >= 2) {
        this.showToast(
          "Warning",
          "A maximum of 2 active attribute filters is allowed to ensure query performance.",
          "warning",
        );
        return;
      }
      this.attributeFilters = {
        ...this.attributeFilters,
        [key]: value,
      };
      this.newAttrKey = "";
      this.newAttrValue = "";
      this.fetchInstances(false);
    }
  }

  handleRemoveAttribute(event) {
    const key = event.currentTarget.dataset.id;
    if (key) {
      const filters = { ...this.attributeFilters };
      delete filters[key];
      this.attributeFilters = filters;
      this.fetchInstances(false);
    }
  }

  get hasAttributes() {
    return Object.keys(this.attributeFilters).length > 0;
  }

  get attributeFiltersList() {
    return Object.entries(this.attributeFilters).map(([key, val]) => {
      return {
        id: key,
        display: `${key}=${val}`,
        removeAriaLabel: `Remove filter for ${key} equals ${val}`,
      };
    });
  }

  get attributesFilterJson() {
    return this.hasAttributes ? JSON.stringify(this.attributeFilters) : "";
  }

  get stalledCountDisplay() {
    if (!this.stalledCountData) return "0";
    const count = this.stalledCountData.count || 0;
    return this.stalledCountData.capped ? `${count}+` : String(count);
  }

  get stalledFilterLabel() {
    return this.showingStalled ? "Show All" : "Stalled";
  }

  get stalledFilterVariant() {
    return this.showingStalled ? "brand" : "neutral";
  }

  // Pluralizes "instance(s)" in the re-drive confirmation copy. A getter is used
  // because LWC templates do not support inline conditional expressions.
  get redrivePluralSuffix() {
    return this.redriveCount === 1 ? "" : "s";
  }

  get cancelPluralSuffix() {
    return this.cancelMatchingCount === 1 ? "" : "s";
  }

  // ────────────────────────────────────────────────────────────────────────
  // DEFINITION HEALTH TRENDS
  // ────────────────────────────────────────────────────────────────────────

  fetchTrends() {
    this.loadingTrends = true;
    const requestId = ++this._trendRequestId;
    return getDefinitionTrends({ windowKey: this.trendWindow })
      .then((result) => {
        if (requestId !== this._trendRequestId) return;
        const rows = (result && result.rows) || [];
        this.trendRows = rows.map((row) => ({
          ...row,
          successRateDisplay:
            row.successRate == null ? "—" : `${row.successRate}%`,
          successRateClass:
            row.successRate != null && row.successRate < 90
              ? "text-red"
              : "text-green",
          failureCountClass: row.failureCount > 0 ? "text-red" : "",
          throughputDisplay:
            row.throughputPerHour == null
              ? `${row.terminalCount}`
              : `${row.terminalCount} (${row.throughputPerHour}/hr)`,
        }));
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to load definition trends: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        if (requestId === this._trendRequestId) {
          this.loadingTrends = false;
        }
      });
  }

  handleTrendWindowChange(event) {
    this.trendWindow = event.detail ? event.detail.value : event.target.value;
    this.fetchTrends();
  }

  get hasTrendRows() {
    return this.trendRows.length > 0;
  }

  // Only show the spinner on initial load (when no rows are cached yet).
  // Subsequent background refreshes update rows in-place without flicker.

  formatInstance(inst) {
    const idleLabel =
      inst.idleMinutes != null ? `${inst.idleMinutes}m idle` : null;
    const waitDescriptor = inst.waitDescriptor || null;
    return {
      ...inst,
      formattedDate: this.formatDateTime(inst.CreatedDate),
      formattedDeadline: inst.Deadline_At__c
        ? this.formatDateTime(inst.Deadline_At__c)
        : null,
      listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? "item-selected" : ""}`,
      statusBadgeClass: this.getStatusBadgeClass(inst.Status__c),
      hasWaitDescriptor: !!waitDescriptor,
      waitDescriptorLabel: waitDescriptor ? waitDescriptor.label : null,
      awaitedSignalName: waitDescriptor ? waitDescriptor.signalName : null,
      isWatchdogWaiting: inst.waitingOn === "Watchdog",
      waitingOnBadgeClass:
        inst.waitingOn === "Watchdog"
          ? "badge badge-purple"
          : inst.waitingOn === "Delayed Queueable"
            ? "badge badge-indigo"
            : "badge badge-blue",
      stalledBadgeClass: inst.stalled ? "badge badge-red" : null,
      formattedIdleMinutes: idleLabel,
      // Issue #119: the hold waits for the next step boundary.
      isHoldWaiting: inst.Held__c === true && inst.Status__c !== "Held",
    };
  }

  filterInstancesList() {
    this.filteredInstances = this.instances.map((inst) => ({
      ...inst,
      listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? "item-selected" : ""}`,
    }));
  }

  handleScroll(event) {
    const container = event.target;
    const threshold = 20;
    const isNearBottom =
      container.scrollHeight - container.scrollTop - container.clientHeight <=
      threshold;

    if (isNearBottom && !this.loadingMore && this.hasMore) {
      this.loadMoreInstances();
    }
  }

  loadMoreInstances() {
    if (this.loadingMore || !this.hasMore) {
      return;
    }
    const targetOffset = this.offsetSize + this.limitSize;
    this.fetchInstances(true, targetOffset);
  }

  handleSelectInstance(event) {
    this.stopPolling();
    this.closeViews();
    this.selectedInstanceId = event.currentTarget.dataset.id;
    this.filterInstancesList();
    this.loadDetails(true);
  }

  // Closes every view so that the instance detail panel shows.
  closeViews() {
    this.viewingDoctor = false;
    this.viewingSchedules = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingCatalog = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.handleCloseHealth();
  }

  handleSelectRelatedInstance(event) {
    this.stopPolling();
    this.closeViews();
    this.selectedInstanceId = event.currentTarget.dataset.id;
    this.filterInstancesList();
    this.loadDetails(true);
  }

  loadDetails(showSpinner) {
    if (showSpinner) {
      this.loadingDetails = true;
    }
    const currentInstanceId = this.selectedInstanceId;
    if (showSpinner) {
      this.successor = null;
    }
    getInstanceDetails({ instanceId: currentInstanceId })
      .then((result) => {
        if (currentInstanceId !== this.selectedInstanceId) {
          return;
        }
        if (!result || !result.instance) {
          this.selectedInst = {};
          this.steps = [];
          this.childInstances = [];
          this.resetChain();
          return;
        }
        const inst = result.instance;
        const payloadFiles = result.payloadFiles || {};
        const breadcrumbs = result.breadcrumbs || [];
        this.successor = result.successor;
        this.syncChain(currentInstanceId, inst, result.successor);
        this.selectedInst = {
          ...inst,
          formattedDate: this.formatDateTime(inst.CreatedDate),
          formattedDeadline: inst.Deadline_At__c
            ? this.formatDateTime(inst.Deadline_At__c)
            : null,
          statusBadgeClass: this.getStatusBadgeClass(inst.Status__c),
          failureCategoryLabel:
            FAILURE_CATEGORY_LABELS[inst.Failure_Category__c] ||
            inst.Failure_Category__c,
          Input__c: this.formatJson(inst.Input__c),
          Output__c: this.formatJson(inst.Output__c),
          Progress__c: this.formatJson(inst.Progress__c),
          inputFile: this.buildPayloadFile(payloadFiles["instance.Input"]),
          outputFile: this.buildPayloadFile(payloadFiles["instance.Output"]),
          progressFile: this.buildPayloadFile(
            payloadFiles["instance.Progress"],
          ),
          waitingOn: result.waitingOn,
          hasWaitDescriptor: !!result.waitDescriptor,
          waitDescriptorLabel: result.waitDescriptor
            ? result.waitDescriptor.label
            : null,
          awaitedSignalName: result.waitDescriptor
            ? result.waitDescriptor.signalName
            : null,
          isWatchdogWaiting: result.waitingOn === "Watchdog",
          waitingOnBadgeClass:
            result.waitingOn === "Watchdog"
              ? "badge badge-purple"
              : result.waitingOn === "Delayed Queueable"
                ? "badge badge-indigo"
                : "badge badge-blue",
          pendingCompensationCount: result.pendingCompensationCount || 0,
          pendingCompensations: result.pendingCompensations || [],
          attributes: result.attributes || [],
          definitionChange: this.mapDefinitionChange(result.definitionChange),
          heldSinceFormatted: this.formatDateTime(inst.Held_At__c),
          holdable: result.holdable === true,
          // Issue #112: { message, createdDate, formattedDate } or null.
          stepHistoryWarning: result.stepHistoryWarning
            ? {
                ...result.stepHistoryWarning,
                formattedDate: this.formatDateTime(
                  result.stepHistoryWarning.createdDate,
                ),
              }
            : null,
        };

        // Map children
        this.childInstances = (result.children || []).map((child) => {
          return {
            ...child,
            formattedDate: this.formatDateTime(child.CreatedDate),
            statusBadgeClass: this.getStatusBadgeClass(child.Status__c),
          };
        });

        // Preserve showDetails toggle state if steps were already loaded
        const showDetailsMap = new Map();
        this.steps.forEach((s) => showDetailsMap.set(s.Id, s.showDetails));

        const breadcrumbsByStep = {};
        for (const b of breadcrumbs) {
          const key = b.Correlation_Key__c;
          if (!breadcrumbsByStep[key]) {
            breadcrumbsByStep[key] = [];
          }
          breadcrumbsByStep[key].push(b);
        }

        this.steps = result.steps.map((step) => {
          let approvalInfo = null;
          let childWorkflowLink = null;
          if (step.Output__c) {
            try {
              const parsed = JSON.parse(step.Output__c);
              if (parsed.waitingForApproval) {
                approvalInfo = {
                  key: parsed.approvalKey,
                  role: parsed.approvalRole,
                };
              }
              if (parsed.childWorkflowName && parsed.childCorrelationKey) {
                const matchingChild = this.childInstances.find(
                  (child) =>
                    child.Correlation_Key__c === parsed.childCorrelationKey &&
                    child.Workflow_Name__c === parsed.childWorkflowName,
                );
                if (matchingChild) {
                  childWorkflowLink = {
                    id: matchingChild.Id,
                    name: matchingChild.Name,
                  };
                }
              }
            } catch {
              // ignore non-json
            }
          }

          const cpu = step.CPU_Time_Ms__c;
          const soql = step.SOQL_Query_Count__c;
          const heap = step.Heap_Size_Bytes__c;

          const hasTelemetry = cpu !== undefined && cpu !== null;
          let telemetryString = "—";
          let hasLimitPressure = false;

          if (hasTelemetry) {
            const cpuVal = cpu ?? 0;
            const soqlVal = soql ?? 0;
            const heapVal = heap ?? 0;

            const cpuPct = Math.round((cpuVal / ASYNC_LIMITS.CPU) * 100);
            const soqlPct = Math.round((soqlVal / ASYNC_LIMITS.SOQL) * 100);
            const heapPct = Math.round((heapVal / ASYNC_LIMITS.HEAP) * 100);

            telemetryString = `CPU: ${cpuVal} ms (${cpuPct}%) | SOQL: ${soqlVal}/${ASYNC_LIMITS.SOQL} (${soqlPct}%) | Heap: ${(heapVal / 1024 / 1024).toFixed(2)} MB (${heapPct}%)`;
            hasLimitPressure = cpuPct >= 80 || soqlPct >= 80 || heapPct >= 80;
          }

          const stepBreadcrumbs = (breadcrumbsByStep[step.Id] || []).map(
            (b) => {
              let badgeClass = "terminal-badge";
              const lvl = (b.Level__c || "").toUpperCase();
              if (lvl === "WARN") {
                badgeClass += " terminal-badge-warn";
              } else if (lvl === "ERROR") {
                badgeClass += " terminal-badge-error";
              } else {
                badgeClass += " terminal-badge-info";
              }
              return {
                ...b,
                formattedFireTime: b.Fire_Time__c
                  ? this.formatDateTime(b.Fire_Time__c)
                  : this.formatDateTime(b.CreatedDate),
                badgeClass,
              };
            },
          );

          return {
            ...step,
            formattedDate: this.formatDateTime(step.CreatedDate),
            statusBadgeClass: approvalInfo
              ? "badge badge-orange pulse-glow"
              : this.getStatusBadgeClass(step.Status__c),
            markerClass: approvalInfo
              ? "timeline-marker bg-yellow pulse-glow"
              : this.getTimelineMarkerClass(step.Status__c),
            showDetails:
              showDetailsMap.get(step.Id) || (approvalInfo ? true : false),
            isWaitingForApproval: !!approvalInfo,
            approvalKey: approvalInfo ? approvalInfo.key : null,
            approvalRole: approvalInfo ? approvalInfo.role : null,
            childInstanceId: childWorkflowLink ? childWorkflowLink.id : null,
            childInstanceName: childWorkflowLink
              ? childWorkflowLink.name
              : null,
            Input__c: this.formatJson(step.Input__c),
            Output__c: this.formatJson(step.Output__c),
            inputFile: this.buildPayloadFile(
              payloadFiles["step." + step.Id + ".Input"],
            ),
            outputFile: this.buildPayloadFile(
              payloadFiles["step." + step.Id + ".Output"],
            ),
            hasTelemetry,
            telemetryString,
            hasLimitPressure,
            formattedRetryCount:
              step.Retry_Count__c !== undefined && step.Retry_Count__c !== null
                ? step.Retry_Count__c
                : "—",
            budgetClass: hasLimitPressure
              ? "text-red slds-text-title_bold"
              : "slds-text-color_weak",
            isEligibleForSkip:
              inst.Status__c === "Failed" && step.Status__c === "Failed",
            breadcrumbs: stepBreadcrumbs,
            hasBreadcrumbs: stepBreadcrumbs.length > 0,
          };
        });

        // Check if we can stop polling early
        const isStillWaitingForApproval = this.steps.some(
          (step) => step.isWaitingForApproval,
        );
        const isTransitioning =
          inst.Status__c === "Running" ||
          inst.Status__c === "Compensating" ||
          inst.Status__c === "Cancelling";
        if (!isStillWaitingForApproval && !isTransitioning) {
          this.stopPolling();
        }
      })
      .catch((error) => {
        if (currentInstanceId === this.selectedInstanceId) {
          this.showToast(
            "Error",
            "Failed to retrieve details: " + this.reduceErrors(error),
            "error",
          );
        }
      })
      .finally(() => {
        if (currentInstanceId === this.selectedInstanceId) {
          this.loadingDetails = false;
        }
      });
  }

  toggleStepDetails(event) {
    const stepId = event.currentTarget.dataset.stepId;
    this.steps = this.steps.map((step) => {
      if (step.Id === stepId) {
        return { ...step, showDetails: !step.showDetails };
      }
      return step;
    });
  }

  handleRefresh() {
    if (this.viewingDrain) {
      this.loadDrain(true);
    }
    if (this.viewingFailureBreakdown) {
      this.fetchFailureBreakdown();
    }
    if (this.viewingLatency) {
      this.fetchLatency();
    }
    if (this.viewingCatalog) {
      this.loadCatalog();
    }
    if (this.viewingHealth) {
      this.fetchHealth();
    }
    this.fetchTrends();
    this.refreshInstances().then(() => {
      this.showToast("Success", "Workflow dashboard refreshed", "success");
    });
  }

  handleOpenDoctor() {
    this.viewingDoctor = true;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    this.loadDoctorStatus();
  }

  handleCloseDoctor() {
    this.viewingDoctor = false;
  }

  handleOpenDrain() {
    this.viewingDrain = true;
    this.viewingDoctor = false;
    this.viewingUnrouted = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    // Re-run the query if a workflow is already selected; the combobox value
    // hasn't changed, so its onchange won't fire to refresh the table itself.
    if (this.drainWorkflow) {
      this.loadDrain();
    } else {
      this.drainRows = [];
    }
  }

  handleCloseDrain() {
    this.viewingDrain = false;
  }

  handleOpenSchedules() {
    this.viewingSchedules = true;
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.selectedInstanceId = null;
    this.resetChain();
  }

  handleCloseSchedules() {
    this.viewingSchedules = false;
  }

  handleOpenUnrouted() {
    this.viewingUnrouted = true;
    this.viewingDrain = false;
    this.viewingDoctor = false;
    this.viewingSchedules = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    this.loadUnroutedSignals();
  }

  handleCloseUnrouted() {
    this.viewingUnrouted = false;
  }

  handleOpenFailureBreakdown() {
    this.viewingFailureBreakdown = true;
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingSchedules = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.viewingLatency = false;
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    if (this.selectedWorkflow) {
      this.breakdownWorkflow = this.selectedWorkflow;
    } else if (!this.breakdownWorkflow && this.definitionOptions.length > 0) {
      this.breakdownWorkflow = this.definitionOptions[0].value;
    }
    this.fetchFailureBreakdown();
  }

  handleCloseFailureBreakdown() {
    this.viewingFailureBreakdown = false;
  }

  handleOpenCatalog() {
    this.viewingCatalog = true;
    this.handleCloseHealth();
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingSchedules = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    this.loadCatalog();
  }

  handleCloseCatalog() {
    this.viewingCatalog = false;
  }

  loadCatalog() {
    this.loadingCatalog = true;
    getWorkflowCatalog()
      .then((result) => {
        this.catalogRows = (result || []).map((row) =>
          this.formatCatalogRow(row),
        );
      })
      .catch((error) => {
        this.catalogRows = [];
        this.showToast(
          "Error",
          "Failed to retrieve the workflow catalog: " +
            this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingCatalog = false;
      });
  }

  // Shapes a raw catalog row for display: resolves the description/version placeholders and
  // precomputes the deep-link dataset the template stamps onto the click targets.
  formatCatalogRow(row) {
    const description =
      row.description && row.description.trim().length > 0
        ? row.description
        : "";
    return {
      ...row,
      descriptionDisplay: description,
      isUndocumented: !row.documented,
      versionDisplay: row.versioned ? "v" + row.version : "—",
    };
  }

  // Opens the instance list from a Catalog row or a status count. The list shows that
  // definition and, for a status count, that status.
  handleCatalogRowClick(event) {
    this.openInstanceList(
      event.currentTarget.dataset.definition,
      event.currentTarget.dataset.status || "",
    );
  }

  // Opens the instance list for a definition and an optional status. Closes the Catalog
  // and Fleet Health views. Clears the search and attribute filters, so that the list
  // shows all instances of the definition.
  openInstanceList(definition, status) {
    if (!definition) {
      return;
    }
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.showingStalled = false;
    this.selectedWorkflow = definition;
    this.selectedStatus = status;
    this.selectedFailureCategory = "";
    this.searchTerm = "";
    this.attributeFilters = {};
    this.fetchInstances(false);
  }

  // ────────────────────────────────────────────────────────────────────────
  // FLEET HEALTH (#111)
  // ────────────────────────────────────────────────────────────────────────

  handleOpenHealth() {
    this.viewingHealth = true;
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingSchedules = false;
    this.viewingFailureBreakdown = false;
    this.viewingLatency = false;
    this.viewingCatalog = false;
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    this.fetchHealth();
  }

  // Closes the view. A request that is in progress becomes stale, so it cannot show a
  // toast on a different view.
  handleCloseHealth() {
    this.viewingHealth = false;
    this._healthRequestId++;
    this.loadingHealth = false;
  }

  fetchHealth() {
    const requestId = ++this._healthRequestId;
    this.loadingHealth = true;
    return getFleetHealth({ windowKey: this.healthWindow })
      .then((result) => {
        if (requestId === this._healthRequestId) {
          this.healthData = result;
          this.healthError = "";
          this.buildHealthRows();
        }
      })
      .catch((error) => {
        if (requestId !== this._healthRequestId) {
          return;
        }
        const message = this.reduceErrors(error);
        this.healthData = null;
        this.healthError = message;
        this.buildHealthRows();
        this.showToast(
          "Error",
          "Failed to load fleet health: " + message,
          "error",
        );
      })
      .finally(() => {
        if (requestId === this._healthRequestId) {
          this.loadingHealth = false;
        }
      });
  }

  handleHealthWindowChange(event) {
    this.healthWindow = event.detail ? event.detail.value : event.target.value;
    this.fetchHealth();
  }

  // Keeps the last valid threshold when the input is blank, not a number, or out of range.
  // The view shows the threshold that it uses.
  handleHealthThresholdChange(event) {
    const raw = event.detail ? event.detail.value : event.target.value;
    const value = raw === "" || raw === null ? NaN : Number(raw);
    if (Number.isFinite(value) && value >= 0 && value <= 100) {
      this.healthThreshold = value;
      this.buildHealthRows();
    }
  }

  handleHealthRowClick(event) {
    this.openInstanceList(event.currentTarget.dataset.definition, "");
  }

  get hasHealthRows() {
    return this.healthRows.length > 0;
  }

  // The empty state shows only after a load that has no rows.
  get showHealthEmpty() {
    return !this.healthError && this.healthRows.length === 0;
  }

  get healthIsSampled() {
    return !!(this.healthData && this.healthData.isSampled);
  }

  get healthSampleCap() {
    return this.healthData ? this.healthData.sampleCap : 0;
  }

  get healthCountsCapped() {
    return !!(this.healthData && this.healthData.countsCapped);
  }

  get healthCountCap() {
    return this.healthData ? this.healthData.countCap : 0;
  }

  // Builds the display rows. It runs when data arrives or the threshold changes, not on
  // each render. The flag uses the counts, not the rounded rate, so 94.96% is below 95%.
  buildHealthRows() {
    const rows = (this.healthData && this.healthData.rows) || [];
    this.healthRows = rows.map((row) => {
      const terminal = (row.completed || 0) + (row.failed || 0);
      const hasRate = terminal > 0;
      const belowThreshold =
        hasRate && (row.completed * 100) / terminal < this.healthThreshold;
      return {
        ...row,
        belowThreshold,
        rowClass: belowThreshold
          ? "slds-hint-parent health-row-below"
          : "slds-hint-parent",
        rateDisplay: hasRate ? `${row.successRate}%` : "—",
        rateClass: belowThreshold ? "text-red" : hasRate ? "text-green" : "",
        failedClass: row.failed > 0 ? "text-red" : "",
        linkTitle: `View the instances of ${row.workflowName}`,
        avgApprox: this.isApproxDuration(
          row.avgDurationMs,
          row.durationSampled,
        ),
        avgDisplay: this.formatDuration(row.avgDurationMs),
        maxApprox: this.isApproxDuration(
          row.maxDurationMs,
          row.durationSampled,
        ),
        maxDisplay: this.formatDuration(row.maxDurationMs),
      };
    });
  }

  // A sampled duration shows "≈". A missing value shows only "—".
  isApproxDuration(ms, sampled) {
    return !!sampled && ms !== null && ms !== undefined;
  }

  handleBreakdownWorkflowChange(event) {
    this.breakdownWorkflow = event.detail
      ? event.detail.value
      : event.target.value;
    this.fetchFailureBreakdown();
  }

  handleBreakdownTimeWindowChange(event) {
    this.breakdownTimeWindow = event.detail
      ? event.detail.value
      : event.target.value;
    this.fetchFailureBreakdown();
  }

  fetchFailureBreakdown() {
    if (!this.breakdownWorkflow) {
      this.breakdownData = null;
      return;
    }
    this.loadingFailureBreakdown = true;
    getWorkflowFailureBreakdown({
      workflowName: this.breakdownWorkflow,
      timeWindow:
        this.breakdownTimeWindow === "all" ? null : this.breakdownTimeWindow,
    })
      .then((result) => {
        this.breakdownData = result;
        this.loadingFailureBreakdown = false;
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to retrieve failure breakdown: " + this.reduceErrors(error),
          "error",
        );
        this.loadingFailureBreakdown = false;
        this.breakdownData = null;
      });
  }

  handleOpenLatency() {
    this.viewingLatency = true;
    this.viewingFailureBreakdown = false;
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingSchedules = false;
    this.viewingCatalog = false;
    this.handleCloseHealth();
    this.selectedInstanceId = null;
    this.resetChain();
    this.filterInstancesList();
    if (this.selectedWorkflow) {
      this.latencyWorkflow = this.selectedWorkflow;
    } else if (!this.latencyWorkflow && this.definitionOptions.length > 0) {
      this.latencyWorkflow = this.definitionOptions[0].value;
    }
    this.fetchLatency();
  }

  handleCloseLatency() {
    this.viewingLatency = false;
  }

  handleLatencyWorkflowChange(event) {
    this.latencyWorkflow = event.detail
      ? event.detail.value
      : event.target.value;
    this.fetchLatency();
  }

  handleLatencyTimeWindowChange(event) {
    this.latencyTimeWindow = event.detail
      ? event.detail.value
      : event.target.value;
    this.fetchLatency();
  }

  fetchLatency() {
    if (!this.latencyWorkflow) {
      this.latencyData = null;
      return;
    }
    const requestId = ++this._latencyRequestSeq;
    this.loadingLatency = true;
    getDefinitionLatency({
      workflowName: this.latencyWorkflow,
      windowKey:
        this.latencyTimeWindow === "all" ? null : this.latencyTimeWindow,
    })
      .then((result) => {
        // Discard a stale resolution: a newer request has superseded this one,
        // so it must not overwrite the newer data or clear the newer spinner.
        if (requestId !== this._latencyRequestSeq) {
          return;
        }
        this.latencyData = result;
        this.loadingLatency = false;
      })
      .catch((error) => {
        if (requestId !== this._latencyRequestSeq) {
          return;
        }
        this.showToast(
          "Error",
          "Failed to retrieve latency metrics: " + this.reduceErrors(error),
          "error",
        );
        this.loadingLatency = false;
        this.latencyData = null;
      });
  }

  loadUnroutedSignals() {
    this.loadingUnrouted = true;
    const buster = new Date().getTime().toString();
    Promise.all([
      getUnroutedSignals({
        criteria: {
          searchTerm: null,
          limitSize: 50,
          offsetSize: 0,
          cacheBuster: buster,
        },
      }),
      getUnroutedSignalCount({ searchTerm: null }),
    ])
      .then(([signals, countResult]) => {
        this.unroutedSignals = signals || [];
        this.unroutedCountData = countResult || { count: 0, capped: false };
      })
      .catch((err) => {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Error",
            message: this.reduceErrors(err),
            variant: "error",
          }),
        );
      })
      .finally(() => {
        this.loadingUnrouted = false;
      });
  }

  handleRedeliver(event) {
    const signalId = event.currentTarget.dataset.signalId;
    if (!signalId) return;
    this.redelivering = { ...this.redelivering, [signalId]: true };
    redeliverSignal({ signalId })
      .then((result) => {
        const matched = result && result.matched;
        this.dispatchEvent(
          new ShowToastEvent({
            title: matched ? "Signal Re-delivered" : "No Match Yet",
            message: matched
              ? "The signal was re-delivered and the workflow was woken."
              : "No active workflow matched — signal remains Unrouted.",
            variant: matched ? "success" : "warning",
          }),
        );
        if (matched) {
          this.loadUnroutedSignals();
        }
      })
      .catch((err) => {
        this.dispatchEvent(
          new ShowToastEvent({
            title: "Error",
            message: this.reduceErrors(err),
            variant: "error",
          }),
        );
      })
      .finally(() => {
        const updated = { ...this.redelivering };
        delete updated[signalId];
        this.redelivering = updated;
      });
  }

  get unroutedCountDisplay() {
    if (!this.unroutedCountData) return "0";
    const count = this.unroutedCountData.count || 0;
    return this.unroutedCountData.capped ? `${count}+` : String(count);
  }

  get hasUnroutedSignals() {
    return this.unroutedSignals && this.unroutedSignals.length > 0;
  }

  handleDrainWorkflowChange(event) {
    this.drainWorkflow = event.detail.value;
    this.loadDrain();
  }

  // isRefresh = true is a silent periodic/toolbar re-fetch of the same workflow:
  // it keeps the current rows visible (no spinner, no flicker) and swallows
  // errors. A fresh load (workflow change / panel open) clears prior rows up front
  // so a slow or failing request never leaves a previous definition's retirement
  // status showing under the new selection.
  loadDrain(isRefresh) {
    if (!this.drainWorkflow) {
      this.drainRows = [];
      return;
    }
    // Capture the requested workflow so a slower, earlier response for a
    // previously-selected workflow can't overwrite the current selection.
    const requestedWorkflow = this.drainWorkflow;
    if (!isRefresh) {
      this.drainRows = [];
      this.loadingDrain = true;
    }
    getVersionDrain({ workflowName: requestedWorkflow })
      .then((rows) => {
        if (this.drainWorkflow !== requestedWorkflow) {
          return;
        }
        this.drainRows = rows.map((row) => {
          let badgeClass;
          let badgeLabel;
          if (row.nonTerminalCount > 0) {
            badgeClass = "badge badge-red";
            badgeLabel = `In-flight: ${row.nonTerminalCount}`;
          } else if (row.failedCount > 0) {
            // Re-drivable failures: not in-flight, but retiring the version's
            // code would break Retry/Re-drive — operator must review first.
            badgeClass = "badge badge-orange";
            badgeLabel = `Review failures: ${row.failedCount}`;
          } else {
            badgeClass = "badge badge-green";
            badgeLabel = "Safe to retire";
          }
          return {
            ...row,
            badgeClass,
            badgeLabel,
            versionLabel: row.version != null ? `v${row.version}` : "(none)",
          };
        });
      })
      .catch((error) => {
        if (this.drainWorkflow !== requestedWorkflow || isRefresh) {
          // Silent on background refresh — keep the last good rows.
          return;
        }
        this.showToast(
          "Error",
          "Failed to load version drain: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        if (this.drainWorkflow === requestedWorkflow && !isRefresh) {
          this.loadingDrain = false;
        }
      });
  }

  get hasDrainRows() {
    return this.drainRows.length > 0;
  }

  get drainWorkflowSelected() {
    return !!this.drainWorkflow;
  }

  loadDoctorStatus() {
    this.loadingDoctor = true;
    this.fetchTrends();
    getWatchdogStatus()
      .then((result) => {
        let latestJobVal = null;
        if (result && result.latestJob) {
          latestJobVal = {
            ...result.latestJob,
            statusBadgeClass: this.getStatusBadgeClass(
              result.latestJob.Status__c,
            ),
          };
        }
        this.doctorData = result
          ? {
              ...result,
              latestJob: latestJobVal,
              latestJobCreatedDate: result.latestJob
                ? this.formatDateTime(result.latestJob.CreatedDate)
                : null,
            }
          : { config: {} };
        this.refreshPeView();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to load doctor status: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDoctor = false;
      });

    getConcurrencyStatus()
      .then((rows) => {
        this.concurrencyRows = (rows || []).map((r) => ({
          ...r,
          ceilingLabel:
            r.ceiling === null || r.ceiling === undefined ? "—" : r.ceiling,
          atCapacity:
            r.ceiling !== null &&
            r.ceiling !== undefined &&
            r.inFlight >= r.ceiling,
          ...this.buildWaitingQueue(r),
        }));
      })
      .catch((error) => {
        // Concurrency panel is best-effort; never block the System Doctor view.
        this.concurrencyRows = [];
        console.error(
          "Failed to load concurrency status:",
          this.reduceErrors(error),
        );
      });

    this.loadStorageFootprint();
    this.loadRateLimitStatus();
    this.loadReadiness();
  }

  // Runs the readiness checks. Only the newest request can change the panel.
  // Best-effort: a failure shows an inline message and does not stop the view.
  loadReadiness() {
    const requestId = ++this.readinessRequestSeq;
    const startedMs = Date.now();
    this.readinessRunning = true;
    getReadinessChecks()
      .then((rows) => {
        if (requestId !== this.readinessRequestSeq) {
          return;
        }
        if (!Array.isArray(rows) || rows.length === 0) {
          this.setReadinessError("No checks were returned.");
          return;
        }
        this.readinessError = null;
        this.readinessRows = rows.map((row) => this.shapeReadinessRow(row));
        this.readinessElapsedMs = Date.now() - startedMs;
        this.readinessLoaded = true;
        this.readinessRunning = false;
      })
      .catch((error) => {
        if (requestId !== this.readinessRequestSeq) {
          return;
        }
        const reason = this.reduceErrors(error);
        this.setReadinessError(reason);
        console.error("Failed to load readiness checks:", reason);
      });
  }

  handleRunReadiness() {
    this.loadReadiness();
  }

  setReadinessError(reason) {
    this.readinessRows = [];
    this.readinessElapsedMs = null;
    this.readinessError = reason;
    this.readinessLoaded = true;
    this.readinessRunning = false;
  }

  // Adds display labels to one row. Apex sets the status and the text.
  // A Pass row shows no fix.
  shapeReadinessRow(row) {
    const status = READINESS_STATUS[row.status] || READINESS_UNKNOWN;
    return {
      ...row,
      statusLabel: status.label,
      badgeClass: status.badgeClass,
      icon: status.icon,
      iconClass: status.iconClass,
      showRemediation: status !== READINESS_STATUS.Pass && !!row.remediation,
    };
  }

  get hasReadinessRows() {
    return this.readinessRows.length > 0;
  }

  get showReadinessLoading() {
    return !this.readinessLoaded;
  }

  // "All checks pass" only when every row is a known Pass. Error and empty are not a pass.
  get readinessSummary() {
    if (!this.hasReadinessRows) {
      return "";
    }
    const fails = this.readinessRows.filter((r) => r.statusLabel === "Fail");
    const warns = this.readinessRows.filter((r) => r.statusLabel === "Warn");
    const unknown = this.readinessRows.filter(
      (r) => r.statusLabel === "Unknown",
    );
    const parts = [];
    if (fails.length) {
      parts.push(`${fails.length} fail`);
    }
    if (warns.length) {
      parts.push(`${warns.length} warn`);
    }
    if (unknown.length) {
      parts.push(`${unknown.length} unknown`);
    }
    return parts.length ? `· ${parts.join(" · ")}` : "· All checks pass";
  }

  // Red for a Fail, orange for Warn or Unknown, green for all Pass.
  get readinessSummaryClass() {
    const labels = this.readinessRows.map((r) => r.statusLabel);
    let colour = "text-green";
    if (labels.includes("Fail")) {
      colour = "text-red";
    } else if (labels.some((label) => label !== "Pass")) {
      colour = "text-orange";
    }
    return `slds-m-left_x-small ${colour}`;
  }

  get readinessTimingLabel() {
    if (this.readinessRunning) {
      return "Running…";
    }
    return this.readinessElapsedMs === null
      ? ""
      : `Checked in ${this.readinessElapsedMs} ms`;
  }

  refreshPeView() {
    this.peView = buildPeView(
      this.doctorData,
      this._peWarningSetting,
      this._peCriticalSetting,
    );
  }

  // Watchdog liveness (#113). The server calculates the state on each read.
  get watchdogLiveness() {
    return (this.doctorData && this.doctorData.liveness) || {};
  }

  get livenessStatus() {
    return LIVENESS_STATUS[this.watchdogLiveness.state] || LIVENESS_UNKNOWN;
  }

  get livenessLabel() {
    return this.livenessStatus.label;
  }

  get livenessBadgeClass() {
    return `${this.livenessStatus.badgeClass} slds-m-right_small`;
  }

  get isLivenessStale() {
    return this.watchdogLiveness.state === "STALE";
  }

  get livenessDetailClass() {
    return this.isLivenessStale
      ? "slds-text-body_small slds-text-color_error"
      : "slds-text-body_small slds-text-color_weak";
  }

  // An active watchdog record with no recent sweep: the chain can be dead.
  get watchdogRunningButStale() {
    return (
      !!(this.doctorData && this.doctorData.isRunning) && this.isLivenessStale
    );
  }

  get livenessDetail() {
    const live = this.watchdogLiveness;
    if (!live.lastSweepAt) {
      return "No sweep recorded yet.";
    }
    let text = `Last sweep ${this.formatDateTime(live.lastSweepAt)}`;
    if (live.elapsedMinutes != null) {
      text += ` (${live.elapsedMinutes} min ago)`;
    }
    text += ".";
    if (live.thresholdMinutes != null) {
      text += ` Stale after ${live.thresholdMinutes} min.`;
    }
    return text;
  }

  // Issue #132: wait queue in admission order, and counts per priority class
  // (highest first). Tolerates rows with no queue fields.
  buildWaitingQueue(r) {
    const waiting = (r.waiting || []).map((w) => ({
      ...w,
      key: w.instanceId,
      positionLabel: `#${w.position}`,
      priorityLabel: `P${w.priority}`,
      priorityTitle: `Admission priority ${w.priority}. The gate admits a higher value sooner.`,
      label: w.name || w.instanceId,
    }));
    const byPriority = r.waitingByPriority || {};
    const priorityClasses = Object.keys(byPriority)
      .map((p) => Number(p))
      .sort((a, b) => b - a)
      .map((p) => `P${p}: ${byPriority[p]}`)
      .join(" · ");
    const waitingTotal = r.waitingTotal || 0;
    return {
      queueKey: `${r.workflowName}-queue`,
      waitingRows: waiting,
      hasWaitingRows: waiting.length > 0,
      hasWaitingSummary: waitingTotal > 0,
      waitingSummary: `${waitingTotal} waiting · ${priorityClasses}`,
    };
  }

  get hasConcurrencyRows() {
    return this.concurrencyRows && this.concurrencyRows.length > 0;
  }

  // Loads the read-only Storage Footprint snapshot and shapes each per-object row with a
  // human-readable size and formatted growth deltas for the panel. Best-effort: a failure
  // clears the panel and logs, never blocking the rest of the System Doctor view.
  loadStorageFootprint() {
    getStorageFootprint()
      .then((result) => {
        if (!result) {
          this.storageData = null;
          this.storageObjectRows = [];
          return;
        }
        this.storageData = result;
        this.storageObjectRows = (result.objects || []).map((row) => ({
          ...row,
          estimatedSizeLabel: this.formatBytes(row.estimatedBytes),
          delta7Label: this.formatDelta(row.delta7),
          delta30Label: this.formatDelta(row.delta30),
        }));
      })
      .catch((error) => {
        this.storageData = null;
        this.storageObjectRows = [];
        console.error(
          "Failed to load storage footprint:",
          this.reduceErrors(error),
        );
      });
  }

  // Loads the live token buckets. A new cacheBuster on each load bypasses the Lightning
  // cache. Best-effort: a failure shows an inline message and does not stop the view.
  // Only the newest request can change the panel.
  loadRateLimitStatus() {
    const requestId = ++this.rateLimitRequestSeq;
    getRateLimitStatus({
      cacheBuster: `${Date.now()}-${requestId}`,
    })
      .then((result) => {
        if (requestId !== this.rateLimitRequestSeq) {
          return;
        }
        if (!result || !Array.isArray(result.rows)) {
          this.setRateLimitError("No data was returned.");
          return;
        }
        this.rateLimitError = null;
        this.rateLimitAsOfMs = result.asOfMs;
        this.rateLimitRows = result.rows.map((row) =>
          this.shapeRateLimitRow(row),
        );
        this.rateLimitLoaded = true;
      })
      .catch((error) => {
        if (requestId !== this.rateLimitRequestSeq) {
          return;
        }
        const reason = this.reduceErrors(error);
        this.setRateLimitError(reason);
        console.error("Failed to load rate limit status:", reason);
      });
  }

  setRateLimitError(reason) {
    this.rateLimitRows = [];
    this.rateLimitAsOfMs = null;
    this.rateLimitError = reason;
    this.rateLimitLoaded = true;
  }

  // Adds display labels to one row. Apex sets the status and the numbers.
  shapeRateLimitRow(row) {
    const status = RATE_LIMIT_STATUS[row.status] || RATE_LIMIT_UNKNOWN;
    const hasTokens =
      row.availableTokens !== null && row.availableTokens !== undefined;
    const capacity =
      row.capacity === null || row.capacity === undefined ? "—" : row.capacity;
    const isThrottling = row.status === "THROTTLING";
    return {
      ...row,
      statusLabel: status.label,
      badgeClass: status.badgeClass,
      icon: status.icon,
      iconClass: status.iconClass,
      configLabel: `Capacity ${capacity} · refill ${
        row.refillRatePerSecond ?? "—"
      }/s`,
      tokensLabel: `${
        hasTokens ? Number(row.availableTokens).toFixed(2) : "—"
      } / ${capacity} tokens`,
      nextTokenLabel:
        isThrottling && row.secondsUntilNextToken != null
          ? `Next token in ${row.secondsUntilNextToken} s`
          : null,
      isIdle: row.status === "IDLE",
    };
  }

  get hasRateLimitRows() {
    return this.rateLimitRows.length > 0;
  }

  get showRateLimitEmpty() {
    return (
      this.rateLimitLoaded && !this.rateLimitError && !this.hasRateLimitRows
    );
  }

  get showRateLimitLoading() {
    return !this.rateLimitLoaded;
  }

  get rateLimitSummary() {
    const count = this.rateLimitRows.filter(
      (row) => row.status === "THROTTLING",
    ).length;
    return count > 0 ? `· ${count} throttling` : "";
  }

  get rateLimitAsOfLabel() {
    return this.rateLimitAsOfMs
      ? `As of ${new Date(this.rateLimitAsOfMs).toLocaleTimeString()}`
      : "";
  }

  get hasStorageData() {
    return !!this.storageData;
  }

  get storageContentSizeLabel() {
    return this.storageData
      ? this.formatBytes(this.storageData.contentVersionBytes)
      : "—";
  }

  get storageTotalSizeLabel() {
    return this.storageData
      ? this.formatBytes(this.storageData.estimatedTotalBytes)
      : "—";
  }

  // CSS class for the allowance meter: warning styling once the estimated footprint crosses
  // the operator-configured threshold, otherwise the normal accent.
  get storageAllowanceClass() {
    return this.storageData && this.storageData.isOverThreshold
      ? "storage-meter storage-meter_warning"
      : "storage-meter";
  }

  get storagePercentLabel() {
    if (!this.storageData || !this.storageData.hasStorageLimit) {
      return "N/A";
    }
    return this.storageData.percentOfAllowance + "%";
  }

  // File-storage gauge: offloaded ContentVersion payloads bill against the org's FILE storage
  // allowance, reported separately from the data-storage percentage. Informational only — the
  // configurable warning threshold applies to the data percentage, not this one.
  get storageFilePercentLabel() {
    if (!this.storageData || !this.storageData.hasFileStorageLimit) {
      return "N/A";
    }
    return this.storageData.filePercentOfAllowance + "%";
  }

  // Formats a byte count as a compact human-readable size (B / KB / MB / GB).
  formatBytes(bytes) {
    const value = Number(bytes) || 0;
    if (value < 1024) {
      return value + " B";
    }
    const units = ["KB", "MB", "GB", "TB"];
    let size = value / 1024;
    let unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    return size.toFixed(1) + " " + units[unitIndex];
  }

  // Formats a trailing-window growth delta with an explicit "+" so acceleration reads clearly.
  formatDelta(delta) {
    const value = Number(delta) || 0;
    return "+" + value;
  }

  handleEnqueueWatchdog() {
    this.loadingDoctor = true;
    enqueueWatchdog()
      .then(() => {
        this.showToast("Success", "Watchdog enqueued successfully.", "success");
        this.loadDoctorStatus();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to enqueue watchdog: " + this.reduceErrors(error),
          "error",
        );
        this.loadingDoctor = false;
      });
  }

  handleOpenModal() {
    this.launchName = "";
    this.launchKey = "";
    this.launchInputJson = "";
    this.launchError = "";
    this.modalOpen = true;
  }

  handleCloseModal() {
    this.modalOpen = false;
  }

  handleLaunchFieldChange(event) {
    const fieldName = event.target.name;
    this[fieldName] = event.target.value;
  }

  handleExecuteWorkflow() {
    if (this.executingLaunch) {
      return;
    }
    this.launchError = "";
    if (!this.launchName) {
      this.launchError = "Please select a Workflow Definition.";
      return;
    }
    if (!this.launchKey || !this.launchKey.trim()) {
      this.launchError = "Please provide a Correlation Key.";
      return;
    }

    // Validate JSON if provided
    if (this.launchInputJson) {
      const normalized = this._normalizeJson(this.launchInputJson);
      if (normalized === null) {
        this.launchError =
          "Input Payload must be valid JSON. " +
          "If you pasted from a chat or document, re-type the quote characters — " +
          "“curly quotes” are not valid JSON.";
        return;
      }
      this.launchInputJson = normalized;
    }

    this.executingLaunch = true;
    startWorkflow({
      workflowName: this.launchName,
      correlationKey: this.launchKey,
      inputJson: this.launchInputJson,
    })
      .then((result) => {
        this.showToast(
          "Success",
          "Workflow instance started successfully. ID: " + result,
          "success",
        );
        this.modalOpen = false;
        this.refreshInstances();
      })
      .catch((error) => {
        this.launchError =
          "Failed to execute workflow: " + this.reduceErrors(error);
      })
      .finally(() => {
        this.executingLaunch = false;
      });
  }

  handleRetryWorkflow() {
    this.loadingDetails = true;
    retryWorkflowInstance({ instanceId: this.selectedInstanceId })
      .then(() => {
        this.showToast(
          "Success",
          "Workflow instance queued for retry successfully.",
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to retry workflow: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleResumePastStep(event) {
    const stepName = event.target.dataset.stepName;
    const textarea = this.template.querySelector(
      `textarea[data-step-name="${stepName}"]`,
    );
    let payload = textarea ? textarea.value : "";

    if (payload && payload.trim()) {
      const normalized = this._normalizeJson(payload);
      if (normalized === null) {
        if (textarea) {
          textarea.setCustomValidity(
            "Invalid JSON format. Typographic/curly quotes are not valid JSON.",
          );
          textarea.reportValidity();
        }
        return;
      }
      payload = normalized;
      if (textarea) {
        textarea.setCustomValidity("");
        textarea.reportValidity();
      }
    } else {
      if (textarea) {
        textarea.setCustomValidity("");
        textarea.reportValidity();
      }
    }

    LightningConfirm.open({
      message: `Are you sure you want to skip step "${stepName}" and resume forward execution using the supplied JSON output?`,
      variant: "headerless",
      label: "Confirm Skip Step",
    }).then((result) => {
      if (!result) {
        return;
      }

      this.loadingDetails = true;
      resumePastStepInstance({
        instanceId: this.selectedInstanceId,
        stepName: stepName,
        suppliedOutputJson: payload,
      })
        .then(() => {
          this.showToast(
            "Success",
            `Workflow resumed past step ${stepName}.`,
            "success",
          );
          this.refreshInstances();
          this.loadDetails(true);
          this.startPolling();
        })
        .catch((error) => {
          this.showToast(
            "Error",
            "Failed to resume past step: " + this.reduceErrors(error),
            "error",
          );
        })
        .finally(() => {
          this.loadingDetails = false;
        });
    });
  }

  // Enable bulk re-drive only when the current filter actually contains failed
  // (recoverable) instances and the stalled view is not active (stalled rows are
  // Suspended, not Failed; showing the button there would re-drive hidden failures).
  get isRedriveDisabled() {
    return (
      !this.stats ||
      this.stats.failed === 0 ||
      this.redriving ||
      this.showingStalled
    );
  }

  get redriveButtonLabel() {
    return `Re-drive (${this.stats ? this.stats.failed : 0})`;
  }

  get isCancelDisabled() {
    return (
      !this.stats ||
      this.stats.active === 0 ||
      this.cancellingMatching ||
      this.showingStalled
    );
  }

  get cancelButtonLabel() {
    return this.cancellingMatching
      ? "Counting..."
      : `Cancel (${this.stats ? this.stats.active : 0})`;
  }

  handleRedriveMatching() {
    if (this.redriving) {
      return;
    }
    this.redriving = true;
    // Snapshot filter values so the count call and the launch call always
    // target the same selection, even if the operator changes filters while
    // the count request is in flight.
    this.redriveSnapshotName = this.selectedWorkflow;
    this.redriveSnapshotStatus = this.selectedStatus;
    this.redriveSnapshotSearchTerm = this.searchTerm;
    getRedriveEligibleCount({
      workflowName: this.redriveSnapshotName,
      status: this.redriveSnapshotStatus,
      searchTerm: this.redriveSnapshotSearchTerm,
    })
      .then((count) => {
        if (!count || count === 0) {
          this.redriving = false;
          this.showToast(
            "Nothing to re-drive",
            "No failed instances match the current filter.",
            "info",
          );
          return;
        }
        this.redriveCount = count;
        this.redriving = false;
        this.redriveModalOpen = true;
      })
      .catch((error) => {
        this.redriving = false;
        this.showToast(
          "Error",
          "Failed to count re-drive candidates: " + this.reduceErrors(error),
          "error",
        );
      });
  }

  handleRedriveModalClose() {
    this.redriveModalOpen = false;
  }

  handleRedriveModalConfirm() {
    this.redriveModalOpen = false;
    this.redriving = true;
    redriveMatchingInstances({
      workflowName: this.redriveSnapshotName,
      status: this.redriveSnapshotStatus,
      searchTerm: this.redriveSnapshotSearchTerm,
    })
      .then((outcome) => {
        if (!outcome) {
          return;
        }
        if (outcome.started) {
          this.showToast(
            "Re-drive started",
            `Re-driving ${outcome.eligibleCount} failed instance${outcome.eligibleCount === 1 ? "" : "s"}. ` +
              "Progress is shown in the detail panel below.",
            "success",
          );
          this.closeViews();
          this.selectedInstanceId = outcome.redriveInstanceId;
          this.refreshInstances();
          this.loadDetails(true);
          this.startPolling();
        } else {
          this.showToast(
            "Nothing to re-drive",
            "No failed instances match the current filter.",
            "info",
          );
        }
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to re-drive matching instances: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.redriving = false;
      });
  }

  handleCancelMatching() {
    if (this.cancellingMatching) {
      return;
    }
    this.cancellingMatching = true;
    this.cancelSnapshotName = this.selectedWorkflow;
    this.cancelSnapshotStatus = this.selectedStatus;
    this.cancelSnapshotSearchTerm = this.searchTerm;
    getCancelEligibleCount({
      workflowName: this.cancelSnapshotName,
      status: this.cancelSnapshotStatus,
      searchTerm: this.cancelSnapshotSearchTerm,
    })
      .then((count) => {
        if (!count || count === 0) {
          this.cancellingMatching = false;
          this.showToast(
            "Nothing to cancel",
            "No active instances match the current filter.",
            "info",
          );
          return;
        }
        this.cancelMatchingCount = count;
        this.cancellingMatching = false;
        this.cancelMatchingModalOpen = true;
      })
      .catch((error) => {
        this.cancellingMatching = false;
        this.showToast(
          "Error",
          "Failed to count cancel candidates: " + this.reduceErrors(error),
          "error",
        );
      });
  }

  handleCancelMatchingModalClose() {
    this.cancelMatchingModalOpen = false;
  }

  handleCancelMatchingModalConfirm() {
    this.cancelMatchingModalOpen = false;
    this.cancellingMatching = true;
    cancelMatchingInstances({
      workflowName: this.cancelSnapshotName,
      status: this.cancelSnapshotStatus,
      searchTerm: this.cancelSnapshotSearchTerm,
    })
      .then((outcome) => {
        if (!outcome) {
          return;
        }
        if (outcome.started) {
          this.showToast(
            "Success",
            `Cancellation requested for ${outcome.eligibleCount} active instance${outcome.eligibleCount === 1 ? "" : "s"}. ` +
              "Progress is shown in the detail panel below.",
            "success",
          );
          this.closeViews();
          this.selectedInstanceId = outcome.cancelInstanceId;
          this.refreshInstances();
          this.loadDetails(true);
          this.startPolling();
        } else {
          this.showToast(
            "Nothing to cancel",
            "No active instances match the current filter.",
            "info",
          );
        }
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to cancel matching instances: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.cancellingMatching = false;
      });
  }

  handleCancelWorkflow() {
    this.cancelModalOpen = true;
  }

  handleCancelModalClose() {
    this.cancelModalOpen = false;
  }

  handleCancelModalConfirm(event) {
    const runCompensations = event.currentTarget.dataset.compensate === "true";
    this.cancelModalOpen = false;
    this.loadingDetails = true;
    cancelWorkflow({
      req: {
        instanceId: this.selectedInstanceId,
        runCompensations,
      },
    })
      .then(() => {
        this.showToast(
          "Success",
          "Workflow cancellation requested successfully.",
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to cancel workflow: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleOpenCompensateModal() {
    this.compensateModalOpen = true;
  }

  handleCloseCompensateModal() {
    this.compensateModalOpen = false;
  }

  handleConfirmCompensate() {
    this.compensateModalOpen = false;
    this.loadingDetails = true;
    compensateWorkflow({ instanceId: this.selectedInstanceId })
      .then((compensatingInstanceId) => {
        this.showToast(
          "Success",
          "Compensation workflow spawned successfully.",
          "success",
        );
        this.selectedInstanceId = compensatingInstanceId;
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to trigger compensation: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleOpenSignalModal() {
    this.signalModalOpen = true;
    // Pre-fill the awaited signal name (approval/child waits) so the operator can send it
    // with no transformation; a generic/timer wait leaves it blank for manual entry.
    this.signalName =
      this.selectedInst && this.selectedInst.awaitedSignalName
        ? this.selectedInst.awaitedSignalName
        : "";
    this.signalPayload = "";
  }

  handleSignalModalClose() {
    this.signalModalOpen = false;
    this.signalName = "";
    this.signalPayload = "";
  }

  handleSignalNameChange(event) {
    this.signalName = event.target.value;
  }

  handleSignalPayloadChange(event) {
    this.signalPayload = event.target.value;
  }

  handleSignalModalConfirm() {
    if (this.signalPayload && this.signalPayload.trim()) {
      const textarea = this.template.querySelector(
        '[data-id="signal-payload-input"]',
      );
      const normalized = this._normalizeJson(this.signalPayload);
      if (normalized === null) {
        if (textarea) {
          textarea.setCustomValidity(
            "Invalid JSON format. Typographic/curly quotes are not valid JSON.",
          );
          textarea.reportValidity();
        }
        return;
      }
      this.signalPayload = normalized;
      if (textarea) {
        textarea.setCustomValidity("");
        textarea.reportValidity();
      }
    } else {
      const textarea = this.template.querySelector(
        '[data-id="signal-payload-input"]',
      );
      if (textarea) {
        textarea.setCustomValidity("");
        textarea.reportValidity();
      }
    }

    this.loadingDetails = true;
    injectSignal({
      instanceId: this.selectedInstanceId,
      signalName: this.signalName,
      payloadJson: this.signalPayload,
    })
      .then(() => {
        this.signalModalOpen = false;
        this.showToast(
          "Signal Sent",
          "Signal injected successfully.",
          "success",
        );
        this.loadDetails(true);
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to inject signal: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleCommentsChange(event) {
    this.approvalComments = event.target.value;
  }

  handleApprovalSubmit(event) {
    const approvalKey = event.target.dataset.key;
    const approved = event.target.dataset.approved === "true";

    this.loadingDetails = true;
    submitApproval({
      req: {
        instanceId: this.selectedInstanceId,
        approvalKey: approvalKey,
        approved: approved,
        comments: this.approvalComments,
      },
    })
      .then(() => {
        this.showToast(
          "Success",
          `Approval decision (${approved ? "Approve" : "Reject"}) submitted successfully.`,
          "success",
        );
        this.approvalComments = "";
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to submit approval: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleResumeWorkflow() {
    this.loadingDetails = true;
    resumeWorkflowInstance({ instanceId: this.selectedInstanceId })
      .then(() => {
        this.showToast(
          "Success",
          "Workflow instance resumed successfully.",
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to resume workflow: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleHoldReasonChange(event) {
    this.holdReason = event.target.value;
    this.holdReasonInstanceId = this.selectedInstanceId;
  }

  // Issue #119: a typed reason belongs to the instance it was typed for.
  get holdReasonValue() {
    return this.holdReasonInstanceId === this.selectedInstanceId
      ? this.holdReason
      : "";
  }

  // Issue #119: hold one instance at its next step boundary.
  handleHoldInstance() {
    this.loadingDetails = true;
    holdInstance({
      instanceId: this.selectedInstanceId,
      reason: this.holdReasonValue,
    })
      .then((result) => {
        const held = result.outcome === "HELD";
        this.showToast(
          held ? "Success" : "Warning",
          result.message,
          held ? "success" : "warning",
        );
        if (held) {
          this.holdReason = "";
        }
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to hold instance: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  // Issue #119: release a held instance.
  handleReleaseHold() {
    this.loadingDetails = true;
    releaseHeldInstance({ instanceId: this.selectedInstanceId })
      .then((result) => {
        const released = result.outcome === "RELEASED";
        this.showToast(
          released ? "Success" : "Warning",
          result.message,
          released ? "success" : "warning",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to release instance: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleReleaseDefinitionChanged() {
    this.loadingDetails = true;
    releaseDefinitionChangedInstance({ instanceId: this.selectedInstanceId })
      .then(() => {
        this.showToast(
          "Success",
          "The instance runs on the live definition. The current step runs next.",
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to release instance: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  // Marks added (live only) and removed (stored only) steps for the diff view.
  mapDefinitionChange(change) {
    if (!change) {
      return null;
    }
    const lower = (names) =>
      new Set((names || []).map((n) => (n || "").trim().toLowerCase()));
    const added = lower(change.addedSteps);
    const removed = lower(change.removedSteps);
    const mark = (names, changed, cls, prefix) =>
      (names || []).map((name, index) => ({
        key: `${prefix}_${index}_${name}`,
        name,
        cssClass: changed.has((name || "").trim().toLowerCase())
          ? `slds-text-body_small ${cls}`
          : "slds-text-body_small",
      }));
    return {
      ...change,
      storedRows: mark(change.storedSteps, removed, "step-removed", "s"),
      liveRows: mark(change.liveSteps, added, "step-added", "l"),
      // Warn about a missing current step only when the live list is readable.
      showMissingStep: change.liveAvailable && !change.currentStepInLive,
      showLiveUnavailable: !change.liveAvailable,
      showStoredUnavailable: !change.storedAvailable,
    };
  }

  handleResumeRollback() {
    this.loadingDetails = true;
    resumeCompensationInstance({ instanceId: this.selectedInstanceId })
      .then(() => {
        this.showToast(
          "Success",
          "Rollback resumed. Remaining compensations will run in LIFO order.",
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to resume rollback: " + this.reduceErrors(error),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  // UTILITIES
  formatDateTime(dateStr) {
    if (!dateStr) return "";
    const d = new Date(dateStr);
    return d.toLocaleString();
  }

  formatJson(str) {
    if (!str) return "";
    try {
      const obj = JSON.parse(str);
      return JSON.stringify(obj, null, 2);
    } catch {
      return str; // Return raw string if not json
    }
  }

  _normalizeJson(payload) {
    if (!payload || !payload.trim()) {
      return "";
    }
    try {
      JSON.parse(payload);
      return payload;
    } catch {
      const normalized = payload
        .replace(/[\u201C\u201D]/g, '"')
        .replace(/[\u2018\u2019]/g, "'")
        .replace(/\u00A0/g, " ");
      try {
        JSON.parse(normalized);
        return normalized;
      } catch {
        return null;
      }
    }
  }

  // Turns a server payloadFiles descriptor into a render-ready download link, or null.
  // Present only for attachment-backed payloads whose full content was truncated above.
  buildPayloadFile(file) {
    if (!file || !file.downloadUrl) {
      return null;
    }
    const chars = file.fullLength || 0;
    const sizeLabel =
      chars >= 1024 ? Math.ceil(chars / 1024) + " KB" : chars + " chars";
    return {
      url: file.downloadUrl,
      label: "Download full payload (" + sizeLabel + ")",
    };
  }

  getStatusBadgeClass(status) {
    switch (status) {
      case "Completed":
        return "badge badge-green";
      case "ContinuedAsNew":
        return "badge badge-blue";
      case "Failed":
        return "badge badge-red";
      case "Suspended":
        return "badge badge-orange";
      case "Running":
        return "badge badge-blue pulse-glow";
      case "Pending":
        return "badge badge-grey";
      case "Retrying":
        return "badge badge-yellow pulse-glow";
      case "Compensating":
        return "badge badge-yellow pulse-glow";
      case "Compensated":
        return "badge badge-orange";
      case "CompensationFailed":
        return "badge badge-red pulse-glow";
      case "Cancelling":
        return "badge badge-yellow pulse-glow";
      case "Cancelled":
        return "badge badge-grey";
      case "Paused":
        return "badge badge-orange";
      case "DefinitionChanged":
        return "badge badge-purple";
      case "Held":
        return "badge badge-cyan";
      default:
        return "badge";
    }
  }

  getTimelineMarkerClass(status) {
    switch (status) {
      case "Completed":
        return "timeline-marker bg-green";
      case "ContinuedAsNew":
        return "timeline-marker bg-blue";
      case "Failed":
        return "timeline-marker bg-red";
      case "Retrying":
        return "timeline-marker bg-yellow";
      case "Running":
        return "timeline-marker bg-blue";
      case "Pending":
        return "timeline-marker bg-grey";
      case "Compensating":
        return "timeline-marker bg-yellow";
      case "Compensated":
        return "timeline-marker bg-orange";
      case "CompensationFailed":
        return "timeline-marker bg-red";
      case "Cancelling":
        return "timeline-marker bg-yellow";
      case "Cancelled":
        return "timeline-marker bg-grey";
      case "DefinitionChanged":
        return "timeline-marker bg-purple";
      default:
        return "timeline-marker";
    }
  }

  showToast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title: title,
        message: message,
        variant: variant,
      }),
    );
  }

  reduceErrors(error) {
    if (!error) return "Unknown error";
    if (error.body) {
      if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(", ");
      }
      if (typeof error.body.message === "string") {
        return error.body.message;
      }
    }
    if (typeof error.message === "string") {
      return error.message;
    }
    return JSON.stringify(error);
  }

  startPolling() {
    this.stopPolling();
    this.stopAutoRefresh();
    let attempts = 0;
    this.pollingInterval = setInterval(() => {
      attempts += 1;
      this.refreshInstances();
      if (attempts >= 10) {
        this.stopPolling();
      }
    }, 2000);
  }

  stopPolling(shouldResumeAutoRefresh = true) {
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
      this.pollingInterval = null;
      if (shouldResumeAutoRefresh) {
        this.startAutoRefresh();
      }
    }
  }

  startAutoRefresh() {
    this.stopAutoRefresh();
    this.autoRefreshInterval = setInterval(() => {
      // Keep the open Version Drain panel live so a version doesn't keep showing
      // "Safe to retire" after new in-flight instances start under it.
      if (this.viewingDrain) {
        this.loadDrain(true);
      }
      this.refreshInstances();
    }, 5000);
  }

  stopAutoRefresh() {
    if (this.autoRefreshInterval) {
      clearInterval(this.autoRefreshInterval);
      this.autoRefreshInterval = null;
    }
  }

  // ────────────────────────────────────────────────────────────────────────
  // PAUSE / RESUME
  // ────────────────────────────────────────────────────────────────────────

  handleOpenPauseModal(event) {
    const target = event.currentTarget.dataset.target || "";
    this.pauseModalTarget = target;
    this.pauseModalReason = "";
    this.pauseModalIsResume = false;
    this.pauseModalOpen = true;
  }

  handleOpenResumeModal(event) {
    const target = event.currentTarget.dataset.target || "";
    this.pauseModalTarget = target;
    this.pauseModalIsResume = true;
    this.pauseModalOpen = true;
  }

  handleClosePauseModal() {
    this.pauseModalOpen = false;
  }

  handlePauseReasonChange(event) {
    this.pauseModalReason = event.target.value;
  }

  handleConfirmPauseModal() {
    this.pauseModalOpen = false;
    this.loadingPause = true;
    if (this.pauseModalIsResume) {
      resumeDefinition({ workflowName: this.pauseModalTarget })
        .then(() => {
          const label =
            this.pauseModalTarget === "*"
              ? "all definitions"
              : this.pauseModalTarget;
          this.showToast(
            "Resumed",
            "Resumed " + label + ". Parked instances are re-queued.",
            "success",
          );
          this.loadDoctorStatus();
          this.refreshInstances();
        })
        .catch((error) => {
          this.showToast(
            "Error",
            "Resume failed: " + this.reduceErrors(error),
            "error",
          );
        })
        .finally(() => {
          this.loadingPause = false;
        });
    } else {
      pauseDefinition({
        workflowName: this.pauseModalTarget,
        reason: this.pauseModalReason,
      })
        .then(() => {
          const label =
            this.pauseModalTarget === "*"
              ? "all definitions"
              : this.pauseModalTarget;
          this.showToast(
            "Paused",
            "Paused " + label + ". New steps will park at the chain handoff.",
            "success",
          );
          this.loadDoctorStatus();
          this.refreshInstances();
        })
        .catch((error) => {
          this.showToast(
            "Error",
            "Pause failed: " + this.reduceErrors(error),
            "error",
          );
        })
        .finally(() => {
          this.loadingPause = false;
        });
    }
  }

  get hasPausedDefinitions() {
    return (
      this.doctorData &&
      this.doctorData.pausedDefinitions &&
      this.doctorData.pausedDefinitions.length > 0
    );
  }

  get pausedDefinitions() {
    return (this.doctorData && this.doctorData.pausedDefinitions) || [];
  }
}
