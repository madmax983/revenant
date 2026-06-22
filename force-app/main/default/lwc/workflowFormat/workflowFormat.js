/**
 * Shared presentation helpers for the Revenant workflow LWCs (the ops
 * `workflowDashboard`, the shared `workflowInstanceDetail`, and the record-page
 * `recordWorkflowInstances`). Centralizing these here keeps badge colors, date
 * formatting, and payload-link construction identical across every surface — a
 * status-enum or locale change is now a one-file edit.
 */

export function formatDateTime(dateStr) {
  if (!dateStr) return "";
  return new Date(dateStr).toLocaleString();
}

export function formatJson(str) {
  if (!str) return "";
  try {
    return JSON.stringify(JSON.parse(str), null, 2);
  } catch (e) {
    return str; // Return raw string if not json
  }
}

// Turns a server payloadFiles descriptor into a render-ready download link, or
// null. Present only for attachment-backed payloads whose full content was
// truncated for display.
export function buildPayloadFile(file) {
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

export function getStatusBadgeClass(status) {
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

export function getTimelineMarkerClass(status) {
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

// Base badge classes for the "waiting on" classification a Suspended instance
// carries (Scheduled Job / Delayed Queueable / Watchdog).
export function getWaitingBadgeClass(waitingOn) {
  if (waitingOn === "Watchdog") {
    return "badge badge-purple";
  }
  if (waitingOn === "Delayed Queueable") {
    return "badge badge-indigo";
  }
  return "badge badge-blue";
}
