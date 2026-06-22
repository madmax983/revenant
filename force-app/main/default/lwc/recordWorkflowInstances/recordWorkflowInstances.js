import { LightningElement, api, wire } from "lwc";
import getInstancesForRecord from "@salesforce/apex/WorkflowDashboardController.getInstancesForRecord";
import getInstanceDetails from "@salesforce/apex/WorkflowDashboardController.getInstanceDetails";
import {
  formatDateTime,
  getStatusBadgeClass,
  getWaitingBadgeClass,
} from "c/workflowFormat";

/**
 * Record-page surface (Issue #46): a focused, read-only list of the Revenant
 * workflow instances correlated to the current record (Correlation_Key__c ==
 * recordId), with one-click drill-down into the shared timeline view.
 *
 * It is pure visibility — the only Apex it touches is cacheable SELECTs
 * (getInstancesForRecord, getInstanceDetails). No writes, no Platform Events,
 * no Queueables. On a record whose Id is never used as a correlation key the
 * wire simply returns an empty list and we render a clear empty state.
 */
export default class RecordWorkflowInstances extends LightningElement {
  @api recordId;

  _rows = [];
  _error;
  _loaded = false;

  selectedDetail;
  selectedInstanceId;
  loadingDetail = false;
  showDetail = false;

  @wire(getInstancesForRecord, { recordId: "$recordId" })
  wiredInstances(result) {
    this.wiredResult = result;
    if (result.data) {
      this._rows = result.data;
      this._error = undefined;
      this._loaded = true;
    } else if (result.error) {
      this._error = result.error;
      this._loaded = true;
    }
  }

  get instances() {
    return (this._rows || []).map((row) => {
      const isSuspended = row.Status__c === "Suspended";
      return {
        ...row,
        formattedDate: formatDateTime(row.CreatedDate),
        statusBadgeClass: getStatusBadgeClass(row.Status__c),
        showWaiting: isSuspended && !!row.waitingOn,
        // Keep the wf-waiting-badge hook class the record-page list relies on.
        waitingBadgeClass:
          getWaitingBadgeClass(row.waitingOn) + " wf-waiting-badge",
        rowClass:
          this.selectedInstanceId === row.Id
            ? "wf-row wf-row-selected"
            : "wf-row",
      };
    });
  }

  get hasInstances() {
    return this.instances.length > 0;
  }

  // Empty only once the wire has resolved without error and returned nothing —
  // never shown while still loading or on error (those have their own states).
  get isEmpty() {
    return this._loaded && !this._error && this.instances.length === 0;
  }

  get isLoading() {
    return !this._loaded && !this._error;
  }

  get hasError() {
    return !!this._error;
  }

  get errorMessage() {
    if (!this._error) {
      return "";
    }
    const body = this._error.body;
    return (
      (body && body.message) || "Unable to load workflows for this record."
    );
  }

  handleRowClick(event) {
    this.loadDetailFor(event.currentTarget.dataset.rowid);
  }

  handleSelectRelated(event) {
    if (event.detail && event.detail.id) {
      this.loadDetailFor(event.detail.id);
    }
  }

  loadDetailFor(instanceId) {
    if (!instanceId) {
      return;
    }
    this.selectedInstanceId = instanceId;
    this.loadingDetail = true;
    this.showDetail = true;
    getInstanceDetails({ instanceId })
      .then((result) => {
        if (this.selectedInstanceId === instanceId) {
          this.selectedDetail = result;
        }
      })
      .catch(() => {
        if (this.selectedInstanceId === instanceId) {
          this.selectedDetail = undefined;
        }
      })
      .finally(() => {
        if (this.selectedInstanceId === instanceId) {
          this.loadingDetail = false;
        }
      });
  }

  handleBackToList() {
    this.showDetail = false;
    this.selectedDetail = undefined;
    this.selectedInstanceId = undefined;
  }
}
