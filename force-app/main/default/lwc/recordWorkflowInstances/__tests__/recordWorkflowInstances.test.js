import { createElement } from "lwc";
import RecordWorkflowInstances from "c/recordWorkflowInstances";
import getInstancesForRecord from "@salesforce/apex/WorkflowDashboardController.getInstancesForRecord";
import getInstanceDetails from "@salesforce/apex/WorkflowDashboardController.getInstanceDetails";

// getInstancesForRecord is consumed via @wire, so it needs a test wire adapter
// (emit/error). getInstanceDetails is called imperatively, so the default
// auto-mock (a jest.fn supporting mockResolvedValue) is exactly what we want.
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getInstancesForRecord",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true },
);

jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getInstanceDetails",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

const RECORD_ID = "001000000000001AAA";

const ROWS = [
  {
    Id: "a01000000000001AAA",
    Name: "WFI-000001",
    Workflow_Name__c: "OrderFulfillment",
    Status__c: "Suspended",
    Current_Step__c: "OrderFulfillment.AwaitPayment",
    Correlation_Key__c: RECORD_ID,
    CreatedDate: "2026-06-20T10:00:00.000Z",
    waitingOn: "Watchdog",
  },
  {
    Id: "a01000000000002AAA",
    Name: "WFI-000002",
    Workflow_Name__c: "OrderFulfillment",
    Status__c: "Completed",
    Current_Step__c: "OrderFulfillment.Ship",
    Correlation_Key__c: RECORD_ID,
    CreatedDate: "2026-06-19T10:00:00.000Z",
    waitingOn: null,
  },
];

function createComponent() {
  const element = createElement("c-record-workflow-instances", {
    is: RecordWorkflowInstances,
  });
  element.recordId = RECORD_ID;
  document.body.appendChild(element);
  return element;
}

function flushPromises() {
  return Promise.resolve();
}

describe("c-record-workflow-instances", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("lists each correlated instance with name, status and current step", async () => {
    const element = createComponent();
    getInstancesForRecord.emit(ROWS);
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll(".wf-row");
    expect(rows.length).toBe(2);

    const text = element.shadowRoot.textContent;
    expect(text).toContain("OrderFulfillment");
    expect(text).toContain("Suspended");
    expect(text).toContain("OrderFulfillment.AwaitPayment");
  });

  it("shows the waitingOn classification for suspended rows", async () => {
    const element = createComponent();
    getInstancesForRecord.emit(ROWS);
    await flushPromises();

    const badge = element.shadowRoot.querySelector(".wf-waiting-badge");
    expect(badge).not.toBeNull();
    expect(badge.textContent).toContain("Watchdog");
  });

  it("renders a clear empty state (no spinner, no error) when there are zero instances", async () => {
    const element = createComponent();
    getInstancesForRecord.emit([]);
    await flushPromises();

    expect(element.shadowRoot.querySelector(".wf-empty")).not.toBeNull();
    expect(element.shadowRoot.querySelectorAll(".wf-row").length).toBe(0);
    expect(element.shadowRoot.querySelector("lightning-spinner")).toBeNull();
  });

  it("opens the shared read-only detail view on row click", async () => {
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: ROWS[0].Id,
        Name: ROWS[0].Name,
        Workflow_Name__c: ROWS[0].Workflow_Name__c,
        Status__c: ROWS[0].Status__c,
        Correlation_Key__c: RECORD_ID,
        CreatedDate: ROWS[0].CreatedDate,
      },
      steps: [],
      children: [],
      successor: null,
      waitingOn: "Watchdog",
      pendingCompensations: [],
      pendingCompensationCount: 0,
      payloadFiles: {},
    });

    const element = createComponent();
    getInstancesForRecord.emit(ROWS);
    await flushPromises();

    element.shadowRoot.querySelector(".wf-row").click();
    await flushPromises();
    await flushPromises();

    expect(getInstanceDetails).toHaveBeenCalledWith({ instanceId: ROWS[0].Id });

    const detail = element.shadowRoot.querySelector(
      "c-workflow-instance-detail",
    );
    expect(detail).not.toBeNull();
    expect(detail.readOnly).toBe(true);
  });

  it("surfaces an error panel if the wire errors", async () => {
    const element = createComponent();
    getInstancesForRecord.error();
    await flushPromises();

    expect(element.shadowRoot.querySelector(".wf-error")).not.toBeNull();
  });
});
