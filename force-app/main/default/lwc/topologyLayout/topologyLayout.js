/**
 * Layered layout for the workflow topology graph (#141). The row of a node is
 * its breadth-first distance from the initial step. Rows are left-aligned and
 * keep the declared order. Nodes with no known route from the initial step go
 * in the last rows, at most UNREACHED_PER_ROW in each row.
 *
 * A forward edge spans one row, so its curve stays between two rows. Other
 * edges (back, same row, self loop) use lanes: the gap below the source row,
 * a gutter at the right side, and the gap above the target row. Thus no edge
 * crosses a node box. The layout uses no SVG markers, because a `url(#id)`
 * reference can break in shadow DOM.
 */

export const NODE_WIDTH = 200;
export const NODE_HEIGHT = 58;
export const UNREACHED_PER_ROW = 6;
const H_GAP = 32;
const V_GAP = 64;
const PAD = 24;
// Room above the first row for the lanes of edges into it.
const TOP = PAD + V_GAP / 2;
const LANE = 6;
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

function downArrow(x, y) {
  return `${x - ARROW / 2},${y - ARROW} ${x + ARROW / 2},${y - ARROW} ${x},${y}`;
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
    arrow: downArrow(x2, y2),
  };
}

// An orthogonal route through the row gaps and the right gutter. Each lane
// has its own offset, so two routes do not overlap.
function laneRoute(s, t, lane, gutterX) {
  const shift = ((lane % 5) - 2) * LANE;
  const x1 = s.x + NODE_WIDTH / 2 + shift;
  const y1 = s.y + NODE_HEIGHT;
  const below = y1 + V_GAP / 2 + (lane % 4) * LANE - 1.5 * LANE;
  const gx = gutterX + lane * LANE;
  const x2 = t.x + NODE_WIDTH / 2 + shift;
  const y2 = t.y;
  const above = y2 - V_GAP / 2 - (lane % 4) * LANE + 1.5 * LANE;
  return {
    d: `M ${x1} ${y1} V ${below} H ${gx} V ${above} H ${x2} V ${y2}`,
    arrow: downArrow(x2, y2),
  };
}

function rowsOf(nodes, depth) {
  const reached = new Map();
  const unreached = [];
  for (const n of nodes) {
    if (depth.has(n.name)) {
      const row = depth.get(n.name);
      if (!reached.has(row)) {
        reached.set(row, []);
      }
      reached.get(row).push(n.name);
    } else {
      unreached.push(n.name);
    }
  }
  const rows = [...reached.keys()]
    .sort((a, b) => a - b)
    .map((row) => ({ names: reached.get(row), unreached: false }));
  for (let i = 0; i < unreached.length; i += UNREACHED_PER_ROW) {
    rows.push({
      names: unreached.slice(i, i + UNREACHED_PER_ROW),
      unreached: true,
    });
  }
  return rows;
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
  const rows = rowsOf(nodes, depthsFrom(start, adjacency));

  const positions = new Map();
  rows.forEach((row, level) => {
    row.names.forEach((name, column) => {
      positions.set(name, {
        name,
        x: PAD + column * (NODE_WIDTH + H_GAP),
        y: TOP + level * (NODE_HEIGHT + V_GAP),
        width: NODE_WIDTH,
        height: NODE_HEIGHT,
        unreachedRow: row.unreached,
        level,
      });
    });
  });

  const maxColumns = Math.max(...rows.map((r) => r.names.length));
  const contentWidth = maxColumns * NODE_WIDTH + (maxColumns - 1) * H_GAP;
  const gutterX = PAD + contentWidth + 2 * LANE;
  let lanes = 0;
  const routed = known.map((e) => {
    const s = positions.get(e.source);
    const t = positions.get(e.target);
    const back = t.level !== s.level + 1;
    return {
      key: `${e.source}->${e.target}`,
      source: e.source,
      target: e.target,
      back,
      ...(back ? laneRoute(s, t, lanes++, gutterX) : forwardRoute(s, t)),
    };
  });

  const width = gutterX + (lanes + 1) * LANE + PAD;
  const height =
    TOP +
    rows.length * NODE_HEIGHT +
    (rows.length - 1) * V_GAP +
    V_GAP / 2 +
    PAD;
  return {
    nodes: nodes.map((n) => positions.get(n.name)),
    edges: routed,
    width,
    height,
  };
}
