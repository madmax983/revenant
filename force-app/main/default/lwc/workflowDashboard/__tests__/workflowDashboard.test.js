/* eslint-disable @lwc/lwc/no-async-operation */
import { createElement } from "lwc";
import WorkflowDashboard from "c/workflowDashboard";
import getFilteredInstances from "@salesforce/apex/WorkflowDashboardController.getFilteredInstances";
import getInstanceDetails from "@salesforce/apex/WorkflowDashboardController.getInstanceDetails";
import getDefinitionTrends from "@salesforce/apex/WorkflowDashboardController.getDefinitionTrends";
import getWorkflowFailureBreakdown from "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown";
import getDefinitionLatency from "@salesforce/apex/WorkflowDashboardController.getDefinitionLatency";
import getWorkflowStats from "@salesforce/apex/WorkflowDashboardController.getWorkflowStats";
import getCancelEligibleCount from "@salesforce/apex/WorkflowDashboardController.getCancelEligibleCount";
import cancelMatchingInstances from "@salesforce/apex/WorkflowDashboardCommandController.cancelMatchingInstances";
import getRedriveEligibleCount from "@salesforce/apex/WorkflowDashboardController.getRedriveEligibleCount";
import redriveMatchingInstances from "@salesforce/apex/WorkflowDashboardCommandController.redriveMatchingInstances";
import injectSignal from "@salesforce/apex/WorkflowDashboardCommandController.injectSignal";

jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getDefinitionLatency",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getCancelEligibleCount",
  () => ({ default: jest.fn(() => Promise.resolve(0)) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardCommandController.cancelMatchingInstances",
  () => ({ default: jest.fn(() => Promise.resolve({ started: false })) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getRedriveEligibleCount",
  () => ({ default: jest.fn(() => Promise.resolve(0)) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardCommandController.redriveMatchingInstances",
  () => ({ default: jest.fn(() => Promise.resolve({ started: false })) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardCommandController.injectSignal",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

// Imperative Apex methods that fire on load are mocked so the component can
// render without a backend. Only getDefinitionTrends is asserted on here; the
// rest just need to resolve so connectedCallback's Promise.all settles.
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getDefinitionTrends",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getFilteredInstances",
  () => ({ default: jest.fn(() => Promise.resolve([])) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getInstanceDetails",
  () => ({
    default: jest.fn(() =>
      Promise.resolve({
        instance: { Id: "a0G000000000002", Status__c: "Cancelled" },
        steps: [],
        children: [],
        payloadFiles: {},
      }),
    ),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getWorkflowStats",
  () => ({
    default: jest.fn(() =>
      Promise.resolve({ total: 0, active: 0, completed: 0, failed: 0 }),
    ),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getStalledCount",
  () => ({
    default: jest.fn(() => Promise.resolve({ count: 0, capped: false })),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getUnroutedSignalCount",
  () => ({
    default: jest.fn(() => Promise.resolve({ count: 0, capped: false })),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getWatchdogStatus",
  () => ({
    default: jest.fn(() =>
      Promise.resolve({
        isRunning: true,
        scheduledJobsCount: 0,
        sleepingInstances: 0,
        pendingTimeouts: 0,
        dailyAsyncValue: 0,
        dailyAsyncLimit: 250000,
        config: {},
      }),
    ),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getConcurrencyStatus",
  () => ({
    default: jest.fn(() => Promise.resolve([])),
  }),
  { virtual: true },
);

const TRENDS_TWO_DEFS = {
  windowKey: "24h",
  windowHours: 24,
  rows: [
    {
      workflowName: "BillingWorkflow",
      terminalCount: 3,
      successCount: 1,
      failureCount: 2,
      successRate: 33.3,
      throughputPerHour: 0.13,
    },
    {
      workflowName: "OnboardingWorkflow",
      terminalCount: 5,
      successCount: 4,
      failureCount: 1,
      successRate: 80.0,
      throughputPerHour: 0.21,
    },
  ],
};

function flushPromises() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

// Finds the first <lightning-button> in the component that matches predicate.
function findButton(element, predicate) {
  return Array.from(
    element.shadowRoot.querySelectorAll("lightning-button"),
  ).find(predicate);
}

// Mocks the imperative Apex so the list + details show a single Suspended
// instance, which is the shared arrange for the signal-injection tests.
function mockSuspendedInstance() {
  getFilteredInstances.mockResolvedValue([
    {
      Id: "a0G000000000001",
      Name: "WI-0001",
      Workflow_Name__c: "TestWorkflow",
      Status__c: "Suspended",
    },
  ]);
  getInstanceDetails.mockResolvedValue({
    instance: {
      Id: "a0G000000000001",
      Name: "WI-0001",
      Workflow_Name__c: "TestWorkflow",
      Status__c: "Suspended",
    },
    steps: [],
    children: [],
    payloadFiles: {},
  });
}

// Creates the dashboard, selects the first list item, opens the signal modal,
// and returns the mounted element. Callers must arrange mocks beforehand.
async function openSignalModal() {
  const element = createElement("c-workflow-dashboard", {
    is: WorkflowDashboard,
  });
  document.body.appendChild(element);
  await flushPromises();
  element.shadowRoot
    .querySelector(".list-item")
    .dispatchEvent(new CustomEvent("click"));
  await flushPromises();
  await flushPromises();

  const sendSignalBtn = element.shadowRoot.querySelector(
    'lightning-button[data-id="send-signal-btn"]',
  );
  sendSignalBtn.dispatchEvent(new CustomEvent("click"));
  await flushPromises();
  return element;
}

// Resolves the attribute-filter key/value inputs and the add button used by
// the business-attributes filter tests.
function getAttributeFilterInputs(element) {
  const inputs = Array.from(
    element.shadowRoot.querySelectorAll("lightning-input"),
  );
  const keyInput = inputs.find((i) => i.name === "attrKey");
  const valueInput = inputs.find((i) => i.name === "attrValue");
  const btns = Array.from(
    element.shadowRoot.querySelectorAll("lightning-button-icon"),
  );
  const addBtn = btns.find((b) => b.alternativeText === "Add Attribute");
  return { keyInput, valueInput, addBtn };
}

describe("c-workflow-dashboard trends panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("does not request trends on load", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    createComponent();

    await flushPromises();

    expect(getDefinitionTrends).not.toHaveBeenCalled();
  });

  it("requests trends with default 24h window when System Doctor is opened", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "System Doctor");
    expect(button).not.toBeNull();
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();

    expect(getDefinitionTrends).toHaveBeenCalled();
    expect(getDefinitionTrends.mock.calls[0][0]).toEqual({ windowKey: "24h" });
  });

  it("renders one row per definition with a success-rate cell in System Doctor", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "System Doctor");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll('[data-id="trend-row"]');
    expect(rows.length).toBe(2);

    const panelText = element.shadowRoot.textContent;
    expect(panelText).toContain("OnboardingWorkflow");
    expect(panelText).toContain("80%");
    expect(panelText).toContain("BillingWorkflow");
  });

  it("shows an empty state when no definition has terminal activity", async () => {
    getDefinitionTrends.mockResolvedValue({
      windowKey: "24h",
      windowHours: 24,
      rows: [],
    });
    const element = createComponent();

    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "System Doctor");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll('[data-id="trend-row"]');
    expect(rows.length).toBe(0);
    const empty = element.shadowRoot.querySelector('[data-id="trend-empty"]');
    expect(empty).not.toBeNull();
  });

  it("re-queries trends when the window selector changes in System Doctor", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "System Doctor");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    getDefinitionTrends.mockClear();

    const combobox = element.shadowRoot.querySelector(
      '[data-id="trend-window"]',
    );
    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "1h" } }),
    );

    await flushPromises();

    expect(getDefinitionTrends).toHaveBeenCalledWith({ windowKey: "1h" });
  });
});

describe("c-workflow-dashboard failure breakdown panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("requests breakdown with default 24h window when clicking Failure Breakdown button", async () => {
    getWorkflowFailureBreakdown.mockResolvedValue({
      workflowName: "BillingWorkflow",
      timeWindow: "24h",
      isCapped: false,
      capLimit: 2000,
      totalFailures: 0,
      steps: [],
    });

    const element = createComponent();
    await flushPromises();

    // Select a workflow filter
    const combobox = element.shadowRoot.querySelector(
      '[data-id="workflow-filter"]',
    );

    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "BillingWorkflow" } }),
    );

    // Click Failure Breakdown button in header
    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "Failure Breakdown");
    expect(button).not.toBeNull();
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();

    expect(getWorkflowFailureBreakdown).toHaveBeenCalled();
  });

  it("renders steps, error signatures and example links correctly", async () => {
    getWorkflowFailureBreakdown.mockResolvedValue({
      workflowName: "BillingWorkflow",
      timeWindow: "24h",
      isCapped: true,
      capLimit: 2000,
      totalFailures: 2,
      steps: [
        {
          stepName: "ChargeCard",
          failureCount: 2,
          errorSignatures: [
            {
              signature:
                "System.NullPointerException: Attempt to de-reference a null object",
              count: 2,
              examples: [{ id: "a0G000000000001", name: "WI-0001" }],
            },
          ],
        },
      ],
    });

    const element = createComponent();
    await flushPromises();

    // Select a workflow filter
    const combobox = element.shadowRoot.querySelector(
      '[data-id="workflow-filter"]',
    );
    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "BillingWorkflow" } }),
    );

    // Open Failure Breakdown
    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "Failure Breakdown");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    await flushPromises();

    // Verify it renders accordion sections and details
    const accordion = element.shadowRoot.querySelector("lightning-accordion");
    expect(accordion).not.toBeNull();

    const section = element.shadowRoot.querySelector(
      "lightning-accordion-section",
    );
    expect(section).not.toBeNull();
    expect(section.name).toBe("ChargeCard");
    expect(section.label).toBe("ChargeCard (2 failures)");

    const panelText = element.shadowRoot.textContent;
    expect(panelText).toContain("System.NullPointerException");

    const exampleLink = element.shadowRoot.querySelector(
      "button[data-id='a0G000000000001']",
    );
    expect(exampleLink).not.toBeNull();
    expect(exampleLink.textContent).toBe("WI-0001");
  });
});

