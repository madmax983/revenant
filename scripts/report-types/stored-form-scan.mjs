// Finds the fields to which the engine Apex writes a stored form (issue #137).
// A stored form is a pointer to a file or an encoded value, not the value.
// The scan follows: an assignment (= and +=), put('X__c', ...), two local
// variables in one method, a static method that returns a stored form, and a
// field copy (x.A__c = y.B__c). It matches a field by name only.
// It does not follow: inner class or instance calls, property getters,
// method parameters, put() with a non-literal key, a copy in an expression,
// and trigger files.

const SEEDS = [
  "WorkflowPayloadOffload.savePayloadIfNeeded",
  "WorkflowPayloadCodecs.encode",
];
const KEYWORDS = new Set(["if", "for", "while", "catch", "switch", "return"]);
// `(?!\s*:)` skips a SOQL bind such as `WHERE Name__c = :n`.
const FIELD_ASSIGN = /(\w+__c)\s*\+?=(?![=>]|\s*:)/g;
const VAR_ASSIGN = /\b([A-Za-z_]\w*)\s*\+?=(?![=>]|\s*:)/g;

/** Replaces comments and the text in string literals with spaces. Keeps the length. */
export function mask(source) {
  let out = "";
  let i = 0;
  while (i < source.length) {
    const two = source.slice(i, i + 2);
    let stop;
    if (two === "//") {
      stop = source.indexOf("\n", i);
      if (stop < 0) stop = source.length;
      out += " ".repeat(stop - i);
    } else if (two === "/*") {
      stop = source.indexOf("*/", i + 2);
      stop = stop < 0 ? source.length : stop + 2;
      out += source.slice(i, stop).replace(/[^\n]/g, " ");
    } else if (source[i] === "'") {
      stop = i + 1;
      while (stop < source.length && source[stop] !== "'") {
        stop += source[stop] === "\\" ? 2 : 1;
      }
      stop = Math.min(stop + 1, source.length);
      out += `'${" ".repeat(Math.max(stop - i - 2, 0))}'`.slice(0, stop - i);
    } else {
      stop = i + 1;
      out += source[i];
    }
    i = stop;
  }
  return out;
}

const isTestClass = (masked) => {
  const at = masked.search(/\bclass\s+\w+/);
  return at >= 0 && /@IsTest\b/i.test(masked.slice(0, at));
};

// A `{` after `>` or `]` opens a collection literal, not a block.
const isLiteralBrace = (m, open) => /[>\]]\s*$/.test(m.slice(0, open));

function matchBrace(m, at, step) {
  let depth = 0;
  for (let k = at; k >= 0 && k < m.length; k += step) {
    if (m[k] === "{") depth += step;
    if (m[k] === "}") depth -= step;
    if (depth === 0) return k;
  }
  return -1;
}

function statementStart(m, idx) {
  for (let i = idx - 1; i >= 0; i--) {
    if (m[i] === ";") return i + 1;
    if (m[i] === "}") {
      const open = matchBrace(m, i, -1);
      if (open < 0 || !isLiteralBrace(m, open)) return i + 1;
      i = open;
    } else if (m[i] === "{" && !isLiteralBrace(m, i)) {
      return i + 1;
    }
  }
  return 0;
}

function statementEnd(m, idx) {
  let depth = 0;
  for (let k = idx; k < m.length; k++) {
    if ("({[".includes(m[k])) depth++;
    if (")}]".includes(m[k])) depth--;
    if (depth < 0 || (depth === 0 && m[k] === ";")) return k;
  }
  return m.length;
}

function enclosingMethod(m, idx) {
  const decl = /\b(\w+)\s*\([^;{}()]*(?:\([^;{}()]*\)[^;{}()]*)*\)\s*\{/g;
  let best = null;
  for (const d of m.matchAll(decl)) {
    if (d.index > idx) break;
    if (KEYWORDS.has(d[1])) continue;
    const open = d.index + d[0].length - 1;
    const close = matchBrace(m, open, 1);
    if (close > idx) best = { name: d[1], close };
  }
  return best;
}

const lastGroup = (text, re) => [...text.matchAll(re)].at(-1)?.[1];

/** Gives the start index of each call to a writer in the file. */
function writerCalls(file, writers) {
  const calls = [];
  for (const writer of writers) {
    const [cls, method] = writer.split(".");
    for (const c of file.masked.matchAll(
      new RegExp(`\\b${cls}\\s*\\.\\s*${method}\\s*\\(`, "g"),
    )) {
      calls.push(c.index);
    }
    if (cls !== file.cls) continue;
    for (const c of file.masked.matchAll(
      new RegExp(`\\b${method}\\s*\\(`, "g"),
    )) {
      const before = file.masked.slice(0, c.index).trimEnd();
      const word = /(\w+)$/.exec(before)?.[1];
      // Skip a qualified call and a declaration (`String name(`, `List<X> name(`).
      const declaration =
        /[>\]]$/.test(before) || (word && !["return", "else"].includes(word));
      if (before.endsWith(".") || declaration) continue;
      calls.push(c.index);
    }
  }
  return calls;
}

/** Records where the stored form at `idx` goes. Follows up to `hops` local variables. */
function sink(file, idx, found, hops = 2) {
  const { masked, source } = file;
  const start = statementStart(masked, idx);
  const head = masked.slice(start, idx);
  const field = lastGroup(head, FIELD_ASSIGN);
  if (field) return found.fields.add(field);
  const put = [...head.matchAll(/\.put\s*\(\s*'/g)].at(-1);
  if (put) {
    const at = start + put.index + put[0].length;
    const key = /^(\w+__c)'/.exec(source.slice(at))?.[1];
    if (key) return found.fields.add(key);
  }
  if (/\breturn\b/.test(head)) {
    const method = enclosingMethod(masked, idx);
    if (method) found.writers.add(`${file.cls}.${method.name}`);
    return;
  }
  const variable = lastGroup(head, VAR_ASSIGN);
  const method = enclosingMethod(masked, idx);
  if (!hops || !variable || !method) return;
  const use = new RegExp(`\\b${variable}\\b`, "g");
  use.lastIndex = statementEnd(masked, idx);
  let u;
  while ((u = use.exec(masked)) && u.index < method.close) {
    sink(file, u.index, found, hops - 1);
  }
}

/**
 * Gives the names of the fields that get a stored form.
 * `copyFrom` names fields that hold a stored form. A copy of one also counts.
 */
export function scanStoredFormFields(files, { copyFrom = [] } = {}) {
  const sources = files
    .map((f) => ({
      cls: f.name
        .split("/")
        .at(-1)
        .replace(/\.cls$/, ""),
      source: f.source,
      masked: mask(f.source),
    }))
    .filter((f) => !isTestClass(f.masked));
  const found = { writers: new Set(SEEDS), fields: new Set() };
  const copy = /(\w+__c)\s*=(?![=>])\s*(?:\w+\s*\.\s*)+(\w+__c)\s*(?=[;,)])/g;
  let size = -1;
  while (found.writers.size + found.fields.size !== size) {
    size = found.writers.size + found.fields.size;
    for (const file of sources) {
      for (const idx of writerCalls(file, found.writers))
        sink(file, idx, found);
      for (const c of file.masked.matchAll(copy)) {
        const source = copyFrom.includes(c[2]) || found.fields.has(c[2]);
        if (source && c[1] !== c[2]) {
          found.fields.add(c[1]);
        }
      }
    }
  }
  return found.fields;
}
