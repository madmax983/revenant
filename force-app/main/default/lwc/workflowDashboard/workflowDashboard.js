/* eslint-disable @lwc/lwc/no-async-operation */
import { LightningElement, wire } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import getFilteredInstances from "@salesforce/apex/WorkflowDashboardController.getFilteredInstances";
import getWorkflowStats from "@salesforce/apex/WorkflowDashboardController.getWorkflowStats";
import getInstanceDetails from "@salesforce/apex/WorkflowDashboardController.getInstanceDetails";
import getDefinitions from "@salesforce/apex/WorkflowDashboardController.getDefinitions";
import startWorkflow from "@salesforce/apex/WorkflowDashboardController.startWorkflow";
import retryWorkflowInstance from "@salesforce/apex/WorkflowDashboardController.retryWorkflowInstance";
import getRedriveEligibleCount from "@salesforce/apex/WorkflowDashboardController.getRedriveEligibleCount";
import redriveMatchingInstances from "@salesforce/apex/WorkflowDashboardController.redriveMatchingInstances";
import getCancelEligibleCount from "@salesforce/apex/WorkflowDashboardController.getCancelEligibleCount";
import cancelMatchingInstances from "@salesforce/apex/WorkflowDashboardController.cancelMatchingInstances";
import resumeWorkflowInstance from "@salesforce/apex/WorkflowDashboardController.resumeWorkflowInstance";
import resumeCompensationInstance from "@salesforce/apex/WorkflowDashboardController.resumeCompensationInstance";
import cancelWorkflow from "@salesforce/apex/WorkflowDashboardController.cancelWorkflow";
import submitApproval from "@salesforce/apex/WorkflowDashboardController.submitApproval";
import getWatchdogStatus from "@salesforce/apex/WorkflowDashboardController.getWatchdogStatus";
import enqueueWatchdog from "@salesforce/apex/WorkflowDashboardController.enqueueWatchdog";
import getStalledInstances from "@salesforce/apex/WorkflowDashboardController.getStalledInstances";
import getStalledCount from "@salesforce/apex/WorkflowDashboardController.getStalledCount";
import getVersionDrain from "@salesforce/apex/WorkflowDashboardController.getVersionDrain";
import getUnroutedSignals from "@salesforce/apex/WorkflowDashboardController.getUnroutedSignals";
import getUnroutedSignalCount from "@salesforce/apex/WorkflowDashboardController.getUnroutedSignalCount";
import redeliverSignal from "@salesforce/apex/WorkflowDashboardController.redeliverSignal";
import pauseDefinition from "@salesforce/apex/WorkflowDashboardController.pauseDefinition";
import resumeDefinition from "@salesforce/apex/WorkflowDashboardController.resumeDefinition";
import getConcurrencyStatus from "@salesforce/apex/WorkflowDashboardController.getConcurrencyStatus";
import getDefinitionTrends from "@salesforce/apex/WorkflowDashboardController.getDefinitionTrends";
import getWorkflowFailureBreakdown from "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown";
import compensateWorkflow from "@salesforce/apex/WorkflowDashboardController.compensateWorkflow";
import injectSignal from "@salesforce/apex/WorkflowDashboardController.injectSignal";

const FAILURE_CATEGORY_LABELS = {
  STEP_EXCEPTION: "Step Exception",
  RETRIES_EXHAUSTED: "Retries Exhausted",
  TIMEOUT: "Timeout",
  COMPENSATION_FAILED: "Compensation Failed",
  EXPLICIT_FAIL: "Explicit Step Failure",
  UNKNOWN: "Unknown",
};

const ASYNC_LIMITS = {
  CPU: 60000,
  SOQL: 200,
  HEAP: 12000000
};

