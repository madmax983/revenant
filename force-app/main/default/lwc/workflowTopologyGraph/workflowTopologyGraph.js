/**
 * Workflow topology graph (#141). It draws the steps and the known edges of a
 * definition. With an instance id, it also shows the path of the instance,
 * the current step and its state. Apex gives the data. The graph is
 * best-effort: step output can route to steps that the probe did not find.
 * A notice shows each gap that Apex finds. The component reads on connect,
 * when an input changes, and when the parent calls refresh().
 */
import { LightningElement, api } from "lwc";
import getWorkflowTopology from "@salesforce/apex/WorkflowTopologyController.getWorkflowTopology";
import getInstanceTopology from "@salesforce/apex/WorkflowTopologyController.getInstanceTopology";
import { layoutGraph } from "c/topologyLayout";

const AWAITING = "AWAITING_SIGNAL";
const SUSPENDED = "SUSPENDED";

const ENDED = "ENDED";
const COMPENSATING = "COMPENSATING";

const STATE_LABELS = {
  RUNNING: "Running",
  AWAITING_SIGNAL: "Suspended, awaiting a signal",
  SUSPENDED: "Suspended until a timer or a job ends",
  FAILED: "Failed",
  COMPENSATING: "Rollback runs",
  PARKED: "Parked",
  ENDED: "Ended",
};

// Text on the current node, so the state does not rely on color.
const STATE_MARKS = {
  RUNNING: "Now: running",
  AWAITING_SIGNAL: "Now: awaiting a signal",
  SUSPENDED: "Now: waiting",
  FAILED: "Now: failed",
  COMPENSATING: "Now: rollback",
  PARKED: "Now: parked",
  ENDED: "Ended here",
};

// Maximum characters on one line of a node (the full name is in the tooltip).
const LABEL_CHARS = 24;
const LINE_CHARS = 30;

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
  ROUTING_VARIES:
    'getNextStep gave different successors for the probes. The routes of the steps marked "?" depend on step output.',
  UNREACHED_STEPS:
    "Some steps have no known route from the initial step. Step output can route to them, or no route exists.",
  UNDECLARED_STEPS:
    "A route or the run goes to a step that getSteps() does not declare.",
  VERSIONS_UNRESOLVED:
    "getLatestVersion() threw. The routes of the versions are not known.",
  VERSIONS_CAPPED:
    "The probe read only the newest versions. The routes of older versions are not in the graph.",
};

// Issue #290: why the overlay gives no next step.
const NEXT_CAVEATS = {
  SPAWNING_STEP_UNKNOWN:
    "No step row shows the step that started the parallel branches. The step after the join is not known.",
};
const DEFAULT_NEXT_CAVEAT =
  "Step output can route to other steps. This list shows only the routes that the probe found.";

// Own keys only, so a code such as "toString" shows as it is.
const labelFor = (labels, code) =>
  Object.prototype.hasOwnProperty.call(labels, code) ? labels[code] : code;
const list = (value) => (Array.isArray(value) ? value : []);
const shortName = (name) =>
  typeof name === "string" && name.includes(".")
    ? name.substring(name.lastIndexOf(".") + 1)
    : name;