describe("c-workflow-dashboard latency panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("requests latency with default 24h window when clicking Latency button", async () => {
    getDefinitionLatency.mockResolvedValue({
      workflowName: "BillingWorkflow",
      windowKey: "24h",
      isCapped: false,
      capLimit: 2000,
      sampleSize: 0,
      p50Ms: null,
      p95Ms: null,
      p99Ms: null,
      maxMs: null,
      steps: [],
    });

    const element = createComponent();
    await flushPromises();

    const combobox = element.shadowRoot.querySelector(
      '[data-id="workflow-filter"]',
    );
    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "BillingWorkflow" } }),
    );

    const button = findButton(element, (btn) => btn.label === "Latency");
    expect(button).not.toBeNull();
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();

    expect(getDefinitionLatency).toHaveBeenCalledWith({
      workflowName: "BillingWorkflow",
      windowKey: "24h",
    });
  });

  it("renders percentile tiles, the slowest-step ranking and the truncation badge", async () => {
    getDefinitionLatency.mockResolvedValue({
      workflowName: "BillingWorkflow",
      windowKey: "24h",
      isCapped: true,
      capLimit: 2000,
      sampleSize: 4,
      p50Ms: 10000,
      p95Ms: 19000,
      p99Ms: 20000,
      maxMs: 20000,
      steps: [
        { stepName: "ChargeCard", medianMs: 130000, sampleCount: 4 },
        { stepName: "ReserveInventory", medianMs: 1000, sampleCount: 4 },
      ],
    });

    const element = createComponent();
    await flushPromises();

    const combobox = element.shadowRoot.querySelector(
      '[data-id="workflow-filter"]',
    );
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "BillingWorkflow" } }),
    );

    const button = findButton(element, (btn) => btn.label === "Latency");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    await flushPromises();

    const panelText = element.shadowRoot.textContent;
    // p50 10000ms -> "10s"; p95 19000ms -> "19s".
    expect(panelText).toContain("10s");
    expect(panelText).toContain("19s");
    // Truncation indicator surfaced.
    expect(panelText).toContain("Sampled / window truncated");

    // Slowest step first, median 130000ms -> "2m 10s".
    const rows = element.shadowRoot.querySelectorAll("tbody tr");
    expect(rows.length).toBe(2);
    expect(rows[0].textContent).toContain("ChargeCard");
    expect(rows[0].textContent).toContain("2m 10s");
    expect(rows[1].textContent).toContain("ReserveInventory");
    expect(rows[1].textContent).toContain("1s");
  });
});

describe("c-workflow-dashboard bulk cancel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("clicking the Cancel Matching Active button calls getCancelEligibleCount and opens the cancel modal", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 5,
      completed: 0,
      failed: 0,
    });
    getCancelEligibleCount.mockResolvedValue(3);

    const element = createComponent();
    await flushPromises();

    // Find the button "Cancel Matching Active"
    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Cancel ("));
    expect(button).not.toBeNull();

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify getCancelEligibleCount was called
    expect(getCancelEligibleCount).toHaveBeenCalled();

    // Verify modal is open and shows correct cancelMatchingCount
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).not.toBeNull();

    const modalText = element.shadowRoot.textContent;
    expect(modalText).toContain(
      "3 active workflow instances match the current filter and will be cancelled",
    );
  });

  it("clicking confirm in the modal calls cancelMatchingInstances, closes the modal, shows success toast, and sets selectedInstanceId", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 5,
      completed: 0,
      failed: 0,
    });
    getCancelEligibleCount.mockResolvedValue(3);
    cancelMatchingInstances.mockResolvedValue({
      started: true,
      cancelInstanceId: "a0G000000000002",
    });

    const element = createComponent();
    await flushPromises();

    // Find the button "Cancel Matching Active"
    const button = findButton(
      element,
      (btn) => btn.label && btn.label.startsWith("Cancel ("),
    );
    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Check modal confirm button
    const confirmButton = findButton(
      element,
      (btn) => btn.label === "Cancel Instances",
    );
    expect(confirmButton).not.toBeNull();

    // Listen to the showtoast event
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    confirmButton.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify cancelMatchingInstances was called with the snapshotted filters
    expect(cancelMatchingInstances).toHaveBeenCalledWith({
      workflowName: "",
      status: "",
      searchTerm: "",
    });

    // Verify modal is closed
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();

    // Verify toast was fired
    expect(toastHandler).toHaveBeenCalled();
    const toastEvent = toastHandler.mock.calls[0][0];
    expect(toastEvent.detail.variant).toBe("success");
    expect(toastEvent.detail.title).toBe("Success");
  });

  it("shows info toast and does not open modal when getCancelEligibleCount returns 0", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 5,
      completed: 0,
      failed: 0,
    });
    getCancelEligibleCount.mockResolvedValue(0);

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Cancel ("));

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(getCancelEligibleCount).toHaveBeenCalled();
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();
    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("info");
  });

  it("shows error toast when getCancelEligibleCount fails", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 5,
      completed: 0,
      failed: 0,
    });
    getCancelEligibleCount.mockRejectedValue(new Error("Count failed"));

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Cancel ("));

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
  });

  it("shows error toast when cancelMatchingInstances fails", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 5,
      completed: 0,
      failed: 0,
    });
    getCancelEligibleCount.mockResolvedValue(3);
    cancelMatchingInstances.mockRejectedValue(new Error("Execution failed"));

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Cancel ("));
    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    const confirmButton = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "Cancel Instances");

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    confirmButton.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
  });
});

