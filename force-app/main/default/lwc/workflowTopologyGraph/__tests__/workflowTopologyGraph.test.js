import { createElement } from "lwc";
import WorkflowTopologyGraph from "c/workflowTopologyGraph";
import getWorkflowTopology from "@salesforce/apex/WorkflowTopologyController.getWorkflowTopology";
import getInstanceTopology from "@salesforce/apex/WorkflowTopologyController.getInstanceTopology";

jest.mock(
  "@salesforce/apex/WorkflowTopologyController.getWorkflowTopology",
  () => ({ default: jest.fn() }),
  { virtual: true },
);
jest.mock(
  "@salesforce/apex/WorkflowTopologyController.getInstanceTopology",
  () => ({ default: jest.fn() }),
  { virtual: true },
);

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

const V = "OrderFlow.Validate";
const R = "OrderFlow.Review";
const S = "OrderFlow.Reserve";
const H = "OrderFlow.Ship";

const node = (name, label, extra = {}) => ({
  name,
  label,
  declared: true,
  initial: false,
  terminal: false,
  compensatable: false,
  routingUnknown: false,
  reachable: true,
  ...extra,
});

function graph(overrides = {}) {
  return {
    workflowName: "OrderFlow",
    initialStep: V,
    nodes: [
      node(V, "Validate", { initial: true }),
      node(R, "Review", { routingUnknown: true, reachable: false }),
      node(S, "Reserve", { compensatable: true }),
      node(H, "Ship", { terminal: true }),
    ],
    edges: [
      { source: V, target: S },
      { source: S, target: H },
    ],
    gapsFound: true,
    incompleteReasons: ["ROUTING_THREW", "UNREACHED_STEPS"],
    defects: [],
    overlay: null,
    ...overrides,
  };
}

function overlay(overrides = {}) {
  return {
    instanceId: "a0G000000000001",
    instanceStatus: "Suspended",
    currentSteps: [R],
    currentState: "AWAITING_SIGNAL",
    path: [
      { stepName: V, status: "Completed", compensation: false },
      { stepName: R, status: "Pending", compensation: false },
    ],
    nextSteps: [],
    pathTruncated: false,
    ...overrides,
  };
}

async function render(props, result) {
  const mock = props.instanceId ? getInstanceTopology : getWorkflowTopology;
  if (result instanceof Error) {
    mock.mockRejectedValue(result);
  } else {
    mock.mockResolvedValue(result);
  }
  const element = createElement("c-workflow-topology-graph", {
    is: WorkflowTopologyGraph,
  });
  Object.assign(element, props);
  document.body.appendChild(element);
  await flushPromises();
  return element;
}

const q = (element, id) =>
  element.shadowRoot.querySelector(`[data-id="${id}"]`);
const qa = (element, id) =>
  Array.from(element.shadowRoot.querySelectorAll(`[data-id="${id}"]`));
const nodeEl = (element, name) =>
  element.shadowRoot.querySelector(
    `[data-id="topology-node"][data-name="${name}"]`,
  );
const classesOf = (el) => el.getAttribute("class") || "";

