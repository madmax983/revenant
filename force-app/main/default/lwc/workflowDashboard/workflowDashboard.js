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
import getPausedDefinitions from "@salesforce/apex/WorkflowDashboardController.getPausedDefinitions";
import getConcurrencyStatus from "@salesforce/apex/WorkflowDashboardController.getConcurrencyStatus";

export default class WorkflowDashboard extends LightningElement {
  instances = [];
  filteredInstances = [];
  definitions = [];
  stats = { total: 0, active: 0, completed: 0, failed: 0 };

  // UI state
  selectedInstanceId;
  // Raw getInstanceDetails payload handed straight to <c-workflow-instance-detail>,
  // which owns all detail view-model shaping and rendering.
  rawDetail;
  loadingDetails = false;
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

  // Pagination & Filters State
  selectedWorkflow = "";
  selectedStatus = "";
  limitSize = 50;
  offsetSize = 0;
  hasMore = true;
  loadingMore = false;
  cacheBuster = "";
  redriving = false;

  // Stalled-instance filter
  showingStalled = false;
  stalledCountData = { count: 0, capped: false };

  // Confirmation modals
  redriveModalOpen = false;
  redriveCount = 0;
  cancelModalOpen = false;
  redriveSnapshotName;
  redriveSnapshotStatus;
  redriveSnapshotSearchTerm;

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

  connectedCallback() {
    this.fetchInstances(false);
    this.startAutoRefresh();
  }

  disconnectedCallback() {
    this.stopPolling();
    this.stopAutoRefresh();
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

  // The instance-detail view-model (steps, children, badges, cancelability,
  // compensation stack, etc.) now lives in <c-workflow-instance-detail>, which is
  // fed the raw getInstanceDetails payload via the rawDetail property below.

  fetchInstances(isAppend) {
    if (!isAppend) {
      this.offsetSize = 0;
      this.hasMore = true;
      this.loadingMore = false;
      this.cacheBuster = Date.now().toString();
    }

    const currentOffset = this.offsetSize;
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
          limitSize: currentLimit,
          offsetSize: currentOffset,
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
    });

    const unroutedCountPromise = getUnroutedSignalCount({ searchTerm: null });