describe("c-workflow-dashboard bulk redrive", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("clicking the Re-drive Matching Failed button calls getRedriveEligibleCount and opens the redrive confirmation modal", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 0,
      completed: 0,
      failed: 5,
    });
    getRedriveEligibleCount.mockResolvedValue(3);

    const element = createComponent();
    await flushPromises();

    // Find the button "Re-drive Matching Failed"
    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Re-drive ("));
    expect(button).not.toBeNull();

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify getRedriveEligibleCount was called
    expect(getRedriveEligibleCount).toHaveBeenCalled();

    // Verify modal is open and shows correct redriveCount
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).not.toBeNull();

    const modalText = element.shadowRoot.textContent;
    expect(modalText).toContain(
      "3 failed workflow instances match the current filter and will be re-driven",
    );
  });

  it("clicking confirm in the modal calls redriveMatchingInstances with the snapshotted filters, closes the modal, and fires a success toast event", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 0,
      completed: 0,
      failed: 5,
    });
    getRedriveEligibleCount.mockResolvedValue(3);
    redriveMatchingInstances.mockResolvedValue({
      started: true,
      eligibleCount: 3,
      redriveInstanceId: "a0G000000000002",
    });

    const element = createComponent();
    await flushPromises();

    // Find the button "Re-drive Matching Failed"
    const button = findButton(
      element,
      (btn) => btn.label && btn.label.startsWith("Re-drive ("),
    );
    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Check modal confirm button
    const confirmButton = findButton(
      element,
      (btn) => btn.label === "Re-drive Instances",
    );
    expect(confirmButton).not.toBeNull();

    // Listen to the showtoast event
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    confirmButton.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify redriveMatchingInstances was called with the snapshotted filters
    expect(redriveMatchingInstances).toHaveBeenCalledWith({
      workflowName: "",
      status: "",
      searchTerm: "",
    });

    // Verify modal is closed
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();

    // Verify toast was fired
    expect(toastHandler).toHaveBeenCalled();
    const toastEvent = toastHandler.mock.calls[0][0];
    expect(toastEvent.detail.variant).toBe("success");
    expect(toastEvent.detail.title).toBe("Re-drive started");
  });

  it("shows info toast and does not open modal when getRedriveEligibleCount returns 0", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 0,
      completed: 0,
      failed: 5,
    });
    getRedriveEligibleCount.mockResolvedValue(0);

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Re-drive ("));

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(getRedriveEligibleCount).toHaveBeenCalled();
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();
    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("info");
  });

  it("shows error toast when getRedriveEligibleCount fails and does not crash", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 0,
      completed: 0,
      failed: 5,
    });
    getRedriveEligibleCount.mockRejectedValue(new Error("Count failed"));

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Re-drive ("));

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
    expect(toastHandler.mock.calls[0][0].detail.message).toContain(
      "Failed to count re-drive candidates: Count failed",
    );
  });

  it("shows error toast when redriveMatchingInstances fails", async () => {
    getWorkflowStats.mockResolvedValue({
      total: 5,
      active: 0,
      completed: 0,
      failed: 5,
    });
    getRedriveEligibleCount.mockResolvedValue(3);
    redriveMatchingInstances.mockRejectedValue(new Error("Execution failed"));

    const element = createComponent();
    await flushPromises();

    const button = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label && btn.label.startsWith("Re-drive ("));
    button.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    const confirmButton = Array.from(
      element.shadowRoot.querySelectorAll("lightning-button"),
    ).find((btn) => btn.label === "Re-drive Instances");

    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    confirmButton.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    expect(toastHandler).toHaveBeenCalled();
    expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
    expect(toastHandler.mock.calls[0][0].detail.message).toContain(
      "Failed to re-drive matching instances: Execution failed",
    );
  });
});

