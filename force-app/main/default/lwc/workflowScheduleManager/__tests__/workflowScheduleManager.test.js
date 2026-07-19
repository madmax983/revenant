import { createElement } from "lwc";
import WorkflowScheduleManager from "c/workflowScheduleManager";
import getSchedules from "@salesforce/apex/WorkflowScheduleController.getSchedules";
import getWorkflowDefinitions from "@salesforce/apex/WorkflowScheduleController.getWorkflowDefinitions";
import getTimeZones from "@salesforce/apex/WorkflowScheduleController.getTimeZones";
import previewCron from "@salesforce/apex/WorkflowScheduleController.previewCron";

// Wired reads are backed by test wire adapters so the suite can push data with
// .emit(); imperative reads/writes are plain jest.fn mocks that resolve.
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.getSchedules",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.getWorkflowDefinitions",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.getTimeZones",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.previewCron",
  () => ({
    default: jest.fn(() =>
      Promise.resolve({ valid: true, lastFire: null, nextFire: null }),
    ),
  }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.getScheduleDetail",
  () => ({ default: jest.fn(() => Promise.resolve({ logs: [] })) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.saveSchedule",
  () => ({ default: jest.fn(() => Promise.resolve("a0S000000000001")) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.deleteSchedule",
  () => ({ default: jest.fn(() => Promise.resolve()) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.enableSchedule",
  () => ({ default: jest.fn(() => Promise.resolve()) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.disableSchedule",
  () => ({ default: jest.fn(() => Promise.resolve()) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.runNow",
  () => ({ default: jest.fn(() => Promise.resolve("a0G000000000001")) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.registerDedicatedJob",
  () => ({ default: jest.fn(() => Promise.resolve()) }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowScheduleController.unregisterDedicatedJob",
  () => ({ default: jest.fn(() => Promise.resolve()) }),
  { virtual: true },
);

const ZONES = ["America/New_York", "Asia/Tokyo", "Europe/London", "UTC"];

// Microtask-based flush (no timers) so the suite stays clean under the LWC
// no-async-operation lint rule while still draining the promise/render queue.
function flushPromises() {
  return Promise.resolve().then(() => Promise.resolve());
}

function createComponent() {
  const element = createElement("c-workflow-schedule-manager", {
    is: WorkflowScheduleManager,
  });
  document.body.appendChild(element);
  return element;
}

// Mounts the component, emits the wired reads, and opens the editor modal by
// clicking "New Schedule". Returns the mounted element with the modal open.
async function openEditor() {
  const element = createComponent();
  getSchedules.emit([]);
  getWorkflowDefinitions.emit([]);
  getTimeZones.emit(ZONES);
  await flushPromises();

  const newBtn = Array.from(
    element.shadowRoot.querySelectorAll("lightning-button"),
  ).find((b) => b.label === "New Schedule");
  newBtn.dispatchEvent(new CustomEvent("click"));
  await flushPromises();
  return element;
}

function zoneCombobox(element) {
  return element.shadowRoot.querySelector(
    'lightning-combobox[data-field="Time_Zone__c"]',
  );
}

describe("c-workflow-schedule-manager time zone selector", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("renders the zone combobox with a UTC default option plus supported zones", async () => {
    const element = await openEditor();

    const combo = zoneCombobox(element);
    expect(combo).not.toBeNull();

    const values = combo.options.map((o) => o.value);
    // Blank UTC default is first, followed by every supported id.
    expect(combo.options[0]).toEqual({ label: "UTC (default)", value: "" });
    expect(values).toContain("America/New_York");
    expect(values).toContain("Asia/Tokyo");
    // New schedules default to the blank (UTC) selection.
    expect(combo.value).toBe("");
  });

  it("passes the selected timeZone to previewCron when the zone changes", async () => {
    const element = await openEditor();

    // A cron must be present before the preview fires.
    const cronInput = element.shadowRoot.querySelector(
      'lightning-input[data-field="Cron_Expression__c"]',
    );
    cronInput.dispatchEvent(
      new CustomEvent("change", { detail: { value: "0 2 * * *" } }),
    );
    await flushPromises();
    previewCron.mockClear();

    const combo = zoneCombobox(element);
    combo.dispatchEvent(
      new CustomEvent("change", { detail: { value: "America/New_York" } }),
    );
    await flushPromises();

    expect(previewCron).toHaveBeenCalledWith({
      cron: "0 2 * * *",
      timeZone: "America/New_York",
    });
  });

  it("disables Save when the selected zone is not supported", async () => {
    const element = await openEditor();

    // Fill the other required fields so only the zone drives saveDisabled.
    const setField = (field, value) => {
      const input = element.shadowRoot.querySelector(`[data-field="${field}"]`);
      input.dispatchEvent(new CustomEvent("change", { detail: { value } }));
    };
    setField("Name", "Nightly");
    setField("Workflow_Name__c", "MyWorkflow");
    setField("Correlation_Key_Prefix__c", "nightly");
    setField("Cron_Expression__c", "0 2 * * *");
    await flushPromises();

    const findSave = () =>
      Array.from(
        element.shadowRoot.querySelectorAll("lightning-button"),
      ).find((b) => b.label === "Save");

    // A supported zone keeps Save enabled.
    zoneCombobox(element).dispatchEvent(
      new CustomEvent("change", { detail: { value: "America/New_York" } }),
    );
    await flushPromises();
    expect(findSave().disabled).toBe(false);

    // An unsupported zone (e.g. from a stale/API value) disables Save.
    zoneCombobox(element).dispatchEvent(
      new CustomEvent("change", { detail: { value: "Not/AZone" } }),
    );
    await flushPromises();
    expect(findSave().disabled).toBe(true);
  });
});