    return Promise.all([
      instancesPromise,
      statsPromise,
      stalledCountPromise,
      unroutedCountPromise,
    ])
      .then(([result, statsResult, stalledResult, unroutedResult]) => {
        const formatted = result.map((inst) => this.formatInstance(inst));

        if (isAppend) {
          this.instances = [...this.instances, ...formatted];
        } else {
          this.instances = formatted;
        }

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
        if (this.selectedInstanceId && !isAppend) {
          this.loadDetails(false);
        }
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to retrieve workflow instances: " +
            (error.body ? error.body.message : error.message),
          "error",
        );
      })
      .finally(() => {
        this.loadingMore = false;
        this.loadingDetails = false;
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
    });

    const unroutedCountPromise = getUnroutedSignalCount({ searchTerm: null });

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
        console.error("Error refreshing instances:", error);
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
    this.selectedWorkflow = event.target.value;
    this.fetchInstances(false);
  }

  handleStatusFilterChange(event) {
    this.selectedStatus = event.target.value;
    this.fetchInstances(false);
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
    return this.showingStalled ? "Show All" : "Show Stalled";
  }

  get stalledFilterVariant() {
    return this.showingStalled ? "brand" : "neutral";
  }

  formatInstance(inst) {
    const idleLabel =
      inst.idleMinutes != null ? `${inst.idleMinutes}m idle` : null;
    return {
      ...inst,
      formattedDate: this.formatDateTime(inst.CreatedDate),
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
    this.offsetSize += this.limitSize;
    this.fetchInstances(true);
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
    // Fired by <c-workflow-instance-detail> as a 'selectrelated' CustomEvent
    // carrying the related instance Id in event.detail.id.
    const relatedId = event.detail ? event.detail.id : null;
    if (!relatedId) {
      return;
    }
    this.stopPolling();
    this.viewingDoctor = false;
    this.selectedInstanceId = relatedId;
    this.filterInstancesList();
    this.loadDetails(true);
  }

  loadDetails(showSpinner) {
    if (showSpinner) {
      this.loadingDetails = true;
      this.rawDetail = undefined;
    }
    const currentInstanceId = this.selectedInstanceId;
    getInstanceDetails({ instanceId: currentInstanceId })
      .then((result) => {
        if (currentInstanceId !== this.selectedInstanceId) {
          return;
        }
        // <c-workflow-instance-detail> shapes its own view-model from the raw
        // payload; the dashboard just hands it over and keeps the poll-stop logic.
        this.rawDetail = result;

        const steps = result.steps || [];
        const isStillWaitingForApproval = steps.some((step) => {
          if (!step.Output__c) {
            return false;
          }
          try {
            return !!JSON.parse(step.Output__c).waitingForApproval;
          } catch (e) {
            return false;
          }
        });
        const status = result.instance ? result.instance.Status__c : null;
        const isTransitioning =
          status === "Running" ||
          status === "Compensating" ||
          status === "Cancelling";
        if (!isStillWaitingForApproval && !isTransitioning) {
          this.stopPolling();
        }
      })
      .catch((error) => {
        if (currentInstanceId === this.selectedInstanceId) {
          this.showToast(
            "Error",
            "Failed to retrieve details: " + error.body.message,
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

  handleRefresh() {
    if (this.viewingDrain) {
      this.loadDrain(true);
    }
    this.refreshInstances().then(() => {
      this.showToast("Success", "Workflow dashboard refreshed", "success");
    });
  }

  handleOpenDoctor() {
    this.viewingDoctor = true;
    this.viewingDrain = false;
    this.viewingUnrouted = false;
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
    this.selectedInstanceId = null;
    this.filterInstancesList();
    this.loadUnroutedSignals();
  }

  handleCloseUnrouted() {
    this.viewingUnrouted = false;
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
            message: err.body ? err.body.message : String(err),
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
            message: err.body ? err.body.message : String(err),
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
          "Failed to load version drain: " +
            (error.body ? error.body.message : error.message),
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
    getWatchdogStatus()
      .then((result) => {
        let latestJobVal = null;
        if (result.latestJob) {
          latestJobVal = {
            ...result.latestJob,
            statusBadgeClass: this.getStatusBadgeClass(
              result.latestJob.Status__c,
            ),
          };
        }
        this.doctorData = {
          ...result,
          latestJob: latestJobVal,
          latestJobCreatedDate: result.latestJob
            ? this.formatDateTime(result.latestJob.CreatedDate)
            : null,
        };
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to load doctor status: " +
            (error.body ? error.body.message : error.message),
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
      .catch(() => {
        // Concurrency panel is best-effort; never block the System Doctor view.
        this.concurrencyRows = [];
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
          "Failed to enqueue watchdog: " +
            (error.body ? error.body.message : error.message),
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
      } catch (_) {
        // First parse failed. Try normalizing common paste artifacts — but only as
        // a fallback so valid JSON is never rewritten:
        //   · typographic (“curly”) quotes from Word / macOS autocorrect
        //   · non-breaking spaces ( ) from Word / Google Docs / some chat
        //     renderers; they look identical to spaces but are invalid JSON whitespace
        const normalized = payload
          .replace(/[\u201C\u201D]/g, '"')
          .replace(/[\u2018\u2019]/g, "'")
          .replace(/\u00A0/g, " ");
        try {
          JSON.parse(normalized);
          payload = normalized;
        } catch (ex) {
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
        this.launchError = "Failed to execute workflow: " + error.body.message;
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
          "Failed to retry workflow: " + error.body.message,
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
  get canRedriveMatching() {
    return (
      this.stats &&
      this.stats.failed > 0 &&
      !this.redriving &&
      !this.showingStalled
    );
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
          "Failed to count re-drive candidates: " +
            (error.body ? error.body.message : error.message),
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
          "Failed to re-drive matching instances: " +
            (error.body ? error.body.message : error.message),
          "error",
        );
      })
      .finally(() => {
        this.redriving = false;
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
          "Failed to cancel workflow: " +
            (error.body ? error.body.message : error.message),
          "error",
        );
      })
      .finally(() => {
        this.loadingDetails = false;
      });
  }

  handleApprovalSubmit(event) {
    // Fired by <c-workflow-instance-detail> as an 'approvalsubmit' CustomEvent
    // carrying { approvalKey, approved, comments } in event.detail.
    const { approvalKey, approved, comments } = event.detail || {};

    this.loadingDetails = true;
    submitApproval({
      instanceId: this.selectedInstanceId,
      approvalKey: approvalKey,
      approved: approved,
      comments: comments,
    })
      .then(() => {
        this.showToast(
          "Success",
          `Approval decision (${approved ? "Approve" : "Reject"}) submitted successfully.`,
          "success",
        );
        this.refreshInstances();
        this.loadDetails(true);
        this.startPolling();
      })
      .catch((error) => {
        this.showToast(
          "Error",
          "Failed to submit approval: " + error.body.message,
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
          "Failed to resume workflow: " +
            (error.body ? error.body.message : error.message),
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
          "Failed to resume rollback: " +
            (error.body ? error.body.message : error.message),
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

  showToast(title, message, variant) {
    this.dispatchEvent(
      new ShowToastEvent({
        title: title,
        message: message,
        variant: variant,
      }),
    );
  }

  startPolling() {
    this.stopPolling();
    let attempts = 0;
    this.pollingInterval = setInterval(() => {
      attempts += 1;
      this.refreshInstances();
      if (attempts >= 10) {
        this.stopPolling();
      }
    }, 2000);
  }

  stopPolling() {
    if (this.pollingInterval) {
      clearInterval(this.pollingInterval);
      this.pollingInterval = null;
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
    // Triggered both by list/stalled buttons (dataset.target) and by the detail
    // child's 'pausedefinition' CustomEvent (event.detail.target).
    const target =
      (event.detail && event.detail.target) ||
      (event.currentTarget &&
        event.currentTarget.dataset &&
        event.currentTarget.dataset.target) ||
      "";
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
            "Resume failed: " +
              (error.body ? error.body.message : error.message),
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
            "Pause failed: " +
              (error.body ? error.body.message : error.message),
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
