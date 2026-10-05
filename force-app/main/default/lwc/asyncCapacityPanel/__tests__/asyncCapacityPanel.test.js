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
        key: "BACKLOG",
        label: "Pending jobs vs executions left",
        used: 9,
        limit: 249000,
        percent: 0,
        status: "HEALTHY",
      },
    ],
    jobCounts: {
      holding: 3,
      queued: 5,
      processing: 1,
      total: 9,
      flexQueueLimit: 100,
    },
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
            key: "BACKLOG",
            label: "Pending jobs vs executions left",
            used: null,
            limit: 40000,
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
    expect(rows[1].textContent).toContain("—");
    expect(rows[1].textContent).not.toContain("N/A");
  });

  it("renders the job counts", async () => {
    const element = await render(envelope());
    const jobs = q(element, "capacity-jobs").textContent;
    expect(jobs).toContain("Flex queue (Holding) 3 / 100");
    expect(jobs).toContain("Queued 5");
    expect(jobs).toContain("Processing 1");
    expect(jobs).toContain("Total 9");
  });

  it("renders the Preparing count", async () => {
    const element = await render(
      envelope({
        jobCounts: {
          holding: 3,
          queued: 5,
          processing: 1,
          preparing: 2,
          total: 11,
          flexQueueLimit: 100,
        },
      }),
    );
    const jobs = q(element, "capacity-jobs").textContent;
    expect(jobs).toContain("Preparing 2");
    expect(jobs).toContain("Total 11");
  });

  it("shows no Preparing count when the data has none", async () => {
    const element = await render(envelope());
    expect(q(element, "capacity-jobs").textContent).not.toContain("Preparing");
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

  it("shows the action for Degraded and Critical", async () => {
    let element = await render(envelope({ status: "DEGRADED" }));
    expect(q(element, "capacity-action").textContent).toContain(
      "Start fewer new instances",
    );
    document.body.removeChild(element);
    element = await render(envelope({ status: "CRITICAL", chainAtRisk: true }));
    expect(q(element, "capacity-action").textContent).toContain(
      "Pause definitions that are not critical",
    );
  });

  it("uses the plain badge for Unknown and for an unexpected status", async () => {
    for (const status of ["UNKNOWN", "toString", undefined]) {
      const element = await render(envelope({ status }));
      const badge = q(element, "capacity-status");
      expect(badge.textContent).toBe("Unknown");
      expect(badge.className).toBe("slds-badge");
      document.body.removeChild(element);
    }
  });

  it("follows chainAtRisk from Apex, not the status text", async () => {
    const element = await render(
      envelope({ status: "DEGRADED", chainAtRisk: true }),
    );
    expect(q(element, "capacity-risk")).not.toBeNull();
  });

  it("clamps the progress bar at 100", async () => {
    const element = await render(
      envelope({
        metrics: [
          {
            key: "DAILY_ASYNC",
            label: "Daily async Apex executions",
            used: 300,
            limit: 200,
            percent: 150,
            status: "CRITICAL",
          },
        ],
      }),
    );
    const bar = element.shadowRoot.querySelector("lightning-progress-bar");
    expect(bar.value).toBe(100);
    expect(q(element, "capacity-metric").textContent).toContain("150%");
  });

  it("skips null metric rows and keys rows without a key", async () => {
    const element = await render(
      envelope({
        metrics: [
          null,
          {
            label: "No key",
            used: 1,
            limit: 10,
            percent: 10,
            status: "HEALTHY",
          },
        ],
      }),
    );
    const rows = qa(element, "capacity-metric");
    expect(rows).toHaveLength(1);
    expect(rows[0].textContent).toContain("No key");
  });

  it("shows the as-of time", async () => {
    const element = await render(envelope());
    expect(q(element, "capacity-asof").textContent).toContain("As of");
  });

  it("says when thresholds are missing", async () => {
    const element = await render(
      envelope({ warnPercent: null, critPercent: undefined }),
    );
    const text = q(element, "capacity-thresholds").textContent;
    expect(text).toBe("Thresholds are not available.");
    expect(text).not.toContain("null");
  });

  it("shows an error when metrics is not a list", async () => {
    const element = await render(envelope({ metrics: "bad" }));
    expect(q(element, "capacity-error").textContent).toContain(
      "No data was returned.",
    );
  });

  it("marks the loading box busy and the error box as an alert", async () => {
    getAsyncCapacity.mockReturnValue(new Promise(() => {}));
    const loading = createElement("c-async-capacity-panel", {
      is: AsyncCapacityPanel,
    });
    document.body.appendChild(loading);
    expect(q(loading, "capacity-loading").getAttribute("aria-busy")).toBe(
      "true",
    );
    document.body.removeChild(loading);

    const element = await render(new Error("boom"));
    expect(q(element, "capacity-error").getAttribute("role")).toBe("alert");
  });

  it("marks the daily row when the org has an elastic limit", async () => {
    const element = await render(
      envelope({
        metrics: [
          {
            key: "DAILY_ASYNC",
            label: "Daily async Apex executions",
            used: 250000,
            limit: 500000,
            percent: 50,
            status: "HEALTHY",
            elastic: true,
          },
        ],
      }),
    );
    expect(q(element, "capacity-metric").textContent).toContain(
      "Elastic limit",
    );
  });

  it("does not mark the daily row without an elastic limit", async () => {
    const element = await render(envelope());
    expect(q(element, "capacity-metric").textContent).not.toContain(
      "Elastic limit",
    );
  });

  it("shows the pending executions in the job counts", async () => {
    const element = await render(
      envelope({
        jobCounts: {
          holding: 0,
          queued: 1,
          processing: 1,
          total: 2,
          pendingExecutions: 4002,
          capped: false,
          flexQueueLimit: 100,
        },
      }),
    );
    expect(q(element, "capacity-jobs").textContent).toContain(
      `Pending executions ${(4002).toLocaleString()}`,
    );
    expect(q(element, "capacity-capped")).toBeNull();
  });

  it("says when the job read stopped at its cap", async () => {
    const element = await render(
      envelope({
        jobCounts: {
          holding: 0,
          queued: 2000,
          processing: 0,
          total: 2000,
          pendingExecutions: 2000,
          capped: true,
          flexQueueLimit: 100,
        },
      }),
    );
    expect(q(element, "capacity-capped").textContent).toContain(
      "first 2,000 jobs",
    );
  });

  it("marks a capped metric percent as a lower bound", async () => {
    const element = await render(
      envelope({
        status: "UNKNOWN",
        metrics: [
          {
            key: "BACKLOG",
            label: "Pending executions vs executions left",
            used: 2000,
            limit: 100000,
            percent: 2,
            status: "UNKNOWN",
            capped: true,
          },
        ],
      }),
    );
    const row = q(element, "capacity-metric");
    expect(row.textContent).toContain("≥ 2%");
    expect(q(element, "metric-status").textContent).toBe("Unknown");
  });

  it("shows an exact percent when the metric is not capped", async () => {
    const element = await render(envelope());
    expect(q(element, "capacity-metric").textContent).not.toContain("≥");
  });

  it("marks a lower-bound metric percent when batch jobs have no size", async () => {
    const element = await render(
      envelope({
        status: "UNKNOWN",
        metrics: [
          {
            key: "BACKLOG",
            label: "Pending executions vs executions left",
            used: 1,
            limit: 249000,
            percent: 0,
            status: "UNKNOWN",
            capped: false,
            lowerBound: true,
          },
        ],
        jobCounts: {
          holding: 1,
          queued: 0,
          processing: 0,
          total: 1,
          pendingExecutions: 1,
          capped: false,
          unsizedBatches: 1,
          flexQueueLimit: 100,
        },
      }),
    );
    expect(q(element, "capacity-metric").textContent).toContain("≥ 0%");
    expect(q(element, "capacity-unsized").textContent).toContain("1 batch job");
  });

  it("hides the unsized note when all batch jobs have a size", async () => {
    const element = await render(envelope());
    expect(q(element, "capacity-unsized")).toBeNull();
  });
});
