import { createElement } from "lwc";
import WorkflowDashboard from "c/workflowDashboard";
import getDefinitionTrends from "@salesforce/apex/WorkflowDashboardController.getDefinitionTrends";
import getWorkflowFailureBreakdown from "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown";

jest.mock(
  "@salesforce/apex/WorkflowDashboardController.getWorkflowFailureBreakdown",
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

  it("requests trends with the default 24h window on load", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    createComponent();

    await flushPromises();

    expect(getDefinitionTrends).toHaveBeenCalled();
    expect(getDefinitionTrends.mock.calls[0][0]).toEqual({ windowKey: "24h" });
  });

  it("renders one row per definition with a success-rate cell", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll('[data-id="trend-row"]');
    expect(rows.length).toBe(2);

    const panelText = element.shadowRoot.querySelector(
      '[data-id="trends-panel"]',
    ).textContent;
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
    await flushPromises();

    const rows = element.shadowRoot.querySelectorAll('[data-id="trend-row"]');
    expect(rows.length).toBe(0);
    const empty = element.shadowRoot.querySelector('[data-id="trend-empty"]');
    expect(empty).not.toBeNull();
  });

  it("re-queries trends when the window selector changes", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();
    getDefinitionTrends.mockClear();

    const combobox = element.shadowRoot.querySelector(
      '[data-id="trend-window"]',
    );
    combobox.dispatchEvent(
      new CustomEvent("change", { detail: { value: "1h" } }),
    );

    await flushPromises();

    expect(getDefinitionTrends).toHaveBeenCalledWith({ windowKey: "1h" });
  });

  it("collapses and expands the panel body on header click", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);
    const element = createComponent();

    await flushPromises();
    await flushPromises();

    // Panel body is visible by default.
    expect(
      element.shadowRoot.querySelector('[data-id="trend-row"]'),
    ).not.toBeNull();

    // Click the toggle button to collapse.
    element.shadowRoot
      .querySelector('[role="button"]')
      .dispatchEvent(new CustomEvent("click"));

    await Promise.resolve();

    // Body rows should be gone; combobox should also be hidden.
    expect(
      element.shadowRoot.querySelector('[data-id="trend-row"]'),
    ).toBeNull();
    expect(
      element.shadowRoot.querySelector('[data-id="trend-window"]'),
    ).toBeNull();

    // Click again to expand.
    element.shadowRoot
      .querySelector('[role="button"]')
      .dispatchEvent(new CustomEvent("click"));

    await Promise.resolve();

    expect(
      element.shadowRoot.querySelector('[data-id="trend-row"]'),
    ).not.toBeNull();
  });

  it("persists collapsed state to localStorage and restores it on mount", async () => {
    getDefinitionTrends.mockResolvedValue(TRENDS_TWO_DEFS);

    // Seed localStorage as if the user previously collapsed the panel.
    localStorage.setItem("revenant_dashboard_trends_collapsed", "true");

    const element = createComponent();
    await flushPromises();
    await flushPromises();

    // Should start collapsed — body rows not rendered.
    expect(
      element.shadowRoot.querySelector('[data-id="trend-row"]'),
    ).toBeNull();

    localStorage.removeItem("revenant_dashboard_trends_collapsed");
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
      steps: []
    });

    const element = createComponent();
    await flushPromises();

    // Select a workflow filter
    const combobox = element.shadowRoot.querySelector('[data-id="workflow-filter"]');

    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(new CustomEvent("change", { detail: { value: "BillingWorkflow" } }));

    // Click Failure Breakdown button in header
    const button = Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find(btn => btn.label === "Failure Breakdown");
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
              signature: "System.NullPointerException: Attempt to de-reference a null object",
              count: 2,
              examples: [
                { id: "a0G000000000001", name: "WI-0001" }
              ]
            }
          ]
        }
      ]
    });

    const element = createComponent();
    await flushPromises();

    // Select a workflow filter
    const combobox = element.shadowRoot.querySelector('[data-id="workflow-filter"]');
    expect(combobox).not.toBeNull();
    combobox.dispatchEvent(new CustomEvent("change", { detail: { value: "BillingWorkflow" } }));


    // Open Failure Breakdown
    const button = Array.from(element.shadowRoot.querySelectorAll("lightning-button"))
      .find(btn => btn.label === "Failure Breakdown");
    button.dispatchEvent(new CustomEvent("click"));

    await flushPromises();
    await flushPromises();

    // Verify it renders accordion sections and details
    const accordion = element.shadowRoot.querySelector("lightning-accordion");
    expect(accordion).not.toBeNull();

    const section = element.shadowRoot.querySelector("lightning-accordion-section");
    expect(section).not.toBeNull();
    expect(section.name).toBe("ChargeCard");
    expect(section.label).toBe("ChargeCard (2 failures)");

    const panelText = element.shadowRoot.textContent;
    expect(panelText).toContain("System.NullPointerException");

    const exampleLink = element.shadowRoot.querySelector("a[data-id='a0G000000000001']");
    expect(exampleLink).not.toBeNull();
    expect(exampleLink.textContent).toBe("WI-0001");
  });
});