const fit = (text, max) =>
  typeof text === "string" && text.length > max
    ? `${text.substring(0, max - 1)}…`
    : text;

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
  _scrolledFor = null;

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

  // Scrolls a large graph so that the current step is in view, once per read.
  renderedCallback() {
    const current = this.currentSteps[0];
    const canvas = this.template.querySelector('[data-id="topology-canvas"]');
    if (!current || !canvas || this._scrolledFor === this.graph) {
      return;
    }
    this._scrolledFor = this.graph;
    const pos = this.layout.nodes.find((n) => n.name === current);
    if (pos) {
      canvas.scrollLeft = Math.max(
        0,
        pos.x + pos.width / 2 - canvas.clientWidth / 2,
      );
      canvas.scrollTop = Math.max(
        0,
        pos.y + pos.height / 2 - canvas.clientHeight / 2,
      );
    }
  }

  /** Reads the graph again. The current graph stays on screen until then. */
  @api
  refresh() {
    if (this._connected) {
      this.load(true);
    }
  }

  reload() {
    if (this._connected) {
      this.load(false);
    }
  }

  load(quiet) {
    // Ignore a late answer to an old request.
    const token = ++this._request;
    let request;
    if (this._instanceId) {
      // The endpoint is cacheable, so the platform enforces read-only. A new
      // key reads the live position.
      request = getInstanceTopology({
        instanceId: this._instanceId,
        cacheBuster: String(Date.now()),
      });
    } else if (this._workflowName) {
      request = getWorkflowTopology({ workflowName: this._workflowName });
    } else {
      this.setGraph(null);
      this.loading = false;
      return;
    }
    this.loading = !quiet;
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

  // A timed approval has a #84 descriptor and a timer. When the descriptor
  // is for the current step, show a signal wait.
  get effectiveState() {
    const state = this.overlay ? this.overlay.currentState : null;
    return state === SUSPENDED && this.awaitedLabel ? AWAITING : state;
  }

  // The descriptor applies only to the current step. The detail view and
  // the graph can read at different times.
  get awaitedLabel() {
    const d = this._waitDescriptor;
    if (!d || !d.label || !this.overlay) {
      return null;
    }
    return !d.stepName || this.currentSteps.includes(d.stepName)
      ? d.label
      : null;
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
    return this.hasGraph && this.graph.gapsFound === true;
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

  // One entry for each SPLIT branch.
  get currentSteps() {
    return list(this.overlay && this.overlay.currentSteps);
  }

  get currentNodes() {
    const byName = this.nodeByName;
    return this.currentSteps.map((name) => byName.get(name)).filter(Boolean);
  }

  get currentLabel() {
    const names = this.currentSteps;
    return names.length
      ? names.map((name) => this.labelOf(name)).join(", ")
      : "Not known";
  }

  get stateLabel() {
    return labelFor(STATE_LABELS, this.effectiveState);
  }

  // A rollback runs, or it is parked when its newest row is a compensation row.
  get inRollback() {
    if (this.effectiveState === COMPENSATING) {
      return true;
    }
    const path = list(this.overlay && this.overlay.path);
    return (
      this.effectiveState !== ENDED &&
      path.length > 0 &&
      path[path.length - 1].compensation === true
    );
  }

  // The step that the engine routes from (issue #290). For a SPLIT it is the
  // step that started the branches.
  get nextFromNodes() {
    const from = this.overlay && this.overlay.nextStepsFrom;
    if (!from) {
      return this.currentNodes;
    }
    const n = this.nodeByName.get(from);
    return n ? [n] : [];
  }

  // True when the next steps come after the join of a SPLIT.
  get nextAfterJoin() {
    const from = this.overlay && this.overlay.nextStepsFrom;
    return Boolean(from) && !this.currentSteps.includes(from);
  }

  get nextLabel() {
    if (this.effectiveState === ENDED) {
      return "None. The run has ended.";
    }
    if (this.inRollback) {
      return "None. The rollback runs.";
    }
    const overlay = this.overlay || {};
    const join = this.nextAfterJoin;
    const next = list(overlay.nextSteps);
    if (next.length > 0) {
      let text = next.map((name) => this.labelOf(name)).join(", ");
      if (overlay.canEnd === true) {
        text += " (or the run can end)";
      }
      return join ? `${text} (after the branches join)` : text;
    }
    if (!overlay.nextStepsUnknownReason && overlay.canEnd === true) {
      return join
        ? "None. The run can end after the branches join."
        : "None. The run can end here.";
    }
    return "No next step is known.";
  }

  get showNextCaveat() {
    if (this.effectiveState === ENDED || this.inRollback) {
      return false;
    }
    if (this.overlay && this.overlay.nextStepsUnknownReason) {
      return true;
    }
    const nodes = this.nextFromNodes;
    return (
      this.graph.gapsFound === true ||
      nodes.length === 0 ||
      nodes.some((n) => n.routingUnknown === true)
    );
  }

  get nextCaveat() {
    const overlay = this.overlay || {};
    const reason = overlay.nextStepsUnknownReason;
    if (reason === "ROUTING_UNKNOWN") {
      return overlay.nextStepsFrom
        ? `No route is known from ${this.labelOf(overlay.nextStepsFrom)} for the version of this run.`
        : "No current step is known.";
    }
    return reason && Object.prototype.hasOwnProperty.call(NEXT_CAVEATS, reason)
      ? NEXT_CAVEATS[reason]
      : DEFAULT_NEXT_CAVEAT;
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
    const steps = count === 1 ? "1 step" : `${count} steps`;
    return `Graph of ${steps} of ${this.graph ? this.graph.workflowName : ""}. The table below lists the same routes as text.`;
  }

  get nodeViews() {
    const byName = this.nodeByName;
    const { seen, compensated } = this.visited;
    const current = new Set(this.currentSteps);
    const stateClass = labelFor(STATE_CLASSES, this.effectiveState);
    return this.layout.nodes.map((pos) => {
      const n = byName.get(pos.name);
      const isCurrent = current.has(pos.name);
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
        badges.push("End");
      }
      if (n.routingUnknown) {
        classes.push("node-unknown");
        badges.push("?");
      }
      if (!n.reachable) {
        classes.push("node-unreached");
      }
      if (!n.declared) {
        classes.push("node-undeclared");
        badges.push("Undeclared");
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
      let mark = null;
      if (isCurrent) {
        mark = this.isAwaiting
          ? `▶ Awaiting: ${this.awaitedLabel}`
          : `▶ ${labelFor(STATE_MARKS, this.effectiveState)}`;
      }
      return {
        key: pos.name,
        name: pos.name,
        label: fit(n.label, LABEL_CHARS),
        title: n.name,
        width: pos.width,
        height: pos.height,
        transform: `translate(${pos.x}, ${pos.y})`,
        cssClass: classes.join(" "),
        badges: fit(badges.join(" · "), LINE_CHARS),
        mark: fit(mark, LINE_CHARS),
      };
    });
  }

  // Edges do not show which one the run used: the step rows have no branch
  // data, so two adjacent rows do not prove a transition.
  get edgeViews() {
    return this.layout.edges.map((e) => ({
      key: e.key,
      d: e.d,
      arrow: e.arrow,
      cssClass: e.back ? "topology-edge edge-side" : "topology-edge",
      arrowClass: "topology-arrow",
    }));
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
