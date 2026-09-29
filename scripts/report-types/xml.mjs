// Strict parser for the small XML subset in Salesforce metadata files (issue #137).

const RAW_AMPERSAND = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/;

/**
 * Parses XML into { name, children, text }.
 * Throws on bad nesting, a stray < > or &, text next to child elements,
 * padded leaf text, and more than one root element.
 */
export function parseXml(source) {
  const body = source
    .replace(/^\s*<\?xml[^>]*\?>/, "")
    .replace(/<!--[\s\S]*?-->/g, "");
  const root = { name: "#root", children: [], text: "" };
  const stack = [root];
  const tag =
    /<(\/?)([A-Za-z_][\w.-]*)((?:\s+[\w:.-]+="[^"<>]*")*)\s*(\/?)>|([^<]+)/g;
  let at = 0;
  let m;
  while ((m = tag.exec(body))) {
    if (m.index !== at) throw new Error(`bad markup at ${at}`);
    at = tag.lastIndex;
    const top = stack.at(-1);
    if (m[5] !== undefined) {
      if (m[5].includes(">")) throw new Error("stray >");
      if (RAW_AMPERSAND.test(m[5])) throw new Error("raw &");
      top.text += m[5];
    } else if (m[1]) {
      if (top.name !== m[2]) throw new Error(`</${m[2]}> closes <${top.name}>`);
      stack.pop();
    } else {
      const node = { name: m[2], children: [], text: "" };
      top.children.push(node);
      if (!m[4]) stack.push(node);
    }
  }
  if (at !== body.length) throw new Error(`bad markup at ${at}`);
  if (stack.length !== 1) throw new Error(`<${stack.at(-1).name}> not closed`);
  if (root.children.length !== 1) throw new Error("not one root element");
  checkText(root);
  return root.children[0];
}

function checkText(node) {
  if (node.children.length && node.text.trim()) {
    throw new Error(`<${node.name}> has text next to child elements`);
  }
  if (!node.children.length && node.text !== node.text.trim()) {
    throw new Error(`<${node.name}> text has spaces at the start or end`);
  }
  node.children.forEach(checkText);
}

/**
 * Checks the child elements of each node against `schema`.
 * A schema entry is a list of names in order. `x?` is optional. `x+` is one or more.
 * A name with no schema entry must be a leaf.
 */
export function checkOrder(node, schema) {
  const spec = schema[node.name];
  if (spec === undefined) {
    if (node.children.length) throw new Error(`<${node.name}> must be a leaf`);
    return;
  }
  const pattern = spec
    .map((s) => {
      const name = s.replace(/[?+]$/, "");
      const quant = s.endsWith("?") ? "?" : s.endsWith("+") ? "+" : "";
      return `(?:${name},)${quant}`;
    })
    .join("");
  const names = node.children.map((c) => `${c.name},`).join("");
  if (!new RegExp(`^${pattern}$`).test(names)) {
    throw new Error(`<${node.name}> has [${names}], expected [${spec}]`);
  }
  for (const child of node.children) checkOrder(child, schema);
}
