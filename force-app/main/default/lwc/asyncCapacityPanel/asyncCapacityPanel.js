/**
 * Async Apex Capacity panel for System Doctor (#129). It shows the daily async Apex
 * executions and the flex queue as percent used, with a Healthy / Degraded / Critical
 * status. Apex sets the statuses. This component only adds labels. It reads once on
 * connect. System Doctor creates it again on each refresh.
 */
import { LightningElement } from "lwc";
import getAsyncCapacity from "@salesforce/apex/WorkflowAsyncCapacityController.getAsyncCapacity";

const STATUS = {
  HEALTHY: {
    label: "Healthy",
    badgeClass: "slds-badge slds-theme_success",
    action: "No action is necessary.",
  },
  DEGRADED: {
    label: "Degraded",
    badgeClass: "slds-badge slds-theme_warning",
    action:
      "Find the jobs that use async capacity (Setup > Apex Jobs). Decrease new starts or move batch work to a later time.",
  },
  CRITICAL: {
    label: "Critical",
    badgeClass: "slds-badge slds-theme_error",
    action:
      "Pause definitions that are not critical. Stop or move batch jobs. After recovery, look for orphaned instances.",
  },
};
const STATUS_UNKNOWN = {
  label: "Unknown",
  badgeClass: "slds-badge",
  action:
    "Capacity data is not available. Examine the org limits (sf org list limits) and Setup > Apex Jobs.",
};

const isMissing = (value) => value === null || value === undefined;
const formatCount = (value) =>
  isMissing(value) ? "—" : Number(value).toLocaleString();

export default class AsyncCapacityPanel extends LightningElement {
  capacity = null;
  error = null;
  loaded = false;

  connectedCallback() {
    this.load();
  }

  load() {
    getAsyncCapacity()
      .then((result) => {
        if (!result || !Array.isArray(result.metrics)) {
          this.setError("No data was returned.");
          return;
        }
        this.capacity = result;
        this.error = null;
        this.loaded = true;
      })
      .catch((err) => {
        this.setError(this.reduceError(err));
      });
  }

  setError(reason) {
    this.capacity = null;
    this.error = reason;
    this.loaded = true;
  }

  reduceError(err) {
    if (err && err.body && err.body.message) {
      return err.body.message;
    }
    return (err && err.message) || "Unknown error";
  }

  get isLoading() {
    return !this.loaded;
  }

  get hasData() {
    return !!this.capacity;
  }

  get overall() {
    return STATUS[this.capacity && this.capacity.status] || STATUS_UNKNOWN;
  }

  get statusLabel() {
    return this.overall.label;
  }

  get statusBadgeClass() {
    return this.overall.badgeClass;
  }

  get actionText() {
    return this.overall.action;
  }

  get chainAtRisk() {
    return !!(this.capacity && this.capacity.chainAtRisk === true);
  }

  get metricRows() {
    return (this.capacity.metrics || []).map((m) => {
      const status = STATUS[m.status] || STATUS_UNKNOWN;
      const hasPercent = !isMissing(m.percent);
      return {
        key: m.key,
        label: m.label,
        usageLabel: `${formatCount(m.used)} / ${formatCount(m.limit)}`,
        percentLabel: hasPercent ? `${m.percent}%` : "N/A",
        barValue: hasPercent ? Math.min(Number(m.percent), 100) : 0,
        statusLabel: status.label,
        badgeClass: status.badgeClass,
      };
    });
  }

  get jobCountsLabel() {
    const jobs = this.capacity.jobCounts || {};
    if (isMissing(jobs.total)) {
      return "AsyncApexJob counts are not available.";
    }
    return `Holding ${formatCount(jobs.holding)} · Queued ${formatCount(
      jobs.queued,
    )} · Processing ${formatCount(jobs.processing)} · Total ${formatCount(
      jobs.total,
    )}`;
  }

  get thresholdLabel() {
    return `Degraded at ${this.capacity.warnPercent}% · Critical at ${this.capacity.critPercent}%`;
  }

  get isInvalidConfig() {
    return this.capacity.thresholdSource === "INVALID";
  }

  get asOfLabel() {
    return this.capacity.asOfMs
      ? `As of ${new Date(this.capacity.asOfMs).toLocaleTimeString()}`
      : "";
  }
}
