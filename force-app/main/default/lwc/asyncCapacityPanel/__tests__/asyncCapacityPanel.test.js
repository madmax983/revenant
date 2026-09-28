import { createElement } from "lwc";
import AsyncCapacityPanel from "c/asyncCapacityPanel";
import getAsyncCapacity from "@salesforce/apex/WorkflowAsyncCapacityController.getAsyncCapacity";

jest.mock(
  "@salesforce/apex/WorkflowAsyncCapacityController.getAsyncCapacity",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function envelope(overrides = {}) {
  return {
    asOfMs: 1700000000000,
    status: "HEALTHY",
    chainAtRisk: false,
    warnPercent: 80,
    critPercent: 95,
    thresholdSource: "DEFAULT",
    metrics: [
      {
        key: "DAILY_ASYNC",
        label: "Daily async Apex executions",
        used: 1000,
        limit: 250000,
        percent: 0.4,
        status: "HEALTHY",
      },
      {
        key: "FLEX_QUEUE",
        label: "Apex flex queue (Holding)",
        used: 3,
        limit: 100,
        percent: 3,
        status: "HEALTHY",
      },
    ],
    jobCounts: { holding: 3, queued: 5, processing: 1, total: 9 },
    ...overrides,
  };
}

async function render(result) {
  if (result instanceof Error) {
    getAsyncCapacity.mockRejectedValue(result);
  } else {
    getAsyncCapacity.mockResolvedValue(result);
  }
  const element = createElement("c-async-capacity-panel", {
    is: AsyncCapacityPanel,
  });
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

const q = (element, id) =>
  element.shadowRoot.querySelector(`[data-id="${id}"]`);
const qa = (element, id) =>
  element.shadowRoot.querySelectorAll(`[data-id="${id}"]`);

describe("c-async-capacity-panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows a loading state before the read returns", () => {
    getAsyncCapacity.mockReturnValue(new Promise(() => {}));
    const element = createElement("c-async-capacity-panel", {
      is: AsyncCapacityPanel,
    });
    document.body.appendChild(element);
    expect(q(element, "capacity-loading")).not.toBeNull();
    expect(q(element, "capacity-status")).toBeNull();
  });

  it("reads capacity once on connect", async () => {
    await render(envelope());
    expect(getAsyncCapacity).toHaveBeenCalledTimes(1);
  });

  it("renders a Healthy badge and no risk alert", async () => {
    const element = await render(envelope());
    const badge = q(element, "capacity-status");
    expect(badge.textContent).toBe("Healthy");
    expect(badge.className).toContain("slds-theme_success");
    expect(q(element, "capacity-risk")).toBeNull();
    expect(q(element, "capacity-action").textContent).toContain("No action");
  });

  it("renders a Degraded badge and no risk alert", async () => {
    const element = await render(envelope({ status: "DEGRADED" }));
    const badge = q(element, "capacity-status");
    expect(badge.textContent).toBe("Degraded");
    expect(badge.className).toContain("slds-theme_warning");
    expect(q(element, "capacity-risk")).toBeNull();
  });

  it("renders the chain handoff risk alert when Critical", async () => {
    const element = await render(
      envelope({ status: "CRITICAL", chainAtRisk: true }),
    );
    const badge = q(element, "capacity-status");
    expect(badge.textContent).toBe("Critical");
    expect(badge.className).toContain("slds-theme_error");
    const risk = q(element, "capacity-risk");
    expect(risk).not.toBeNull();
    expect(risk.textContent).toContain("Chain handoff at risk");
    expect(risk.getAttribute("role")).toBe("alert");
  });

  it("renders an Unknown badge for missing data", async () => {
    const element = await render(envelope({ status: "UNKNOWN" }));
    expect(q(element, "capacity-status").textContent).toBe("Unknown");
    expect(q(element, "capacity-risk")).toBeNull();
  });

  it("renders one row per metric with used, limit, percent and status", async () => {
    const element = await render(
      envelope({
        status: "DEGRADED",
        metrics: [
          {
            key: "DAILY_ASYNC",
            label: "Daily async Apex executions",
            used: 210000,
            limit: 250000,
            percent: 84,
            status: "DEGRADED",
          },
          {
            key: "FLEX_QUEUE",
            label: "Apex flex queue (Holding)",
            used: null,
            limit: 100,
            percent: null,
            status: "UNKNOWN",
          },
        ],
      }),
    );
    const rows = qa(element, "capacity-metric");
    expect(rows).toHaveLength(2);
    expect(rows[0].textContent).toContain("Daily async Apex executions");
    expect(rows[0].textContent).toContain((210000).toLocaleString());
    expect(rows[0].textContent).toContain((250000).toLocaleString());
    expect(rows[0].textContent).toContain("84%");
    const statuses = qa(element, "metric-status");
    expect(statuses[0].textContent).toBe("Degraded");
    expect(statuses[1].textContent).toBe("Unknown");
    expect(rows[1].textContent).toContain("N/A");
  });

  it("renders the job counts", async () => {
    const element = await render(envelope());
    const jobs = q(element, "capacity-jobs").textContent;
    expect(jobs).toContain("Holding 3");
    expect(jobs).toContain("Queued 5");
    expect(jobs).toContain("Processing 1");
    expect(jobs).toContain("Total 9");
  });

  it("says when job counts are not available", async () => {
    const element = await render(
      envelope({
        jobCounts: {
          holding: null,
          queued: null,
          processing: null,
          total: null,
        },
      }),
    );
    expect(q(element, "capacity-jobs").textContent).toContain("not available");
  });

  it("renders the thresholds", async () => {
    const element = await render(
      envelope({ warnPercent: 70, critPercent: 90 }),
    );
    const text = q(element, "capacity-thresholds").textContent;
    expect(text).toContain("Degraded at 70%");
    expect(text).toContain("Critical at 90%");
  });

  it("warns when the threshold config is not valid", async () => {
    const element = await render(envelope({ thresholdSource: "INVALID" }));
    expect(q(element, "capacity-invalid-config").textContent).toContain(
      "Async_Capacity_Thresholds__c",
    );
  });

  it("hides the config warning when the config is valid", async () => {
    const element = await render(envelope({ thresholdSource: "CONFIG" }));
    expect(q(element, "capacity-invalid-config")).toBeNull();
  });

  it("shows an error when the read fails", async () => {
    const error = new Error("boom");
    error.body = { message: "Unauthorized: no access" };
    const element = await render(error);
    const box = q(element, "capacity-error");
    expect(box).not.toBeNull();
    expect(box.textContent).toContain("Unauthorized: no access");
    expect(q(element, "capacity-status")).toBeNull();
  });

  it("shows an error when the read returns no data", async () => {
    const element = await render(undefined);
    expect(q(element, "capacity-error")).not.toBeNull();
  });
});