describe("c-workflow-dashboard details panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("renders progress payload and offloaded download link when details are loaded", async () => {
    // 1. Mock getFilteredInstances to return at least one instance so it shows up in list
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        CreatedDate: "2026-06-24T12:00:00.000Z",
      },
    ]);

    // 2. Mock getInstanceDetails to return progress payload details
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        Progress__c: "Progress info",
      },
      steps: [],
      children: [],
      payloadFiles: {
        "instance.Progress": {
          downloadUrl:
            "/sfc/servlet.shepherd/document/download/069000000000001",
          fullLength: 51200,
        },
      },
    });

    const element = createComponent();
    await flushPromises();

    // 3. Click the instance item to load details
    const item = element.shadowRoot.querySelector(".list-item");
    expect(item).not.toBeNull();
    item.dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    // 4. Assert on rendered details in details panel
    const codeBlocks = Array.from(
      element.shadowRoot.querySelectorAll("pre.code-block"),
    );
    const progressBlock = codeBlocks.find(
      (block) => block.textContent === "Progress info",
    );
    expect(progressBlock).not.toBeNull();

    const links = Array.from(element.shadowRoot.querySelectorAll("a"));
    const progressLink = links.find(
      (link) => link.textContent === "Download full payload (50 KB)",
    );
    expect(progressLink).not.toBeNull();
    expect(progressLink.getAttribute("href")).toBe(
      "/sfc/servlet.shepherd/document/download/069000000000001",
    );
  });

  it("renders progress payload without offloaded link when progressFile is absent", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        Progress__c: "Standard progress info",
      },
      steps: [],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    const codeBlocks = Array.from(
      element.shadowRoot.querySelectorAll("pre.code-block"),
    );
    const progressBlock = codeBlocks.find(
      (block) => block.textContent === "Standard progress info",
    );
    expect(progressBlock).not.toBeNull();

    const links = Array.from(element.shadowRoot.querySelectorAll("a"));
    const progressLink = links.find((link) =>
      link.textContent.includes("Download full payload"),
    );
    expect(progressLink).toBeUndefined();
  });

  it("prettifies and renders valid JSON progress payloads", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        Progress__c: '{"status":"ok","step":3}',
      },
      steps: [],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    const codeBlocks = Array.from(
      element.shadowRoot.querySelectorAll("pre.code-block"),
    );
    const expectedFormattedJson = JSON.stringify(
      { status: "ok", step: 3 },
      null,
      2,
    );
    const progressBlock = codeBlocks.find(
      (block) => block.textContent === expectedFormattedJson,
    );
    expect(progressBlock).not.toBeNull();
  });

  it("handles empty details response without crashing", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);
    getInstanceDetails.mockResolvedValue(null);

    const element = createComponent();
    await flushPromises();

    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    // Verify it settled and component did not crash
    expect(element.shadowRoot.querySelector(".list-item")).not.toBeNull();
  });

  it("renders per-step budget indicator and flags limit pressure", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
      steps: [
        {
          Id: "step1",
          Step_Name__c: "StepNormal",
          Status__c: "Completed",
          CreatedDate: "2026-06-24T12:00:00.000Z",
          CPU_Time_Ms__c: 1000,
          SOQL_Query_Count__c: 10,
          Heap_Size_Bytes__c: 1048576, // 1 MB
        },
        {
          Id: "step2",
          Step_Name__c: "StepPressure",
          Status__c: "Failed",
          CreatedDate: "2026-06-24T12:05:00.000Z",
          CPU_Time_Ms__c: 50000, // 50s (>=80% of 60s)
          SOQL_Query_Count__c: 5,
          Heap_Size_Bytes__c: 500000,
        },
        {
          Id: "step3",
          Step_Name__c: "StepNoTelemetry",
          Status__c: "Completed",
          CreatedDate: "2026-06-24T12:10:00.000Z",
          CPU_Time_Ms__c: null,
          SOQL_Query_Count__c: null,
          Heap_Size_Bytes__c: null,
        },
      ],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    // Verify budget info is rendered
    const stepCards = element.shadowRoot.querySelectorAll(".step-card");
    expect(stepCards.length).toBe(3);

    // Verify step 1 (normal telemetry)
    const usageTexts = Array.from(
      element.shadowRoot.querySelectorAll(".step-card"),
    ).map((card) => card.textContent);

    // Check normal usage text
    expect(usageTexts[0]).toContain(
      "Resource Usage: CPU: 1000 ms (2%) | SOQL: 10/200 (5%) | Heap: 1.00 MB (9%)",
    );

    // Check limit pressure warning and style for step 2
    expect(usageTexts[1]).toContain(
      "Resource Usage: CPU: 50000 ms (83%) | SOQL: 5/200 (3%) | Heap: 0.48 MB (4%)",
    );
    const warningIcon = stepCards[1].querySelector("lightning-icon");
    expect(warningIcon).not.toBeNull();
    expect(warningIcon.alternativeText).toBe("Limit Pressure");

    // Check missing telemetry for step 3
    expect(usageTexts[2]).toContain("Resource Usage: —");
  });

  it("guards against null/undefined telemetry and retry count values to prevent NaN and unrendered retries", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
      steps: [
        {
          Id: "step1",
          Step_Name__c: "StepGuarded",
          Status__c: "Completed",
          CreatedDate: "2026-06-24T12:00:00.000Z",
          CPU_Time_Ms__c: 1000,
          SOQL_Query_Count__c: null,
          Heap_Size_Bytes__c: undefined,
          Retry_Count__c: null,
        },
      ],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    const stepCards = element.shadowRoot.querySelectorAll(".step-card");
    expect(stepCards.length).toBe(1);

    const usageText = stepCards[0].textContent;
    expect(usageText).toContain(
      "Resource Usage: CPU: 1000 ms (2%) | SOQL: 0/200 (0%) | Heap: 0.00 MB (0%)",
    );
    expect(usageText).toContain("Retries: —");
  });

  it("renders step breadcrumbs in a terminal panel when details are loaded and expanded", async () => {
    // 1. Mock getFilteredInstances to return at least one instance so it shows up in list
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
    ]);

    // 2. Mock getInstanceDetails to return step details and breadcrumbs
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
      steps: [
        {
          Id: "step1",
          Step_Name__c: "ChargeCard",
          Status__c: "Completed",
          CreatedDate: "2026-06-24T12:00:00.000Z",
        },
        {
          Id: "step2",
          Step_Name__c: "SendEmail",
          Status__c: "Completed",
          CreatedDate: "2026-06-24T12:05:00.000Z",
        },
      ],
      breadcrumbs: [
        {
          Id: "bc1",
          Correlation_Key__c: "step1",
          Level__c: "INFO",
          Message__c: "Starting credit card charge",
          Fire_Time__c: "2026-06-24T12:00:01.000Z",
        },
        {
          Id: "bc2",
          Correlation_Key__c: "step1",
          Level__c: "WARN",
          Message__c: "Retrying card charge due to network timeout",
          Fire_Time__c: "2026-06-24T12:00:05.000Z",
        },
        {
          Id: "bc3",
          Correlation_Key__c: "step2",
          Level__c: "ERROR",
          Message__c: "Failed to send email receipt",
          Fire_Time__c: "2026-06-24T12:05:02.000Z",
        },
      ],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();

    // 3. Click list item to load details
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    // 4. Click the show details button for ChargeCard step to expand it
    const toggleButtons = element.shadowRoot.querySelectorAll(
      "lightning-button-stateful.text-button",
    );
    expect(toggleButtons.length).toBe(2);
    toggleButtons[0].dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // 5. Verify that the terminal panel exists and contains the correct breadcrumbs
    const terminalPanels =
      element.shadowRoot.querySelectorAll(".terminal-panel");
    expect(terminalPanels.length).toBe(1);

    const terminalLines = terminalPanels[0].querySelectorAll(".terminal-line");
    expect(terminalLines.length).toBe(2);

    // Verify first line details
    const timestamp1 = terminalLines[0].querySelector(".terminal-timestamp");
    const badge1 = terminalLines[0].querySelector(".terminal-badge");
    const message1 = terminalLines[0].querySelector(".terminal-message");

    const expectedTime1 = new Date("2026-06-24T12:00:01.000Z").toLocaleString();
    expect(timestamp1.textContent).toBe(`[${expectedTime1}]`);
    expect(badge1.textContent).toBe("INFO");
    expect(badge1.className).toContain("terminal-badge-info");
    expect(message1.textContent).toBe("Starting credit card charge");

    // Verify second line details
    const timestamp2 = terminalLines[1].querySelector(".terminal-timestamp");
    const badge2 = terminalLines[1].querySelector(".terminal-badge");
    const message2 = terminalLines[1].querySelector(".terminal-message");

    const expectedTime2 = new Date("2026-06-24T12:00:05.000Z").toLocaleString();
    expect(timestamp2.textContent).toBe(`[${expectedTime2}]`);
    expect(badge2.textContent).toBe("WARN");
    expect(badge2.className).toContain("terminal-badge-warn");
    expect(message2.textContent).toBe(
      "Retrying card charge due to network timeout",
    );

    // 6. Click the show details button for SendEmail step to expand it
    toggleButtons[1].dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    const terminalPanelsAfter =
      element.shadowRoot.querySelectorAll(".terminal-panel");
    expect(terminalPanelsAfter.length).toBe(2);

    const emailTerminalLines =
      terminalPanelsAfter[1].querySelectorAll(".terminal-line");
    expect(emailTerminalLines.length).toBe(1);

    const badgeEmail = emailTerminalLines[0].querySelector(".terminal-badge");
    expect(badgeEmail.textContent).toBe("ERROR");
    expect(badgeEmail.className).toContain("terminal-badge-error");
  });
});

