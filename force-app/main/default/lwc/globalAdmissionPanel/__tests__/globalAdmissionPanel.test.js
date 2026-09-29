import { createElement } from "lwc";
import GlobalAdmissionPanel from "c/globalAdmissionPanel";
import getGlobalAdmission from "@salesforce/apex/WorkflowGlobalAdmissionController.getGlobalAdmission";

jest.mock(
  "@salesforce/apex/WorkflowGlobalAdmissionController.getGlobalAdmission",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function envelope(overrides = {}) {
  return {
    asOfMs: 1700000000000,
    state: "OPEN",
    governed: true,
    reason: null,
    reasons: [],
    emergencyStop: false,
    autoBrake: false,
    capacityStatus: null,
    ceiling: null,
    inFlight: 0,
    parkedCount: 0,
    ...overrides,
  };
}

async function render(result) {
  if (result instanceof Error) {
    getGlobalAdmission.mockRejectedValue(result);
  } else {
    getGlobalAdmission.mockResolvedValue(result);
  }
  const element = createElement("c-global-admission-panel", {
    is: GlobalAdmissionPanel,
  });
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

const q = (element, id) =>
  element.shadowRoot.querySelector(`[data-id="${id}"]`);
const qa = (element, id) =>
  element.shadowRoot.querySelectorAll(`[data-id="${id}"]`);

describe("c-global-admission-panel", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows a loading state before the read returns", () => {
    getGlobalAdmission.mockReturnValue(new Promise(() => {}));
    const element = createElement("c-global-admission-panel", {
      is: GlobalAdmissionPanel,
    });
    document.body.appendChild(element);
    expect(q(element, "admission-loading")).not.toBeNull();
  });

  it("shows Open and says that no control is set", async () => {
    const element = await render(envelope({ governed: false }));
    expect(q(element, "admission-state").textContent).toBe("Open");
    expect(q(element, "admission-ungoverned")).not.toBeNull();
    expect(q(element, "admission-braked")).toBeNull();
  });

  it("shows Braked with the emergency stop reason and the parked count", async () => {
    const element = await render(
      envelope({
        state: "BRAKED",
        reason: "EMERGENCY_STOP",
        reasons: ["EMERGENCY_STOP"],
        emergencyStop: true,
        parkedCount: 1234,
      }),
    );
    expect(q(element, "admission-state").textContent).toBe("Braked");
    expect(q(element, "admission-state").className).toContain(
      "slds-theme_error",
    );
    expect(q(element, "admission-braked").textContent).toContain(
      "Emergency stop",
    );
    expect(q(element, "admission-parked").textContent).toBe(
      (1234).toLocaleString(),
    );
    expect(q(element, "admission-stop").textContent).toBe("On");
  });

  it("lists every reason in order", async () => {
    const element = await render(
      envelope({
        state: "BRAKED",
        reason: "EMERGENCY_STOP",
        reasons: ["EMERGENCY_STOP", "CAPACITY_CRITICAL", "CEILING"],
      }),
    );
    const reasons = Array.from(qa(element, "admission-reason")).map(
      (e) => e.textContent,
    );
    expect(reasons).toEqual([
      "Emergency stop",
      "Async capacity critical",
      "Global ceiling reached",
    ]);
  });

  it("shows an unknown reason code as it is", async () => {
    const element = await render(
      envelope({ state: "BRAKED", reason: "NEW_CODE", reasons: ["NEW_CODE"] }),
    );
    expect(q(element, "admission-reason").textContent).toBe("NEW_CODE");
  });

  it("shows the ceiling use, or Not set", async () => {
    let element = await render(envelope({ ceiling: 10, inFlight: 3 }));
    expect(q(element, "admission-ceiling").textContent).toBe("3 / 10");
    document.body.removeChild(element);
    element = await render(envelope({ ceiling: null }));
    expect(q(element, "admission-ceiling").textContent).toBe("Not set");
  });

  it("shows the auto-brake and the capacity status", async () => {
    const element = await render(
      envelope({ autoBrake: true, capacityStatus: "DEGRADED" }),
    );
    expect(q(element, "admission-auto").textContent).toBe("On (Degraded)");
  });

  it("marks a capped parked count", async () => {
    const element = await render(
      envelope({ parkedCount: 10000, parkedCapped: true }),
    );
    expect(q(element, "admission-parked").textContent).toBe(
      `${(10000).toLocaleString()}+`,
    );
  });

  it("shows an error when the data is not valid", async () => {
    const element = await render({ body: { message: "No access" } });
    expect(q(element, "admission-error").textContent).toContain(
      "No data was returned.",
    );
  });

  it("shows the server message when the read fails", async () => {
    const element = await render({ body: { message: "No access" } });
    getGlobalAdmission.mockRejectedValue({ body: { message: "No access" } });
    const failed = createElement("c-global-admission-panel", {
      is: GlobalAdmissionPanel,
    });
    document.body.appendChild(failed);
    await flushPromises();
    expect(q(failed, "admission-error").textContent).toContain("No access");
    expect(q(element, "admission-state")).toBeNull();
  });

  it("uses the error message, else a fallback", async () => {
    let element = await render(new Error("Boom"));
    expect(q(element, "admission-error").textContent).toContain("Boom");
    document.body.removeChild(element);
    element = await render(new Error(""));
    expect(q(element, "admission-error").textContent).toContain(
      "Unknown error",
    );
  });

  it("hides the loading state after the read", async () => {
    const element = await render(envelope());
    expect(q(element, "admission-loading")).toBeNull();
    expect(q(element, "admission-ungoverned")).toBeNull();
    expect(q(element, "admission-asof").textContent).toContain("As of");
  });

  it("shows Off, a missing capacity and a missing count", async () => {
    let element = await render(envelope({ autoBrake: false }));
    expect(q(element, "admission-auto").textContent).toBe("Off");
    expect(q(element, "admission-stop").textContent).toBe("Off");
    document.body.removeChild(element);
    element = await render(
      envelope({
        autoBrake: true,
        capacityStatus: null,
        ceiling: 10,
        inFlight: null,
      }),
    );
    expect(q(element, "admission-auto").textContent).toBe(
      "On (capacity not available)",
    );
    expect(q(element, "admission-ceiling").textContent).toBe(
      `— / ${(10).toLocaleString()}`,
    );
  });
});
