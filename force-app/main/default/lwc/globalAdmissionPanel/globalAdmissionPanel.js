/**
 * Global Admission panel for System Doctor (#136). It shows Open or Braked, the
 * reasons, the controls and the count of starts that the brake parked. Apex sets
 * the state. This component only adds labels. It reads once on connect. System
 * Doctor creates it again on each refresh.
 */
import { LightningElement } from "lwc";
import getGlobalAdmission from "@salesforce/apex/WorkflowGlobalAdmissionController.getGlobalAdmission";

const REASON_LABELS = {
  EMERGENCY_STOP: "Emergency stop",
  CAPACITY_CRITICAL: "Async capacity critical",
  CEILING: "Global ceiling reached",
};
const CAPACITY_LABELS = {
  HEALTHY: "Healthy",
  DEGRADED: "Degraded",
  CRITICAL: "Critical",
  UNKNOWN: "Unknown",
};

const isMissing = (value) => value === null || value === undefined;
const formatCount = (value) =>
  isMissing(value) ? "—" : Number(value).toLocaleString();
// Own keys only, so a code such as "toString" shows as it is.
const labelFor = (labels, code) =>
  Object.prototype.hasOwnProperty.call(labels, code) ? labels[code] : code;

export default class GlobalAdmissionPanel extends LightningElement {
  admission = null;
  error = null;
  loaded = false;

  connectedCallback() {
    this.load();
  }

  load() {
    getGlobalAdmission()
      .then((result) => {
        if (!result || typeof result.state !== "string") {
          this.setError("No data was returned.");
          return;
        }
        this.admission = result;
        this.error = null;
        this.loaded = true;
      })
      .catch((err) => {
        this.setError(this.reduceError(err));
      });
  }

  setError(reason) {
    this.admission = null;
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
    return !!this.admission;
  }

  // Null-safe view of the envelope.
  get data() {
    return this.admission || {};
  }

  get isBraked() {
    return this.data.state === "BRAKED";
  }

  get isUngoverned() {
    return this.data.governed === false;
  }

  get stateLabel() {
    return this.isBraked ? "Braked" : "Open";
  }

  get stateBadgeClass() {
    return this.isBraked
      ? "slds-badge slds-theme_error"
      : "slds-badge slds-theme_success";
  }

  get reasonRows() {
    const reasons = Array.isArray(this.data.reasons) ? this.data.reasons : [];
    return reasons.filter(Boolean).map((code, index) => ({
      key: `${code}-${index}`,
      label: labelFor(REASON_LABELS, code),
    }));
  }

  get stopLabel() {
    return this.data.emergencyStop === true ? "On" : "Off";
  }

  get autoBrakeLabel() {
    if (this.data.autoBrake !== true) {
      return "Off";
    }
    const status = this.data.capacityStatus;
    const capacity = isMissing(status)
      ? "capacity not available"
      : labelFor(CAPACITY_LABELS, status);
    return `On (${capacity})`;
  }

  get ceilingLabel() {
    if (isMissing(this.data.ceiling)) {
      return "Not set";
    }
    return `${formatCount(this.data.inFlight)} / ${formatCount(this.data.ceiling)}`;
  }

  get parkedLabel() {
    const count = formatCount(this.data.parkedCount);
    return this.data.parkedCapped === true ? `${count}+` : count;
  }

  get asOfLabel() {
    return this.data.asOfMs
      ? `As of ${new Date(this.data.asOfMs).toLocaleTimeString()}`
      : "";
  }
}
