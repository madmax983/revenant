/**
 * Layered layout for the workflow topology graph (#141). The row of a node is
 * its breadth-first distance from the initial step. Nodes with no known route
 * from the initial step go in one last row. In a row, nodes keep the declared
 * order. It gives SVG path data and arrow heads. It uses no SVG markers,
 * because a `url(#id)` reference can break in shadow DOM.
 */

export const NODE_WIDTH = 180;
export const NODE_HEIGHT = 56;
const H_GAP = 32;
const V_GAP = 56;
const PAD = 24;
// Space at the right for the curves of back edges and self loops.
const SIDE_ROUTE = 64;
const ARROW = 8;

const empty = () => ({
  nodes: [],
  edges: [],
  width: 2 * PAD + NODE_WIDTH,
  height: 2 * PAD + NODE_HEIGHT,
});

function depthsFrom(start, adjacency) {
  const depth = new Map([[start, 0]]);
  const queue = [start];
  for (let i = 0; i < queue.length; i++) {
    const current = queue[i];
    for (const next of adjacency.get(current) || []) {
      if (!depth.has(next)) {
        depth.set(next, depth.get(current) + 1);
        queue.push(next);
      }
    }
  }
  return depth;
}

// A downward curve from the bottom of the source to the top of the target.
function forwardRoute(s, t) {
  const x1 = s.x + NODE_WIDTH / 2;
  const y1 = s.y + NODE_HEIGHT;
  const x2 = t.x + NODE_WIDTH / 2;
  const y2 = t.y;
  const mid = (y2 - y1) / 2;
  return {
    d: `M ${x1} ${y1} C ${x1} ${y1 + mid} ${x2} ${y2 - mid} ${x2} ${y2}`,
    arrow: `${x2 - ARROW / 2},${y2 - ARROW} ${x2 + ARROW / 2},${y2 - ARROW} ${x2},${y2}`,
  };
}

// A curve at the right side, from the source to the target.
function sideRoute(s, t) {
  const x1 = s.x + NODE_WIDTH;
  const x2 = t.x + NODE_WIDTH;
  let y1 = s.y + NODE_HEIGHT / 2;
  let y2 = t.y + NODE_HEIGHT / 2;
  if (s === t) {
    y1 = s.y + NODE_HEIGHT / 4;
    y2 = s.y + (3 * NODE_HEIGHT) / 4;
  }
  const bend = Math.max(x1, x2) + SIDE_ROUTE * 0.75;
  return {
    d: `M ${x1} ${y1} C ${bend} ${y1} ${bend} ${y2} ${x2} ${y2}`,
    arrow: `${x2 + ARROW},${y2 - ARROW / 2} ${x2 + ARROW},${y2 + ARROW / 2} ${x2},${y2}`,
  };
}

/**
 * Computes the positions of the nodes and the routes of the edges.
 * @param {object} graph The WorkflowTopology.Graph DTO.
 * @returns {{nodes: object[], edges: object[], width: number, height: number}}
 */
export function layoutGraph(graph) {
  const nodes = graph && Array.isArray(graph.nodes) ? graph.nodes : [];
  if (nodes.length === 0) {
    return empty();
  }
  const edges = Array.isArray(graph.edges) ? graph.edges : [];
  const names = new Set(nodes.map((n) => n.name));
  const known = edges.filter((e) => names.has(e.source) && names.has(e.target));

  const adjacency = new Map();
  for (const e of known) {
    if (!adjacency.has(e.source)) {
      adjacency.set(e.source, []);
    }
    adjacency.get(e.source).push(e.target);
  }
  const start = names.has(graph.initialStep)
    ? graph.initialStep
    : nodes[0].name;
  const depth = depthsFrom(start, adjacency);
  const lastReached = Math.max(...depth.values());
  const unreachedRow = lastReached + 1;

  const rows = new Map();
  for (const n of nodes) {
    const row = depth.has(n.name) ? depth.get(n.name) : unreachedRow;
    if (!rows.has(row)) {
      rows.set(row, []);
    }
    rows.get(row).push(n.name);
  }
  const rowIndexes = [...rows.keys()].sort((a, b) => a - b);
  const maxColumns = Math.max(...[...rows.values()].map((r) => r.length));
  const contentWidth = maxColumns * NODE_WIDTH + (maxColumns - 1) * H_GAP;
  const width = 2 * PAD + contentWidth + SIDE_ROUTE;
  const height =
    2 * PAD + rowIndexes.length * NODE_HEIGHT + (rowIndexes.length - 1) * V_GAP;

  const positions = new Map();
  rowIndexes.forEach((row, level) => {
    const members = rows.get(row);
    const rowWidth = members.length * NODE_WIDTH + (members.length - 1) * H_GAP;
    const offset = PAD + (contentWidth - rowWidth) / 2;
    members.forEach((name, column) => {
      positions.set(name, {
        name,
        x: offset + column * (NODE_WIDTH + H_GAP),
        y: PAD + level * (NODE_HEIGHT + V_GAP),
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        unreachedRow: row === unreachedRow,
        level,
      });
    });
  });

  const routed = known.map((e) => {
    const s = positions.get(e.source);
    const t = positions.get(e.target);
    const back = t.level <= s.level;
    return {
      key: `${e.source}->${e.target}`,
      source: e.source,
      target: e.target,
      back,
      ...(back ? sideRoute(s, t) : forwardRoute(s, t)),
    };
  });

  return {
    nodes: nodes.map((n) => positions.get(n.name)),
    edges: routed,
    width,
    height,
  };
}
