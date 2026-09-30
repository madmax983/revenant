/**
 * Workflow topology graph (#141). It draws the steps and the known edges of a
 * definition. With an instance id, it also shows the path of the instance,
 * the current step and its state. Apex gives the data. The graph is
 * best-effort: step output can route to steps that the probe did not find.
 * The component says so. It reads once on connect and when an input changes.
 */
import { LightningElement, api } from "lwc";
import getWorkflowTopology from "@salesforce/apex/WorkflowDashboardController.getWorkflowTopology";
import getInstanceTopology from "@salesforce/apex/WorkflowDashboardController.getInstanceTopology";
import { layoutGraph } from "c/topologyLayout";

const AWAITING = "AWAITING_SIGNAL";
const SUSPENDED = "SUSPENDED";

const STATE_LABELS = {
  RUNNING: "Running",
  AWAITING_SIGNAL: "Suspended, awaiting a signal",
  SUSPENDED: "Suspended, waiting on a timer",
  FAILED: "Failed",
  COMPENSATING: "Rollback in progress",
  PARKED: "Parked",
  ENDED: "Ended",
};

const STATE_CLASSES = {
  RUNNING: "state-running",
  AWAITING_SIGNAL: "state-awaiting",
  SUSPENDED: "state-suspended",
  FAILED: "state-failed",
  COMPENSATING: "state-compensating",
  PARKED: "state-parked",
  ENDED: "state-ended",
};

const REASON_LABELS = {
  DEFINITION_UNRESOLVED:
    "The definition did not resolve, or it declares no step.",
  ROUTING_THREW:
    'getNextStep threw for a probe. The routes of the steps marked "?" are not known.',
  UNREACHED_STEPS:
    "Some steps have no known route from the initial step. Only step output can route to them.",
  UNDECLARED_STEPS:
    "A route or the run goes to a step that getSteps() does not declare.",
  VERSIONS_UNRESOLVED:
    "getLatestVersion() threw. The routes of the versions are not known.",
};

// Own keys only, so a code such as "toString" shows as it is.
const labelFor = (labels, code) =>
  Object.prototype.hasOwnProperty.call(labels, code) ? labels[code] : code;
const list = (value) => (Array.isArray(value) ? value : []);
const shortName = (name) =>
  typeof name === "string" && name.includes(".")
    ? name.substring(name.lastIndexOf(".") + 1)
    : name;

export default class WorkflowTopologyGraph extends LightningElement {
  graph = null;
  layout = layoutGraph(null);
  error = null;
  loading = false;

  _workflowName;
  _instanceId;
  _waitDescriptor;
  _connected = false;
  _request = 0;

  /** The definition to draw. Not used when instanceId is set. */
  @api
  get workflowName() {
    return this._workflowName;
  }
  set workflowName(value) {
    this._workflowName = value;
    this.reload();
  }

  /** The instance to draw. Its definition and path are read from Apex. */
  @api
  get instanceId() {
    return this._instanceId;
  }
  set instanceId(value) {
    this._instanceId = value;
    this.reload();
  }

  /** The #84 awaited-signal descriptor that the detail view already read. */
  @api
  get waitDescriptor() {
    return this._waitDescriptor;
  }
  set waitDescriptor(value) {
    this._waitDescriptor = value;
  }

  connectedCallback() {
    this._connected = true;
    this.load();
  }

  disconnectedCallback() {
    this._connected = false;
  }

  reload() {
    if (this._connected) {
      this.load();
    }
  }

  load() {
    let request;
    if (this._instanceId) {
      request = getInstanceTopology({ instanceId: this._instanceId });
    } else if (this._workflowName) {
      request = getWorkflowTopology({ workflowName: this._workflowName });
    } else {
      this.setGraph(null);
      return;
    }
    // Ignore a late answer to an old request.
    const token = ++this._request;
    this.loading = true;
    this.error = null;
    request
      .then((result) => {
        if (token !== this._request) {
          return;
        }
        this.setGraph(result || null);
        if (!this.graph) {
          this.error = "No data was returned.";
        }
      })
      .catch((err) => {
        if (token !== this._request) {
          return;
        }
        this.setGraph(null);
        this.error = this.reduceError(err);
      })
      .finally(() => {
        if (token === this._request) {
          this.loading = false;
        }
      });
  }

  setGraph(graph) {
    this.graph = graph;
    this.layout = layoutGraph(graph);
  }

  reduceError(err) {
    if (err && err.body && err.body.message) {
      return err.body.message;
    }
    return (err && err.message) || "Unknown error";
  }

  // ---- Graph data ----

  get hasGraph() {
    return !this.loading && !!this.graph;
  }

  get overlay() {
    return (this.graph && this.graph.overlay) || null;
  }

  get hasOverlay() {
    return !!this.overlay;
  }

  get nodeByName() {
    const map = new Map();
    for (const n of list(this.graph && this.graph.nodes)) {
      map.set(n.name, n);
    }
    return map;
  }

  labelOf(name) {
    const n = this.nodeByName.get(name);
    return n && n.label ? n.label : shortName(name);
  }

  successorsOf(name) {
    return list(this.graph && this.graph.edges)
      .filter((e) => e.source === name)
      .map((e) => e.target);
  }

  // A timed approval keeps its #84 descriptor with a timer armed. The
  // descriptor of the detail view then wins over the timer state.
  get effectiveState() {
    const state = this.overlay ? this.overlay.currentState : null;
    return state === SUSPENDED && this.awaitedLabel ? AWAITING : state;
  }

  get awaitedLabel() {
    const d = this._waitDescriptor;
    return d && d.label ? d.label : null;
  }

  get isAwaiting() {
    return this.effectiveState === AWAITING && !!this.awaitedLabel;
  }