export default class WorkflowDashboard extends LightningElement {
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
  approvalComments = "";
  modalOpen = false;
  searchTerm = "";
  viewingDoctor = false;
  loadingDoctor = false;
  doctorData = { config: {} };
  concurrencyRows = [];

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
  // Stable option array (see note above workflowOptions on why getters are avoided).
  trendWindowOptions = [
    { label: "Last 1 hour", value: "1h" },
    { label: "Last 24 hours", value: "24h" },
    { label: "Last 7 days", value: "7d" },
  ];

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
  ];

  failureCategoryOptions = [
    { label: "-- All Categories --", value: "" },
    { label: "Step Exception", value: "STEP_EXCEPTION" },
    { label: "Retries Exhausted", value: "RETRIES_EXHAUSTED" },
    { label: "Timeout", value: "TIMEOUT" },
    { label: "Compensation Failed", value: "COMPENSATION_FAILED" },
    { label: "Explicit Step Failure", value: "EXPLICIT_FAIL" },
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

  get hasBreakdownRows() {
    return (
      this.breakdownData &&
      this.breakdownData.steps &&
      this.breakdownData.steps.length > 0
    );
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

  get isFailed() {
    return this.selectedInst && this.selectedInst.Status__c === "Failed";
  }

  get isRollbackIncomplete() {
    return (
      this.selectedInst && this.selectedInst.Status__c === "CompensationFailed"
    );
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
      status === "CompensationFailed"
    );
  }

  get isSuspended() {
    return this.selectedInst && this.selectedInst.Status__c === "Suspended";
  }

  get isSendSignalDisabled() {
    return !this.signalName || !this.signalName.trim() || this.loadingDetails;
  }

  fetchInstances(isAppend, targetOffset) {
    const requestId = ++this._instanceRequestId;
    if (!isAppend) {
      this.offsetSize = 0;
      this.hasMore = true;
      this.loadingMore = false;
      this.cacheBuster = Date.now().toString();
    }

    const currentOffset = isAppend ? (targetOffset || this.offsetSize) : 0;
    const currentLimit = this.limitSize;

    if (isAppend) {
      this.loadingMore = true;
    } else {
      this.loadingDetails = true;
    }

    const instancesPromise = this.showingStalled
      ? getStalledInstances({
          workflowName: this.selectedWorkflow,
          searchTerm: this.searchTerm,
          thresholdMinutes: null,
          limitSize: currentLimit,
          offsetSize: currentOffset,
          cacheBuster: this.cacheBuster,
        })
      : getFilteredInstances({
          workflowName: this.selectedWorkflow,
          status: this.selectedStatus,
          searchTerm: this.searchTerm,
          failureCategory: this.selectedFailureCategory,
          limitSize: currentLimit,
          offsetSize: currentOffset,
          cacheBuster: this.cacheBuster,
        });

    if (isAppend) {
      return instancesPromise
        .then((result) => {
          if (!this._isConnected || requestId !== this._instanceRequestId) return;
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

    const statsPromise = getWorkflowStats({
      workflowName: this.selectedWorkflow,
      status: this.selectedStatus,
      searchTerm: this.searchTerm,
    });

    const stalledCountPromise = getStalledCount({
      workflowName: this.selectedWorkflow,
      searchTerm: this.searchTerm,
      thresholdMinutes: null,
    }).catch((error) => {
      console.error("Stalled count query failed:", error);
      return { count: 0, capped: false };
    });

    const unroutedCountPromise = getUnroutedSignalCount({ searchTerm: null })
      .catch((error) => {
        console.error("Unrouted signal count query failed:", error);
        return { count: 0, capped: false };
      });

    return Promise.all([
      instancesPromise,
      statsPromise,
      stalledCountPromise,
      unroutedCountPromise,
    ])
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
    const currentSize =
      this.instances.length > 0 ? this.instances.length : this.limitSize;
    this.cacheBuster = Date.now().toString();

    const listEl = this.template.querySelector(".slds-scrollable_y");
    const savedScrollTop = listEl ? listEl.scrollTop : 0;

    const instancesPromise = this.showingStalled
      ? getStalledInstances({
          workflowName: this.selectedWorkflow,
          searchTerm: this.searchTerm,
          thresholdMinutes: null,
          limitSize: currentSize,
          offsetSize: 0,
          cacheBuster: this.cacheBuster,
        })
      : getFilteredInstances({
          workflowName: this.selectedWorkflow,
          status: this.selectedStatus,
          searchTerm: this.searchTerm,
          failureCategory: this.selectedFailureCategory,
          limitSize: currentSize,
          offsetSize: 0,
          cacheBuster: this.cacheBuster,
        });

    const statsPromise = getWorkflowStats({
      workflowName: this.selectedWorkflow,
      status: this.selectedStatus,
      searchTerm: this.searchTerm,
    });

    const stalledCountPromise = getStalledCount({
      workflowName: this.selectedWorkflow,
      searchTerm: this.searchTerm,
      thresholdMinutes: null,
    }).catch((error) => {
      console.error("Stalled count query failed:", error);
      return { count: 0, capped: false };
    });

    const unroutedCountPromise = getUnroutedSignalCount({ searchTerm: null })
      .catch((error) => {
        console.error("Unrouted signal count query failed:", error);
        return { count: 0, capped: false };
      });

    return Promise.all([
      instancesPromise,
      statsPromise,
      stalledCountPromise,
      unroutedCountPromise,
    ])
      .then(([result, statsResult, stalledResult, unroutedResult]) => {
        this.instances = result.map((inst) => this.formatInstance(inst));
        this.stats = statsResult;
        this.stalledCountData = stalledResult || { count: 0, capped: false };
        this.unroutedCountData = unroutedResult || { count: 0, capped: false };
        this.filterInstancesList();

        if (this.selectedInstanceId) {
          this.loadDetails(false);
        }

        // Restore scroll position after LWC reconciles the list DOM
        requestAnimationFrame(() => {
          const el = this.template.querySelector(".slds-scrollable_y");
          if (el) el.scrollTop = savedScrollTop;
        });
      })
      .catch((error) => {
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
    return {
      ...inst,
      formattedDate: this.formatDateTime(inst.CreatedDate),
      formattedDeadline: inst.Deadline_At__c
        ? this.formatDateTime(inst.Deadline_At__c)
        : null,
      listItemClass: `slds-p-around_small list-item clickable ${this.selectedInstanceId === inst.Id ? "item-selected" : ""}`,
      statusBadgeClass: this.getStatusBadgeClass(inst.Status__c),
      isWatchdogWaiting: inst.waitingOn === "Watchdog",
      waitingOnBadgeClass:
        inst.waitingOn === "Watchdog"
          ? "badge badge-purple"
          : inst.waitingOn === "Delayed Queueable"
            ? "badge badge-indigo"
            : "badge badge-blue",
      stalledBadgeClass: inst.stalled ? "badge badge-red" : null,
      formattedIdleMinutes: idleLabel,
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
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.selectedInstanceId = event.currentTarget.dataset.id;
    this.filterInstancesList();
    this.loadDetails(true);
  }

  handleSelectRelatedInstance(event) {
    this.stopPolling();
    this.viewingDoctor = false;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
    this.viewingFailureBreakdown = false;
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
          return;
        }
        const inst = result.instance;
        const payloadFiles = result.payloadFiles || {};
        this.successor = result.successor;
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
          progressFile: this.buildPayloadFile(payloadFiles["instance.Progress"]),
          waitingOn: result.waitingOn,
          isWatchdogWaiting: result.waitingOn === "Watchdog",
          waitingOnBadgeClass:
            result.waitingOn === "Watchdog"
              ? "badge badge-purple"
              : result.waitingOn === "Delayed Queueable"
                ? "badge badge-indigo"
                : "badge badge-blue",
          pendingCompensationCount: result.pendingCompensationCount || 0,
          pendingCompensations: result.pendingCompensations || [],
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

          let hasTelemetry = cpu !== undefined && cpu !== null;
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
            formattedRetryCount: step.Retry_Count__c !== undefined && step.Retry_Count__c !== null ? step.Retry_Count__c : "—",
            budgetClass: hasLimitPressure
              ? "text-red slds-text-title_bold"
              : "slds-text-color_weak",
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
    this.selectedInstanceId = null;
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
    this.selectedInstanceId = null;
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
    this.selectedInstanceId = null;
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
    this.selectedInstanceId = null;
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
    this.selectedInstanceId = null;
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

  loadUnroutedSignals() {
    this.loadingUnrouted = true;
    const buster = new Date().getTime().toString();
    Promise.all([
      getUnroutedSignals({
        searchTerm: null,
        limitSize: 50,
        offsetSize: 0,
        cacheBuster: buster,
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
        this.doctorData = result ? {
          ...result,
          latestJob: latestJobVal,
          latestJobCreatedDate: result.latestJob
            ? this.formatDateTime(result.latestJob.CreatedDate)
            : null,
        } : { config: {} };
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
        }));
      })
      .catch((error) => {
        // Concurrency panel is best-effort; never block the System Doctor view.
        this.concurrencyRows = [];
        console.error("Failed to load concurrency status:", this.reduceErrors(error));
      });
  }

  get hasConcurrencyRows() {
    return this.concurrencyRows && this.concurrencyRows.length > 0;
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
      let payload = this.launchInputJson;
      try {
        JSON.parse(payload);
      } catch {
        // First parse failed. Try normalizing common paste artifacts — but only as
        // a fallback so valid JSON is never rewritten:
        //   · typographic (“curly”) quotes from Word / macOS autocorrect
        //   · non-breaking spaces (\u00A0) from Word / Google Docs / some chat
        //     renderers; they look identical to spaces but are invalid JSON whitespace
        const normalized = payload
          .replace(/[\u201C\u201D]/g, '"')
          .replace(/[\u2018\u2019]/g, "'")
          .replace(/\u00A0/g, " ");
        try {
          JSON.parse(normalized);
          payload = normalized;
        } catch {
          this.launchError =
            "Input Payload must be valid JSON. " +
            "If you pasted from a chat or document, re-type the quote characters — " +
            "“curly quotes” are not valid JSON.";
          return;
        }
      }
      this.launchInputJson = payload;
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
        this.launchError = "Failed to execute workflow: " + this.reduceErrors(error);
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

  // Enable bulk re-drive only when the current filter actually contains failed
  // (recoverable) instances and the stalled view is not active (stalled rows are
  // Suspended, not Failed; showing the button there would re-drive hidden failures).
  get isRedriveDisabled() {
    return !this.stats || this.stats.failed === 0 || this.redriving || this.showingStalled;
  }

  get redriveButtonLabel() {
    return `Re-drive (${this.stats ? this.stats.failed : 0})`;
  }

  get isCancelDisabled() {
    return !this.stats || this.stats.active === 0 || this.cancellingMatching || this.showingStalled;
  }

  get cancelButtonLabel() {
    return this.cancellingMatching ? "Counting..." : `Cancel (${this.stats ? this.stats.active : 0})`;
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
      runCompensations: false,
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
      instanceId: this.selectedInstanceId,
      runCompensations,
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
    this.signalName = "";
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
      const textarea = this.template.querySelector('[data-id="signal-payload-input"]');
      try {
        JSON.parse(this.signalPayload);
        if (textarea) {
          textarea.setCustomValidity("");
          textarea.reportValidity();
        }
      } catch {
        if (textarea) {
          textarea.setCustomValidity("Invalid JSON format.");
          textarea.reportValidity();
        }
        return;
      }
    } else {
      const textarea = this.template.querySelector('[data-id="signal-payload-input"]');
      if (textarea) {
        textarea.setCustomValidity("");
        textarea.reportValidity();
      }
    }

    this.loadingDetails = true;
    injectSignal({
      instanceId: this.selectedInstanceId,
      signalName: this.signalName,
      payloadJson: this.signalPayload
    })
      .then(() => {
        this.signalModalOpen = false;
        this.showToast(
          "Signal Sent",
          "Signal injected successfully.",
          "success"
        );
        this.loadDetails(true);
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to inject signal: " + this.reduceErrors(error),
          "error"
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
      instanceId: this.selectedInstanceId,
      approvalKey: approvalKey,
      approved: approved,
      comments: this.approvalComments,
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
    if (!error) return 'Unknown error';
    if (error.body) {
      if (Array.isArray(error.body)) {
        return error.body.map(e => e.message).join(', ');
      }
      if (typeof error.body.message === 'string') {
        return error.body.message;
      }
    }
    if (typeof error.message === 'string') {
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
