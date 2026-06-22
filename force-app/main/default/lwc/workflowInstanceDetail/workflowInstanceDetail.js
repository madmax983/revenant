import { LightningElement, api } from "lwc";
import {
  formatDateTime,
  formatJson,
  buildPayloadFile,
  getStatusBadgeClass,
  getTimelineMarkerClass,
  getWaitingBadgeClass,
} from "c/workflowFormat";

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
      formattedDate: formatDateTime(inst.CreatedDate),
      statusBadgeClass: getStatusBadgeClass(inst.Status__c),
      Input__c: formatJson(inst.Input__c),
      Output__c: formatJson(inst.Output__c),
      inputFile: buildPayloadFile(payloadFiles["instance.Input"]),
      outputFile: buildPayloadFile(payloadFiles["instance.Output"]),
      waitingOn: result.waitingOn,
      isWatchdogWaiting: result.waitingOn === "Watchdog",
      waitingOnBadgeClass: getWaitingBadgeClass(result.waitingOn),
      pendingCompensationCount: result.pendingCompensationCount || 0,
      pendingCompensations: result.pendingCompensations || [],
    };

    this.childInstances = (result.children || []).map((child) => {
      return {
        ...child,
        formattedDate: formatDateTime(child.CreatedDate),
        statusBadgeClass: getStatusBadgeClass(child.Status__c),
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
        formattedDate: formatDateTime(step.CreatedDate),
        statusBadgeClass: approvalInfo
          ? "badge badge-orange pulse-glow"
          : getStatusBadgeClass(step.Status__c),
        markerClass: approvalInfo
          ? "timeline-marker bg-yellow pulse-glow"
          : getTimelineMarkerClass(step.Status__c),
        showDetails:
          showDetailsMap.get(step.Id) || (approvalInfo ? true : false),
        isWaitingForApproval: !!approvalInfo,
        approvalKey: approvalInfo ? approvalInfo.key : null,
        approvalRole: approvalInfo ? approvalInfo.role : null,
        childInstanceId: childWorkflowLink ? childWorkflowLink.id : null,
        childInstanceName: childWorkflowLink ? childWorkflowLink.name : null,
        Input__c: formatJson(step.Input__c),
        Output__c: formatJson(step.Output__c),
        inputFile: buildPayloadFile(payloadFiles["step." + step.Id + ".Input"]),
        outputFile: buildPayloadFile(
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
}