  get visited() {
    const seen = new Set();
    const compensated = new Set();
    for (const entry of list(this.overlay && this.overlay.path)) {
      seen.add(entry.stepName);
      if (entry.compensation) {
        compensated.add(entry.stepName);
      }
    }
    return { seen, compensated };
  }

  // ---- Notice ----

  get showNotice() {
    return this.hasGraph && this.graph.routingFullyKnown === false;
  }

  get reasonRows() {
    return list(this.graph && this.graph.incompleteReasons).map((code) => ({
      key: code,
      label: labelFor(REASON_LABELS, code),
    }));
  }

  get defectRows() {
    return list(this.graph && this.graph.defects).map((message, index) => ({
      key: `defect-${index}`,
      message,
    }));
  }

  get hasDefects() {
    return this.defectRows.length > 0;
  }

  get isEmpty() {
    return this.hasGraph && list(this.graph.nodes).length === 0;
  }

  // ---- Summary ----

  get currentNode() {
    return this.overlay ? this.nodeByName.get(this.overlay.currentStep) : null;
  }

  get currentLabel() {
    return this.overlay && this.overlay.currentStep
      ? this.labelOf(this.overlay.currentStep)
      : "Not known";
  }

  get stateLabel() {
    return labelFor(STATE_LABELS, this.effectiveState);
  }

  get nextLabel() {
    const next = list(this.overlay && this.overlay.nextSteps);
    if (next.length > 0) {
      return next.map((name) => this.labelOf(name)).join(", ");
    }
    const n = this.currentNode;
    if (n && n.terminal && !n.routingUnknown) {
      return "None. The run can end here.";
    }
    return "No next step is known.";
  }

  get showNextCaveat() {
    const n = this.currentNode;
    return (
      this.graph.routingFullyKnown === false || !n || n.routingUnknown === true
    );
  }

  // ---- SVG ----

  get svgWidth() {
    return this.layout.width;
  }

  get svgHeight() {
    return this.layout.height;
  }

  get viewBox() {
    return `0 0 ${this.layout.width} ${this.layout.height}`;
  }

  get svgLabel() {
    const count = list(this.graph && this.graph.nodes).length;
    return `Graph of ${count} steps of ${this.graph ? this.graph.workflowName : ""}. The table below lists the same routes as text.`;
  }

  get nodeViews() {
    const byName = this.nodeByName;
    const { seen, compensated } = this.visited;
    const current = this.overlay ? this.overlay.currentStep : null;
    const stateClass = labelFor(STATE_CLASSES, this.effectiveState);
    return this.layout.nodes.map((pos) => {
      const n = byName.get(pos.name);
      const isCurrent = pos.name === current;
      const classes = ["topology-node"];
      const badges = [];
      if (n.initial) {
        classes.push("node-initial");
        badges.push("Start");
      }
      if (n.compensatable) {
        classes.push("node-compensatable");
        badges.push("Rollback");
      }
      if (n.terminal) {
        classes.push("node-terminal");
        badges.push("Can end");
      }
      if (n.routingUnknown) {
        classes.push("node-unknown");
        badges.push("? Routing not known");
      }
      if (!n.reachable) {
        classes.push("node-unreached");
      }
      if (!n.declared) {
        classes.push("node-undeclared");
        badges.push("Not declared");
      }
      if (seen.has(pos.name)) {
        classes.push("node-visited");
      }
      if (compensated.has(pos.name)) {
        classes.push("node-compensated");
      }
      if (isCurrent) {
        classes.push("node-current", stateClass);
      }
      return {
        key: pos.name,
        name: pos.name,
        label: n.label,
        title: n.name,
        width: pos.width,
        height: pos.height,
        transform: `translate(${pos.x}, ${pos.y})`,
        cssClass: classes.join(" "),
        badges: badges.join(" · "),
        awaiting:
          isCurrent && this.isAwaiting
            ? `Awaiting: ${this.awaitedLabel}`
            : null,
      };
    });
  }

  get edgeViews() {
    const traversed = new Set(
      list(this.overlay && this.overlay.traversedEdges).map(
        (e) => `${e.source}->${e.target}`,
      ),
    );
    return this.layout.edges.map((e) => {
      const classes = ["topology-edge"];
      if (e.back) {
        classes.push("edge-side");
      }
      if (traversed.has(e.key)) {
        classes.push("edge-traversed");
      }
      return {
        key: e.key,
        d: e.d,
        arrow: e.arrow,
        cssClass: classes.join(" "),
        arrowClass: traversed.has(e.key)
          ? "topology-arrow edge-traversed"
          : "topology-arrow",
      };
    });
  }

  // ---- Text views ----

  get rows() {
    return list(this.graph && this.graph.nodes).map((n) => {
      const next = this.successorsOf(n.name).map((name) => this.labelOf(name));
      let nextText;
      if (n.routingUnknown) {
        nextText = next.length
          ? `${next.join(", ")} (other routes not known)`
          : "Not known";
      } else if (next.length) {
        nextText = n.terminal
          ? `${next.join(", ")} (or the run can end)`
          : next.join(", ");
      } else {
        nextText = n.terminal ? "Run can end" : "None found";
      }
      return { key: n.name, name: n.name, label: n.label, nextText };
    });
  }

  get pathRows() {
    return list(this.overlay && this.overlay.path).map((entry, index) => ({
      key: `path-${index}`,
      order: index + 1,
      label: this.labelOf(entry.stepName),
      status: entry.status,
      compensation: entry.compensation === true,
    }));
  }

  get hasPath() {
    return this.pathRows.length > 0;
  }

  get pathTruncated() {
    return !!(this.overlay && this.overlay.pathTruncated);
  }
}