describe("c-workflow-dashboard operator signal injection", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("renders Send Signal button for Suspended instance, but not for other statuses", async () => {
    // 1. Check Cancelled status first
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Cancelled",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Cancelled",
      },
      steps: [],
      children: [],
      payloadFiles: {},
    });

    const element = createComponent();
    await flushPromises();
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    let sendSignalBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="send-signal-btn"]',
    );
    expect(sendSignalBtn).toBeNull();

    // 2. Check Suspended status
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Suspended",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Suspended",
      },
      steps: [],
      children: [],
      payloadFiles: {},
    });

    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    const elementSuspended = createComponent();
    await flushPromises();
    elementSuspended.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    sendSignalBtn = elementSuspended.shadowRoot.querySelector(
      'lightning-button[data-id="send-signal-btn"]',
    );
    expect(sendSignalBtn).not.toBeNull();
  });

  it("opens modal on click, verifies inputs, and confirm button is disabled by default", async () => {
    mockSuspendedInstance();

    const element = await openSignalModal();

    // Verify modal is open
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).not.toBeNull();

    // Verify Signal Name input and Payload JSON textarea are rendered
    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    expect(nameInput).not.toBeNull();
    const payloadTextarea = element.shadowRoot.querySelector(
      'lightning-textarea[data-id="signal-payload-input"]',
    );
    expect(payloadTextarea).not.toBeNull();

    // Verify confirm button in modal is disabled when Signal Name is empty
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );
    expect(confirmBtn).not.toBeNull();
    expect(confirmBtn.disabled).toBe(true);
  });

  it("enables confirm button when Signal Name is provided, and handles optional Payload JSON", async () => {
    mockSuspendedInstance();

    const element = await openSignalModal();

    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );

    // Initially disabled
    expect(confirmBtn.disabled).toBe(true);

    // Set Signal Name
    nameInput.value = "PaymentReceived";
    nameInput.dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    // Now enabled
    expect(confirmBtn.disabled).toBe(false);

    // Empty it again to verify it disables
    nameInput.value = "";
    nameInput.dispatchEvent(new CustomEvent("change"));
    await flushPromises();
    expect(confirmBtn.disabled).toBe(true);
  });

  it("calls injectSignal with correct arguments on confirm (success), shows success toast, closes modal, and refreshes instance details", async () => {
    mockSuspendedInstance();
    injectSignal.mockResolvedValue({ success: true });

    const element = await openSignalModal();

    // Set input values
    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    nameInput.value = "PaymentReceived";
    nameInput.dispatchEvent(new CustomEvent("change"));

    const payloadTextarea = element.shadowRoot.querySelector(
      'lightning-textarea[data-id="signal-payload-input"]',
    );
    payloadTextarea.value = '{"amount": 100}';
    payloadTextarea.dispatchEvent(new CustomEvent("change"));

    await flushPromises();

    // Track toast event
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    // Reset calls of getInstanceDetails to be sure we count only the post-success refresh
    getInstanceDetails.mockClear();

    // Click confirm button
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );
    confirmBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify injectSignal is called with correct arguments
    expect(injectSignal).toHaveBeenCalledWith({
      instanceId: "a0G000000000001",
      signalName: "PaymentReceived",
      payloadJson: '{"amount": 100}',
    });

    // Verify success toast
    expect(toastHandler).toHaveBeenCalled();
    const toastEvent = toastHandler.mock.calls[0][0];
    expect(toastEvent.detail.variant).toBe("success");
    expect(toastEvent.detail.title).toBe("Signal Sent");

    // Verify modal is closed
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();

    // Verify getInstanceDetails was called to refresh
    expect(getInstanceDetails).toHaveBeenCalled();
  });

  it("calls injectSignal and handles failure by showing error toast and keeping modal open", async () => {
    mockSuspendedInstance();
    injectSignal.mockRejectedValue(
      new Error("Failed to inject signal: invalid state"),
    );

    const element = await openSignalModal();

    // Set input values
    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    nameInput.value = "PaymentReceived";
    nameInput.dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    // Track toast event
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    // Click confirm button
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );
    confirmBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify injectSignal was called
    expect(injectSignal).toHaveBeenCalledWith({
      instanceId: "a0G000000000001",
      signalName: "PaymentReceived",
      payloadJson: "",
    });

    // Verify error toast
    expect(toastHandler).toHaveBeenCalled();
    const toastEvent = toastHandler.mock.calls[0][0];
    expect(toastEvent.detail.variant).toBe("error");
    expect(toastEvent.detail.message).toContain(
      "Failed to inject signal: invalid state",
    );

    // Verify modal remains open
    const modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).not.toBeNull();
  });

  it("closes modal on cancel button click without sending", async () => {
    mockSuspendedInstance();

    const element = await openSignalModal();

    // Verify modal is open
    let modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).not.toBeNull();

    // Click cancel/close button
    const cancelBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="cancel-signal-btn"]',
    );
    expect(cancelBtn).not.toBeNull();
    cancelBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify modal is closed
    modal = element.shadowRoot.querySelector("section.slds-modal");
    expect(modal).toBeNull();
    expect(injectSignal).not.toHaveBeenCalled();
  });

  it("rejects invalid JSON payload on confirm", async () => {
    mockSuspendedInstance();

    const element = await openSignalModal();

    // Set input values
    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    nameInput.value = "PaymentReceived";
    nameInput.dispatchEvent(new CustomEvent("change"));

    const payloadTextarea = element.shadowRoot.querySelector(
      'lightning-textarea[data-id="signal-payload-input"]',
    );
    payloadTextarea.value = "{invalid}";
    payloadTextarea.dispatchEvent(new CustomEvent("change"));

    // Mock validation methods
    const setCustomValidityMock = jest.fn();
    const reportValidityMock = jest.fn();
    payloadTextarea.setCustomValidity = setCustomValidityMock;
    payloadTextarea.reportValidity = reportValidityMock;

    await flushPromises();

    // Click confirm button
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );
    confirmBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify injectSignal is NOT called
    expect(injectSignal).not.toHaveBeenCalled();

    // Verify validation is checked and reported
    expect(setCustomValidityMock).toHaveBeenCalledWith(
      "Invalid JSON format. Typographic/curly quotes are not valid JSON.",
    );
    expect(reportValidityMock).toHaveBeenCalled();
  });

  it("disables Cancel button when loadingDetails is true", async () => {
    mockSuspendedInstance();
    // Return a promise that doesn't resolve immediately to keep loadingDetails = true
    let resolveSignal;
    injectSignal.mockImplementation(() => {
      return new Promise((resolve) => {
        resolveSignal = resolve;
      });
    });

    const element = await openSignalModal();

    // Set input values
    const nameInput = element.shadowRoot.querySelector(
      'lightning-input[data-id="signal-name-input"]',
    );
    nameInput.value = "PaymentReceived";
    nameInput.dispatchEvent(new CustomEvent("change"));
    await flushPromises();

    // Click confirm button to trigger loadingDetails = true
    const confirmBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="confirm-signal-btn"]',
    );
    confirmBtn.dispatchEvent(new CustomEvent("click"));

    await Promise.resolve();

    const cancelBtn = element.shadowRoot.querySelector(
      'lightning-button[data-id="cancel-signal-btn"]',
    );
    const closeBtn = element.shadowRoot.querySelector(
      'lightning-button-icon[data-id="close-signal-modal"]',
    );

    expect(cancelBtn.disabled).toBe(true);
    expect(closeBtn.disabled).toBe(true);

    // Clean up/resolve the pending promise to avoid leaks or hung tests
    resolveSignal({ success: true });
    await flushPromises();
  });
});

