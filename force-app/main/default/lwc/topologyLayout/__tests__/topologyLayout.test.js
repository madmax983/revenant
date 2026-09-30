import {
  layoutGraph,
  NODE_WIDTH,
  NODE_HEIGHT,
  UNREACHED_PER_ROW,
} from "c/topologyLayout";

const node = (name, extra = {}) => ({
  name,
  label: name,
  declared: true,
  initial: false,
  terminal: false,
  compensatable: false,
  routingUnknown: false,
  reachable: true,
  ...extra,
});

const edge = (source, target) => ({ source, target });

const byName = (layout) =>
  Object.fromEntries(layout.nodes.map((n) => [n.name, n]));

describe("c/topologyLayout", () => {
  it("puts the initial step in the top row and successors below", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A", { initial: true }), node("B"), node("C")],
      edges: [edge("A", "B"), edge("B", "C")],
    });
    const n = byName(layout);
    expect(n.A.y).toBeLessThan(n.B.y);
    expect(n.B.y).toBeLessThan(n.C.y);
    expect(n.A.width).toBe(NODE_WIDTH);
    expect(n.A.height).toBe(NODE_HEIGHT);
  });

  // Gives the axis-aligned segments of an orthogonal path ("M x y V y H x ...").
  function segments(d) {
    const tokens = d.split(" ");
    let x = Number(tokens[1]);
    let y = Number(tokens[2]);
    const out = [];
    for (let i = 3; i < tokens.length; i += 2) {
      const [cmd, value] = [tokens[i], Number(tokens[i + 1])];
      const next = cmd === "V" ? { x, y: value } : { x: value, y };
      out.push([{ x, y }, next]);
      ({ x, y } = next);
    }
    return out;
  }

  // True when the segment goes into the inside of the box.
  function crosses([a, b], box) {
    const minX = Math.min(a.x, b.x);
    const maxX = Math.max(a.x, b.x);
    const minY = Math.min(a.y, b.y);
    const maxY = Math.max(a.y, b.y);
    return (
      maxX > box.x + 1 &&
      minX < box.x + box.width - 1 &&
      maxY > box.y + 1 &&
      minY < box.y + box.height - 1
    );
  }

  it("routes back, same-row and self-loop edges around every node box", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: ["A", "B", "C", "D", "E"].map((n) => node(n)),
      edges: [
        edge("A", "B"),
        edge("A", "C"),
        edge("A", "D"),
        edge("B", "C"),
        edge("B", "A"),
        edge("D", "D"),
        edge("E", "A"),
      ],
    });
    const lanes = layout.edges.filter((e) => e.back);
    expect(lanes.length).toBe(4);
    for (const e of lanes) {
      for (const seg of segments(e.d)) {
        for (const box of layout.nodes) {
          expect(crosses(seg, box)).toBe(false);
        }
      }
      for (const seg of segments(e.d)) {
        expect(seg[0].y).toBeGreaterThanOrEqual(0);
        expect(seg[1].x).toBeLessThanOrEqual(layout.width);
      }
    }
    const arrows = new Set(lanes.map((e) => e.arrow));
    expect(arrows.size).toBe(lanes.length);
  });

  it("wraps many unreached steps into more than one row", () => {
    const count = UNREACHED_PER_ROW * 2 + 1;
    const extra = Array.from({ length: count }, (_, i) =>
      node(`U${i}`, { reachable: false }),
    );
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), ...extra],
      edges: [],
    });
    const rows = new Set(
      layout.nodes.filter((n) => n.unreachedRow).map((n) => n.y),
    );
    expect(rows.size).toBe(3);
    const widest = UNREACHED_PER_ROW * NODE_WIDTH;
    expect(layout.width).toBeLessThan(widest * 1.5);
  });

  it("left-aligns each row", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), node("B"), node("C")],
      edges: [edge("A", "B"), edge("A", "C")],
    });
    const n = byName(layout);
    expect(n.A.x).toBe(n.B.x);
  });

  it("puts branches of one step in the same row, in declared order", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), node("C"), node("B")],
      edges: [edge("A", "B"), edge("A", "C")],
    });
    const n = byName(layout);
    expect(n.B.y).toBe(n.C.y);
    expect(n.C.x).toBeLessThan(n.B.x);
  });

  it("puts steps with no known inbound edge in a last row", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), node("B"), node("Z", { reachable: false })],
      edges: [edge("A", "B")],
    });
    const n = byName(layout);
    expect(n.Z.y).toBeGreaterThan(n.B.y);
    expect(n.Z.unreachedRow).toBe(true);
    expect(n.B.unreachedRow).toBe(false);
  });

  it("marks an edge to an earlier row as a back edge", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), node("B")],
      edges: [edge("A", "B"), edge("B", "A")],
    });
    const back = layout.edges.find((e) => e.source === "B");
    const forward = layout.edges.find((e) => e.source === "A");
    expect(back.back).toBe(true);
    expect(forward.back).toBe(false);
  });

  it("draws a self loop", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A")],
      edges: [edge("A", "A")],
    });
    expect(layout.edges).toHaveLength(1);
    expect(layout.edges[0].back).toBe(true);
  });

  it("gives paths and arrow heads with no NaN, inside the canvas", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A"), node("B"), node("C"), node("D", { reachable: false })],
      edges: [edge("A", "B"), edge("A", "C"), edge("C", "A"), edge("D", "B")],
    });
    for (const e of layout.edges) {
      expect(e.d).not.toMatch(/NaN|undefined/);
      expect(e.arrow).not.toMatch(/NaN|undefined/);
      expect(e.key).toBe(`${e.source}->${e.target}`);
    }
    for (const n of layout.nodes) {
      expect(n.x).toBeGreaterThanOrEqual(0);
      expect(n.x + n.width).toBeLessThanOrEqual(layout.width);
      expect(n.y + n.height).toBeLessThanOrEqual(layout.height);
    }
  });

  it("skips an edge to a node that is not in the graph", () => {
    const layout = layoutGraph({
      initialStep: "A",
      nodes: [node("A")],
      edges: [edge("A", "Ghost")],
    });
    expect(layout.edges).toHaveLength(0);
  });

  it("gives an empty layout for an empty or missing graph", () => {
    for (const graph of [null, undefined, { nodes: [], edges: [] }]) {
      const layout = layoutGraph(graph);
      expect(layout.nodes).toEqual([]);
      expect(layout.edges).toEqual([]);
      expect(layout.width).toBeGreaterThan(0);
      expect(layout.height).toBeGreaterThan(0);
    }
  });

  it("uses the first node when the initial step is blank", () => {
    const layout = layoutGraph({
      initialStep: null,
      nodes: [node("A"), node("B")],
      edges: [edge("A", "B")],
    });
    const n = byName(layout);
    expect(n.A.y).toBeLessThan(n.B.y);
  });
});
