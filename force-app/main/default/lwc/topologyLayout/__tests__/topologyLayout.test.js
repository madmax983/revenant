import { layoutGraph, NODE_WIDTH, NODE_HEIGHT } from "c/topologyLayout";

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
