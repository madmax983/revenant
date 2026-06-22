import { LightningElement, api } from "lwc";

/**
 * Presentational, self-contained view of a single Workflow_Instance__c detail
 * payload (the shape returned by WorkflowDashboardController.getInstanceDetails).
 *
 * It owns NO Apex and performs NO mutations. Write affordances (resume, retry,
 * resume-rollback, pause, cancel, approval) are rendered only when `readOnly` is
 * false and are surfaced to the host as semantic CustomEvents — the host decides
 * what (if anything) to do. In `readOnly` mode (the record page, Issue #46) the
 * action controls are not rendered at all, so the component is pure visibility.
 *
 * Reused by both the standalone workflowDashboard ops console and the record-page
 * recordWorkflowInstances component so the timeline UI lives in exactly one place.
 */
export default class WorkflowInstanceDetail extends LightningElement {
  @api readOnly = false;

  selectedInst;
  steps = [];
  childInstances = [];
  successor;
  approvalComments = "";

  _detail;

  @api
  get detail() {
    return this._detail;
  }
  set detail(value) {
    this._detail = value;
    this.applyDetail(value);
  }

  // ---- view-model shaping (ported verbatim from the dashboard's loadDetails) ----
  applyDetail(result) {
    if (!result || !result.instance) {
      this.selectedInst = undefined;
      this.steps = [];
      this.childInstances = [];
      this.successor = undefined;
      return;
    }

    const inst = result.instance;
    const payloadFiles = result.payloadFiles || {};
    this.successor = result.successor;
    this.selectedInst = {
      ...inst,
      formattedDate: this.formatDateTime(inst.CreatedDate),
      statusBadgeClass: this.getStatusBadgeClass(inst.Status__c),
      Input__c: this.formatJson(inst.Input__c),
      Output__c: this.formatJson(inst.Output__c),
      inputFile: this.buildPayloadFile(payloadFiles["instance.Input"]),
      outputFile: this.buildPayloadFile(payloadFiles["instance.Output"]),
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

    this.childInstances = (result.children || []).map((child) => {
      return {
        ...child,
        formattedDate: this.formatDateTime(child.CreatedDate),
        statusBadgeClass: this.getStatusBadgeClass(child.Status__c),
      };
    });

    // Preserve per-step "Show Logs" toggle state across re-sets (the dashboard
    // re-feeds detail on every poll, and we don't want the panel to collapse).
    const showDetailsMap = new Map();
    this.steps.forEach((s) => showDetailsMap.set(s.Id, s.showDetails));

    this.steps = (result.steps || []).map((step) => {
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
        } catch (e) {
          // ignore non-json
        }
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
        childInstanceName: childWorkflowLink ? childWorkflowLink.name : null,
        Input__c: this.formatJson(step.Input__c),
        Output__c: this.formatJson(step.Output__c),
        inputFile: this.buildPayloadFile(
          payloadFiles["step." + step.Id + ".Input"],
        ),
        outputFile: this.buildPayloadFile(
          payloadFiles["step." + step.Id + ".Output"],
        ),
      };
    });
  }

  // ---- derived flags (ported from the dashboard's detail getters) ----
  get showActions() {
    return !this.readOnly;
  }

  get hasSteps() {
    return this.steps.length > 0;
  }

  get hasChildren() {
    return this.childInstances && this.childInstances.length > 0;
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
    return names.map((name, index) => ({
      key: `${index}_${name}`,
      name,
    }));
  }

  get isCancelable() {
    if (!this.selectedInst) return false;
    const status = this.selectedInst.Status__c;
    return (
      status === "Pending" ||
      status === "Running" ||
      status === "Suspended" ||
      status === "Paused" ||
      status === "CompensationFailed"
    );
  }

  // ---- presentational-only interactions ----
  toggleStepDetails(event) {
    const stepId = event.currentTarget.dataset.stepId;
    this.steps = this.steps.map((step) => {
      if (step.Id === stepId) {
        return { ...step, showDetails: !step.showDetails };
      }
      return step;
    });
  }

  handleCommentsChange(event) {
    this.approvalComments = event.target.value;
  }

  // ---- action affordances → semantic events (host owns the behavior) ----
  handleResume() {
    this.dispatchEvent(new CustomEvent("resume"));
  }

  handleRetry() {
    this.dispatchEvent(new CustomEvent("retry"));
  }

  handleResumeRollback() {
    this.dispatchEvent(new CustomEvent("resumerollback"));
  }

  handlePause() {
    this.dispatchEvent(
      new CustomEvent("pausedefinition", {
        detail: {
          target: this.selectedInst ? this.selectedInst.Workflow_Name__c : null,
        },
      }),
    );
  }

  handleCancel() {
    this.dispatchEvent(new CustomEvent("cancel"));
  }

  handleApprovalSubmit(event) {
    const approvalKey = event.target.dataset.key;
    const approved = event.target.dataset.approved === "true";
    this.dispatchEvent(
      new CustomEvent("approvalsubmit", {
        detail: {
          approvalKey,
          approved,
          comments: this.approvalComments,
        },
      }),
    );
    this.approvalComments = "";
  }

  handleSelectRelated(event) {
    const id = event.currentTarget.dataset.id;
    this.dispatchEvent(new CustomEvent("selectrelated", { detail: { id } }));
  }

  // ---- formatting helpers (ported from workflowDashboard) ----
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
    } catch (ex) {
      return str;
    }
  }

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
}
