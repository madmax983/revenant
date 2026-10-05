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
      "Find the jobs that use async capacity (Setup > Apex Jobs). Start fewer new instances. Move batch work to a later time.",
  },
  CRITICAL: {
    label: "Critical",
    badgeClass: "slds-badge slds-theme_error",
    action:
      "Pause definitions that are not critical. Stop or move batch jobs. When capacity is normal again, look for orphaned instances.",
  },
};
const STATUS_UNKNOWN = {
  label: "Unknown",
  badgeClass: "slds-badge",
  action:
    "Capacity data is not available. Examine the org limits (sf org list limits) and Setup > Apex Jobs.",
};

const MISSING = "—";
const isMissing = (value) => value === null || value === undefined;
const formatCount = (value) =>
  isMissing(value) ? MISSING : Number(value).toLocaleString();
// Own keys only, so a status such as "toString" gives Unknown.
const statusFor = (code) =>
  Object.prototype.hasOwnProperty.call(STATUS, code)
    ? STATUS[code]
    : STATUS_UNKNOWN;

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

  // Null-safe view of the envelope. The getters do not throw when there is no data.
  get data() {
    return this.capacity || {};
  }

  get overall() {
    return statusFor(this.data.status);
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
    return this.data.chainAtRisk === true;
  }

  get metricRows() {
    const metrics = Array.isArray(this.data.metrics) ? this.data.metrics : [];
    return metrics.filter(Boolean).map((m, index) => {
      const status = statusFor(m.status);
      const hasPercent = !isMissing(m.percent);
      return {
        key: m.key || `metric-${index}`,
        label: m.label,
        isElastic: m.elastic === true,
        usageLabel: `${formatCount(m.used)} / ${formatCount(m.limit)}`,
        // A capped read or a batch job with no size gives a lower bound.
        percentLabel: hasPercent
          ? `${m.lowerBound === true || m.capped === true ? "≥ " : ""}${
              m.percent
            }%`
          : MISSING,
        barValue: hasPercent ? Math.min(Number(m.percent), 100) : 0,
        statusLabel: status.label,
        badgeClass: status.badgeClass,
      };
    });
  }

  get jobCountsLabel() {
    const jobs = this.data.jobCounts || {};
    if (isMissing(jobs.total)) {
      return "AsyncApexJob counts are not available.";
    }
    const flexLimit = isMissing(jobs.flexQueueLimit)
      ? 100
      : jobs.flexQueueLimit;
    let label = `Flex queue (Holding) ${formatCount(jobs.holding)} / ${formatCount(
      flexLimit,
    )} · Queued ${formatCount(
      jobs.queued,
    )} · Processing ${formatCount(jobs.processing)}`;
    if (!isMissing(jobs.preparing)) {
      label += ` · Preparing ${formatCount(jobs.preparing)}`;
    }
    label += ` · Total ${formatCount(jobs.total)}`;
    if (!isMissing(jobs.pendingExecutions)) {
      label += ` · Pending executions ${formatCount(jobs.pendingExecutions)}`;
    }
    return label;
  }

  get isJobsCapped() {
    return !!(this.data.jobCounts && this.data.jobCounts.capped === true);
  }

  get unsizedBatchesLabel() {
    const count = Number((this.data.jobCounts || {}).unsizedBatches) || 0;
    if (count <= 0) {
      return null;
    }
    const jobs =
      count === 1 ? "1 batch job" : `${formatCount(count)} batch jobs`;
    return `${jobs} did not start. The chunk count is not known, so the pending executions are a lower bound.`;
  }

  get thresholdLabel() {
    const { warnPercent, critPercent } = this.data;
    if (isMissing(warnPercent) || isMissing(critPercent)) {
      return "Thresholds are not available.";
    }
    return `Degraded at ${warnPercent}% · Critical at ${critPercent}%`;
  }

  get isInvalidConfig() {
    return this.data.thresholdSource === "INVALID";
  }

  get asOfLabel() {
    return this.data.asOfMs
      ? `As of ${new Date(this.data.asOfMs).toLocaleTimeString()}`
      : "";
  }
}
