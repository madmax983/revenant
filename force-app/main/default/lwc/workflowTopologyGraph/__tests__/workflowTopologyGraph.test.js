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
    routingFullyKnown: false,
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
    currentStep: R,
    currentState: "AWAITING_SIGNAL",
    path: [
      { stepName: V, status: "Completed", compensation: false },
      { stepName: R, status: "Pending", compensation: false },
    ],
    traversedEdges: [],
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
      graph({ routingFullyKnown: true, incompleteReasons: [] }),
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

      expect(getInstanceTopology).toHaveBeenCalledWith({
        instanceId: "a0G000000000001",
      });
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
        "Suspended, waiting on a timer",
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

      expect(getInstanceTopology).toHaveBeenLastCalledWith({
        instanceId: "a0G000000000002",
      });
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
          routingFullyKnown: true,
          incompleteReasons: [],
          overlay: overlay({
            currentStep: S,
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

    it("draws the path in order and highlights traversed edges", async () => {
      const element = await render(
        { instanceId: "a0G000000000001" },
        graph({
          overlay: overlay({
            currentStep: H,
            currentState: "ENDED",
            instanceStatus: "Completed",
            path: [
              { stepName: V, status: "Completed", compensation: false },
              { stepName: S, status: "Completed", compensation: false },
              { stepName: H, status: "Completed", compensation: false },
              { stepName: S, status: "Compensated", compensation: true },
            ],
            traversedEdges: [
              { source: V, target: S },
              { source: S, target: H },
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
      expect(edges.every((e) => classesOf(e).includes("edge-traversed"))).toBe(
        true,
      );
      expect(classesOf(nodeEl(element, S))).toContain("node-compensated");
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