describe("c-workflow-dashboard business attributes filters", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  function createComponent() {
    const element = createElement("c-workflow-dashboard", {
      is: WorkflowDashboard,
    });
    document.body.appendChild(element);
    return element;
  }

  it("handles adding and removing business attribute filters", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        CreatedDate: "2026-06-24T12:00:00.000Z",
      },
    ]);
    getWorkflowStats.mockResolvedValue({
      total: 1,
      active: 1,
      completed: 0,
      failed: 0,
    });

    const element = createComponent();
    await flushPromises();

    // Query key & value inputs and add button using their properties
    const { keyInput, valueInput, addBtn } = getAttributeFilterInputs(element);

    expect(keyInput).toBeDefined();
    expect(valueInput).toBeDefined();
    expect(addBtn).toBeDefined();

    // Add filter: region = EU
    keyInput.value = "region";
    keyInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "region" } }),
    );
    valueInput.value = "EU";
    valueInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "EU" } }),
    );

    addBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify getFilteredInstances was called with region=EU
    expect(getFilteredInstances).toHaveBeenCalledWith(
      expect.objectContaining({
        criteria: expect.objectContaining({
          attributesFilterJson: JSON.stringify({ region: "EU" }),
        }),
      }),
    );

    // Verify active pill is rendered
    const pills = element.shadowRoot.querySelectorAll(".slds-pill");
    expect(pills.length).toBe(1);
    expect(pills[0].querySelector(".slds-pill__label").textContent).toBe(
      "region=EU",
    );

    // Remove the attribute filter
    const removeBtn = pills[0].querySelector(".slds-pill__remove");
    removeBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify getFilteredInstances was called with empty attributesFilterJson
    expect(getFilteredInstances).toHaveBeenLastCalledWith(
      expect.objectContaining({
        criteria: expect.objectContaining({
          attributesFilterJson: "",
        }),
      }),
    );

    // Verify pill is removed
    const postPills = element.shadowRoot.querySelectorAll(".slds-pill");
    expect(postPills.length).toBe(0);
  });

  it("renders attributes badges in details panel when a workflow instance is selected", async () => {
    getFilteredInstances.mockResolvedValue([
      {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
        CreatedDate: "2026-06-24T12:00:00.000Z",
      },
    ]);
    getInstanceDetails.mockResolvedValue({
      instance: {
        Id: "a0G000000000001",
        Name: "WI-0001",
        Workflow_Name__c: "TestWorkflow",
        Status__c: "Running",
      },
      steps: [],
      children: [],
      payloadFiles: {},
      attributes: [
        { Id: "attr1", Key__c: "region", Value__c: "EU" },
        { Id: "attr2", Key__c: "tier", Value__c: "enterprise" },
      ],
    });

    const element = createComponent();
    await flushPromises();

    // Click list item to load details
    element.shadowRoot
      .querySelector(".list-item")
      .dispatchEvent(new CustomEvent("click"));
    await flushPromises();
    await flushPromises();

    // Verify badge container and badges are rendered
    const badges = element.shadowRoot.querySelectorAll(".slds-badge");
    expect(badges.length).toBe(2);
    expect(badges[0].textContent.trim()).toBe("region=EU");
    expect(badges[1].textContent.trim()).toBe("tier=enterprise");
  });

  it("enforces maximum limit of 2 attribute filters and shows a toast warning on the 3rd", async () => {
    getFilteredInstances.mockResolvedValue([]);
    getWorkflowStats.mockResolvedValue({
      total: 0,
      active: 0,
      completed: 0,
      failed: 0,
    });

    const element = createComponent();
    await flushPromises();

    const { keyInput, valueInput, addBtn } = getAttributeFilterInputs(element);

    // Mock showToast event listener
    const toastHandler = jest.fn();
    element.addEventListener("lightning__showtoast", toastHandler);

    // 1. Add filter 1: a=1
    keyInput.value = "a";
    keyInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "a" } }),
    );
    valueInput.value = "1";
    valueInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "1" } }),
    );
    addBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // 2. Add filter 2: b=2
    keyInput.value = "b";
    keyInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "b" } }),
    );
    valueInput.value = "2";
    valueInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "2" } }),
    );
    addBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify 2 pills are rendered
    let pills = element.shadowRoot.querySelectorAll(".slds-pill");
    expect(pills.length).toBe(2);

    // 3. Attempt to add filter 3: c=3
    keyInput.value = "c";
    keyInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "c" } }),
    );
    valueInput.value = "3";
    valueInput.dispatchEvent(
      new CustomEvent("change", { target: { value: "3" } }),
    );
    addBtn.dispatchEvent(new CustomEvent("click"));
    await flushPromises();

    // Verify warning toast was fired and pill count remains 2
    expect(toastHandler).toHaveBeenCalled();
    const toastEvent = toastHandler.mock.calls[0][0];
    expect(toastEvent.detail.variant).toBe("warning");
    expect(toastEvent.detail.message).toContain(
      "A maximum of 2 active attribute filters is allowed",
    );

    pills = element.shadowRoot.querySelectorAll(".slds-pill");
    expect(pills.length).toBe(2);
  });
});