describe("c-workflow-topology-graph", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("shows a loading state before the read returns", () => {
    getWorkflowTopology.mockReturnValue(new Promise(() => {}));
    const element = createElement("c-workflow-topology-graph", {
      is: WorkflowTopologyGraph,
    });
    element.workflowName = "OrderFlow";
    document.body.appendChild(element);
    expect(q(element, "topology-loading")).not.toBeNull();
  });

  it("does not call Apex without a workflow name or an instance id", async () => {
    const element = createElement("c-workflow-topology-graph", {
      is: WorkflowTopologyGraph,
    });
    document.body.appendChild(element);
    await flushPromises();
    expect(getWorkflowTopology).not.toHaveBeenCalled();
    expect(getInstanceTopology).not.toHaveBeenCalled();
  });

  it("reads the definition graph and draws one node for each step", async () => {
    const element = await render({ workflowName: "OrderFlow" }, graph());

    expect(getWorkflowTopology).toHaveBeenCalledWith({
      workflowName: "OrderFlow",
    });
    expect(qa(element, "topology-node")).toHaveLength(4);
    expect(qa(element, "topology-edge")).toHaveLength(2);
    expect(nodeEl(element, V).textContent).toContain("Validate");
  });

  it("marks the initial, terminal, rollback and unknown steps", async () => {
    const element = await render({ workflowName: "OrderFlow" }, graph());

    expect(classesOf(nodeEl(element, V))).toContain("node-initial");
    expect(classesOf(nodeEl(element, H))).toContain("node-terminal");
    expect(classesOf(nodeEl(element, S))).toContain("node-compensatable");
    expect(nodeEl(element, S).textContent).toContain("Rollback");
    expect(classesOf(nodeEl(element, R))).toContain("node-unknown");
    expect(classesOf(nodeEl(element, R))).toContain("node-unreached");
    expect(classesOf(nodeEl(element, S))).not.toContain("node-terminal");
  });

  it("shows the incomplete notice with its reasons", async () => {
    const element = await render({ workflowName: "OrderFlow" }, graph());

    const notice = q(element, "topology-notice");
    expect(notice).not.toBeNull();
    expect(notice.textContent).toContain("Routing is not fully known");
    const reasons = qa(element, "topology-reason").map((r) => r.textContent);
    expect(reasons).toHaveLength(2);
    expect(reasons.join(" ")).toContain("getNextStep");
    expect(q(element, "topology-best-effort")).not.toBeNull();
  });

  it("shows no notice for a fully known graph but keeps the best-effort caption", async () => {
    const element = await render(
      { workflowName: "OrderFlow" },
      graph({ gapsFound: false, incompleteReasons: [] }),
    );

    expect(q(element, "topology-notice")).toBeNull();
    expect(q(element, "topology-best-effort")).not.toBeNull();
  });

  it("lists each step with its known next steps as text", async () => {
    const element = await render({ workflowName: "OrderFlow" }, graph());

    const rows = qa(element, "topology-row");
    expect(rows).toHaveLength(4);
    const validate = rows.find((r) => r.dataset.name === V);
    expect(validate.textContent).toContain("Reserve");
    const review = rows.find((r) => r.dataset.name === R);
    expect(review.textContent).toContain("Not known");
    const ship = rows.find((r) => r.dataset.name === H);
    expect(ship.textContent).toContain("Run can end");
  });

  it("shows the defects of the definition", async () => {
    const element = await render(
      { workflowName: "OrderFlow" },
      graph({
        defects: ['Step "A" can transition to "Ghost", which is not declared.'],
        nodes: [
          node(V, "Validate", { initial: true }),
          node("Ghost", "Ghost", { declared: false, reachable: true }),
        ],
        edges: [{ source: V, target: "Ghost" }],
      }),
    );

    expect(qa(element, "topology-defect")).toHaveLength(1);
    expect(classesOf(nodeEl(element, "Ghost"))).toContain("node-undeclared");
  });

  it("shortens a long label on the node but keeps the full name", async () => {
    const long = "OrderFlow.ValidateCustomerCreditLimitAndAddressStep";
    const element = await render(
      { workflowName: "OrderFlow" },
      graph({
        nodes: [
          node(long, "ValidateCustomerCreditLimitAndAddressStep", {
            initial: true,
            compensatable: true,
            terminal: true,
            routingUnknown: true,
          }),
        ],
        edges: [],
      }),
    );
    const el = nodeEl(element, long);
    const label = el.querySelector(".node-label").textContent;
    expect(label.length).toBeLessThanOrEqual(24);
    expect(label.endsWith("…")).toBe(true);
    expect(el.querySelector("title").textContent).toBe(long);
    expect(el.querySelector(".node-badges").textContent).toContain("?");
  });

  it("shows an empty state for a graph with no step", async () => {
    const element = await render(
      { workflowName: "Missing" },
      graph({
        nodes: [],
        edges: [],
        incompleteReasons: ["DEFINITION_UNRESOLVED"],
      }),
    );
    expect(q(element, "topology-empty")).not.toBeNull();
    expect(q(element, "topology-svg")).toBeNull();
    expect(q(element, "topology-notice")).not.toBeNull();
  });

  it("clears the graph and ignores a late answer when the inputs are cleared", async () => {
    let resolveOld;
    getWorkflowTopology.mockReturnValueOnce(
      new Promise((resolve) => {
        resolveOld = resolve;
      }),
    );
    const element = createElement("c-workflow-topology-graph", {
      is: WorkflowTopologyGraph,
    });
    element.workflowName = "OrderFlow";
    document.body.appendChild(element);
    element.workflowName = null;
    resolveOld(graph());
    await flushPromises();

    expect(qa(element, "topology-node")).toHaveLength(0);
    expect(q(element, "topology-loading")).toBeNull();
  });

  it("shows an error when the read fails", async () => {
    const element = await render(
      { workflowName: "OrderFlow" },
      Object.assign(new Error("x"), { body: { message: "Unauthorized" } }),
    );

    const error = q(element, "topology-error");
    expect(error).not.toBeNull();
    expect(error.textContent).toContain("Unauthorized");
    expect(q(element, "topology-loading")).toBeNull();
  });

  describe("with an instance", () => {
    it("reads by instance id and highlights the current step", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay() }),
      );

      expect(getInstanceTopology).toHaveBeenCalledWith(
        expect.objectContaining({ instanceId: "a0G000000000001" }),
      );
      expect(getWorkflowTopology).not.toHaveBeenCalled();
      expect(classesOf(nodeEl(element, R))).toContain("node-current");
      expect(classesOf(nodeEl(element, R))).toContain("state-awaiting");
      expect(classesOf(nodeEl(element, V))).toContain("node-visited");
      expect(classesOf(nodeEl(element, H))).not.toContain("node-visited");
    });

    it("gives the answer in the summary: where, state, what advances it, next", async () => {
      const element = await render(
        {
          instanceId: "a0G000000000001",
          waitDescriptor: {
            type: "approval",
            signalName: "Approve:Review",
            label: "Approve:Review",
            stepName: R,
          },
        },
        graph({ overlay: overlay() }),
      );

      expect(q(element, "summary-current").textContent).toContain("Review");
      expect(q(element, "summary-state").textContent).toBe(
        "Suspended, awaiting a signal",
      );
      expect(q(element, "summary-awaiting").textContent).toContain(
        "Approve:Review",
      );
      expect(q(element, "summary-next").textContent).toContain(
        "No next step is known",
      );
      expect(q(element, "summary-next-caveat")).not.toBeNull();
    });

    it("shows the awaited signal on the current node", async () => {
      const element = await render(
        {
          instanceId: "a0G000000000001",
          waitDescriptor: { label: "Approve:Review", stepName: R },
        },
        graph({ overlay: overlay() }),
      );

      expect(nodeEl(element, R).textContent).toContain("Approve:Review");
    });

    it("treats a timed approval as a signal wait when the #84 descriptor is set", async () => {
      const element = await render(
        {
          instanceId: "a0G000000000001",
          waitDescriptor: { label: "Approve:Review", stepName: R },
        },
        graph({ overlay: overlay({ currentState: "SUSPENDED" }) }),
      );

      expect(q(element, "summary-state").textContent).toBe(
        "Suspended, awaiting a signal",
      );
      expect(q(element, "summary-awaiting").textContent).toContain(
        "Approve:Review",
      );
    });

    it("shows a timer wait with no descriptor as a timer wait", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay({ currentState: "SUSPENDED" }) }),
      );

      expect(q(element, "summary-state").textContent).toBe(
        "Suspended until a timer or a job ends",
      );
      expect(q(element, "summary-awaiting")).toBeNull();
      expect(classesOf(nodeEl(element, R))).toContain("state-suspended");
    });

    it("reloads when the instance id changes", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay() }),
      );
      element.instanceId = "a0G000000000002";
      await flushPromises();

      expect(getInstanceTopology).toHaveBeenLastCalledWith(
        expect.objectContaining({ instanceId: "a0G000000000002" }),
      );
    });

    it("hides the awaited signal when the state is not a signal wait", async () => {
      const element = await render(
        {
          instanceId: "a0G000000000001",
          waitDescriptor: { label: "Approve:Review", stepName: R },
        },
        graph({
          overlay: overlay({
            currentState: "FAILED",
            instanceStatus: "Failed",
          }),
        }),
      );

      expect(q(element, "summary-awaiting")).toBeNull();
      expect(q(element, "summary-state").textContent).toBe("Failed");
      expect(classesOf(nodeEl(element, R))).toContain("state-failed");
    });

    it("lists the known next steps of the current step", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          incompleteReasons: [],
          overlay: overlay({
            currentSteps: [S],
            currentState: "RUNNING",
            instanceStatus: "Running",
            nextSteps: [H],
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toContain("Ship");
      expect(q(element, "summary-next-caveat")).toBeNull();
      expect(q(element, "summary-state").textContent).toBe("Running");
    });

    // Issue #290: the overlay gives the step that routes, its end flag and
    // the reason when the next step is not known.
    const running = (extra) =>
      overlay({
        currentState: "RUNNING",
        instanceStatus: "Running",
        ...extra,
      });

    it("lists the steps after the join of a SPLIT", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          overlay: running({
            currentSteps: [S, R],
            nextStepsFrom: V,
            nextSteps: [H],
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "Ship (after the branches join)",
      );
      expect(q(element, "summary-next-caveat")).toBeNull();
    });

    it("says that a SPLIT can end after the join", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          overlay: running({
            currentSteps: [S, R],
            nextStepsFrom: V,
            nextSteps: [],
            canEnd: true,
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "None. The run can end after the branches join.",
      );
    });

    it("says not known when the step that started a SPLIT is not known", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          nodes: [
            node(V, "Validate", { initial: true }),
            node(S, "Reserve", { terminal: true }),
            node(H, "Ship", { terminal: true }),
          ],
          overlay: running({
            currentSteps: [S, H],
            nextSteps: [],
            nextStepsUnknownReason: "SPAWNING_STEP_UNKNOWN",
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "No next step is known.",
      );
      expect(q(element, "summary-next-caveat").textContent).toContain(
        "started the parallel branches",
      );
    });

    it("uses the route of the run version, not the end mark of the node", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          overlay: running({
            currentSteps: [H],
            nextStepsFrom: H,
            nextSteps: [],
            canEnd: false,
            nextStepsUnknownReason: "ROUTING_UNKNOWN",
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "No next step is known.",
      );
      expect(q(element, "summary-next-caveat").textContent).toContain(
        "version of this run",
      );
    });

    it("says that the run can also end when steps follow", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          overlay: running({
            currentSteps: [S],
            nextStepsFrom: S,
            nextSteps: [H],
            canEnd: true,
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "Ship (or the run can end)",
      );
    });

    it("says that no current step is known", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: running({
            currentSteps: [],
            nextSteps: [],
            nextStepsUnknownReason: "ROUTING_UNKNOWN",
          }),
        }),
      );

      expect(q(element, "summary-next-caveat").textContent).toContain(
        "No current step is known.",
      );
    });

    it("names the step with no known route", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: running({
            currentSteps: [S, R],
            nextStepsFrom: V,
            nextSteps: [],
            nextStepsUnknownReason: "ROUTING_UNKNOWN",
          }),
        }),
      );

      expect(q(element, "summary-next-caveat").textContent).toContain(
        "No route is known from Validate",
      );
    });

    it("shows the default caveat for an unknown reason code", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: running({
            nextSteps: [],
            nextStepsUnknownReason: "toString",
          }),
        }),
      );

      expect(q(element, "summary-next-caveat").textContent).toContain(
        "Step output can route to other steps.",
      );
    });

    it("says that the run can end at the current step", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          gapsFound: false,
          overlay: running({
            currentSteps: [S],
            nextStepsFrom: S,
            nextSteps: [],
            canEnd: true,
          }),
        }),
      );

      expect(q(element, "summary-next").textContent).toBe(
        "None. The run can end here.",
      );
      expect(q(element, "summary-next-caveat")).toBeNull();
    });

    it("draws the path in order and marks no edge as used", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentSteps: [H],
            currentState: "ENDED",
            instanceStatus: "Completed",
            path: [
              { stepName: V, status: "Completed", compensation: false },
              { stepName: S, status: "Completed", compensation: false },
              { stepName: H, status: "Completed", compensation: false },
              { stepName: S, status: "Compensated", compensation: true },
            ],
          }),
        }),
      );

      const entries = qa(element, "topology-path-entry");
      expect(entries).toHaveLength(4);
      expect(entries[0].textContent).toContain("1");
      expect(entries[0].textContent).toContain("Validate");
      expect(entries[3].textContent).toContain("Rollback");
      const edges = qa(element, "topology-edge");
      expect(edges.some((e) => classesOf(e).includes("edge-traversed"))).toBe(
        false,
      );
      expect(classesOf(nodeEl(element, S))).toContain("node-compensated");
    });

    it("sends a new cache key on each read of an instance", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay() }),
      );
      const first = getInstanceTopology.mock.calls[0][0].cacheBuster;
      await new Promise((resolve) => setTimeout(resolve, 2));
      element.refresh();
      await flushPromises();
      const second = getInstanceTopology.mock.calls[1][0].cacheBuster;
      expect(first).toBeTruthy();
      expect(second).not.toBe(first);
    });

    it("refresh() reads the live position and keeps the graph on screen", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay() }),
      );
      let resolveNext;
      getInstanceTopology.mockReturnValue(
        new Promise((resolve) => {
          resolveNext = resolve;
        }),
      );
      element.refresh();
      await flushPromises();
      expect(q(element, "topology-loading")).toBeNull();
      expect(qa(element, "topology-node")).toHaveLength(4);

      resolveNext(
        graph({
          overlay: overlay({
            currentSteps: [H],
            currentState: "ENDED",
            instanceStatus: "Completed",
          }),
        }),
      );
      await flushPromises();
      expect(q(element, "summary-current").textContent).toContain("Ship");
      expect(q(element, "summary-next").textContent).toBe(
        "None. The run has ended.",
      );
      expect(q(element, "summary-next-caveat")).toBeNull();
    });

    it("ignores an old answer that comes after a new one", async () => {
      let resolveOld;
      getInstanceTopology.mockReturnValueOnce(
        new Promise((resolve) => {
          resolveOld = resolve;
        }),
      );
      const element = createElement("c-workflow-topology-graph", {
        is: WorkflowTopologyGraph,
      });
      element.instanceId = "a0G000000000001";
      document.body.appendChild(element);
      getInstanceTopology.mockResolvedValueOnce(
        graph({ overlay: overlay({ currentSteps: [S] }) }),
      );
      element.instanceId = "a0G000000000002";
      await flushPromises();
      resolveOld(graph({ overlay: overlay({ currentSteps: [V] }) }));
      await flushPromises();

      expect(q(element, "summary-current").textContent).toContain("Reserve");
    });

    it("says that a parked rollback has no next step", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentSteps: [S],
            currentState: "SUSPENDED",
            instanceStatus: "Suspended",
            path: [
              { stepName: S, status: "Completed", compensation: false },
              { stepName: S, status: "Pending", compensation: true },
            ],
            nextSteps: [],
          }),
        }),
      );
      expect(q(element, "summary-next").textContent).toBe(
        "None. The rollback runs.",
      );
      expect(q(element, "summary-next-caveat")).toBeNull();
    });

    it("says that a rollback has no next step", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentState: "COMPENSATING",
            instanceStatus: "Compensating",
            nextSteps: [H],
          }),
        }),
      );
      expect(q(element, "summary-next").textContent).toBe(
        "None. The rollback runs.",
      );
      expect(q(element, "summary-state").textContent).toBe("Rollback runs");
    });

    it("ignores a descriptor for a different step", async () => {
      const element = await render(
        {
          instanceId: "a0G000000000001",
          waitDescriptor: { label: "Approve:Old", stepName: V },
        },
        graph({ overlay: overlay() }),
      );
      expect(q(element, "summary-awaiting")).toBeNull();
      expect(nodeEl(element, R).textContent).not.toContain("Approve:Old");
    });

    it("writes the state as text on the current node", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentState: "FAILED",
            instanceStatus: "Failed",
          }),
        }),
      );
      expect(nodeEl(element, R).textContent).toContain("Now: failed");
    });

    it("highlights each branch of a SPLIT as current", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentSteps: [S, H],
            currentState: "RUNNING",
            instanceStatus: "Running",
          }),
        }),
      );
      expect(classesOf(nodeEl(element, S))).toContain("node-current");
      expect(classesOf(nodeEl(element, H))).toContain("node-current");
      expect(q(element, "summary-current").textContent).toContain(
        "Reserve, Ship",
      );
    });

    it("flags a truncated path", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({ overlay: overlay({ pathTruncated: true }) }),
      );
      expect(q(element, "topology-truncated")).not.toBeNull();
    });
  });
});
