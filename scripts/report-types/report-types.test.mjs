// Static checks of the Custom Report Types (issue #137). Run: npm run test:report-types
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const MAIN = "force-app/main/default";
const read = (path) => readFileSync(join(ROOT, path), "utf8");

const INSTANCE = "Workflow_Instance__c";
const STEP = "Workflow_Step_Execution__c";
const STEPS_TABLE = `${INSTANCE}.Workflow_Step_Executions__r`;
const TYPES = {
  instances: "Revenant_Workflow_Instances",
  withSteps: "Revenant_Workflow_Instances_with_Steps",
};
const STANDARD_FIELDS = new Set(["Name", "CreatedDate", "LastModifiedDate"]);

// Fields that hold a stored form (offload marker or codec envelope), not a value.
const POINTER_FIELDS = {
  [INSTANCE]: ["Input__c", "Output__c", "Progress__c", "Compensation_Stack__c"],
  [STEP]: ["Input__c", "Output__c", "Captured_Values__c", "Error_Details__c"],
};
// Other fields that the types leave out, with the reason.
const INTERNAL_FIELDS = {
  [INSTANCE]: {
    Active_Correlation_Key__c: "dedup key, same as Correlation_Key__c",
    Admission_Key__c: "admission sort key",
    Async_Job_Id__c: "engine job Id",
    Definition_Fingerprint__c: "definition hash",
    Definition_Shape__c: "engine JSON",
  },
  [STEP]: {
    Decision_Record__c: "determinism record",
    Workflow_Instance__c: "the instance section shows the parent",
  },
};

const INSTANCE_DEFAULTS = [
  "Workflow_Name__c",
  "Status__c",
  "Correlation_Key__c",
  "Definition_Version__c",
  "Current_Step__c",
  "Terminal_At__c",
  "Error_Message__c",
  "Parent_Instance__c",
  "Concurrency_Parked__c",
  "CreatedDate",
  "LastModifiedDate",
];
const STEP_DEFAULTS = [
  "Step_Name__c",
  "Status__c",
  "Retry_Count__c",
  "Transient_Retry_Count__c",
  "CreatedDate",
  "LastModifiedDate",
];

/** Parses XML into { name, children, text }. Throws on a malformed file. */
function parseXml(source) {
  const body = source
    .replace(/<\?xml[^>]*\?>/, "")
    .replace(/<!--[\s\S]*?-->/g, "");
  const root = { name: "#root", children: [], text: "" };
  const stack = [root];
  const tag = /<(\/?)([A-Za-z_][\w.-]*)([^>]*?)(\/?)>|([^<]+)/g;
  let m;
  let at = 0;
  while ((m = tag.exec(body))) {
    if (m.index !== at) throw new Error(`bad markup at ${at}`);
    at = tag.lastIndex;
    const top = stack[stack.length - 1];
    if (m[5] !== undefined) {
      if (m[5].includes(">")) throw new Error("stray >");
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
  if (stack.length !== 1) throw new Error(`<${stack.at(-1).name}> not closed`);
  if (at !== body.length) throw new Error(`bad markup at ${at}`);
  if (root.children.length !== 1) throw new Error("not one root element");
  return root.children[0];
}

const kids = (node, name) => node.children.filter((c) => c.name === name);
const value = (node, name) => kids(node, name)[0]?.text.trim();

function loadType(name) {
  const path = `${MAIN}/reportTypes/${name}.reportType-meta.xml`;
  assert.ok(existsSync(join(ROOT, path)), `missing ${path}`);
  const source = read(path);
  const xml = parseXml(source);
  assert.equal(xml.name, "ReportType");
  assert.match(
    source,
    /<ReportType xmlns="http:\/\/soap\.sforce\.com\/2006\/04\/metadata">/,
  );
  const sections = kids(xml, "sections").map((s) => ({
    label: value(s, "masterLabel"),
    columns: kids(s, "columns").map((c) => ({
      field: value(c, "field"),
      table: value(c, "table"),
      checked: value(c, "checkedByDefault") === "true",
    })),
  }));
  return { xml, sections, columns: sections.flatMap((s) => s.columns) };
}

function objectFields(object) {
  return new Map(
    readdirSync(join(ROOT, MAIN, "objects", object, "fields")).map((file) => {
      const xml = read(`${MAIN}/objects/${object}/fields/${file}`);
      return [file.replace(".field-meta.xml", ""), xml];
    }),
  );
}

// Field name to field XML, for each object.
const FIELDS = {
  [INSTANCE]: objectFields(INSTANCE),
  [STEP]: objectFields(STEP),
};

const objectOf = (table) => (table === STEPS_TABLE ? STEP : table);
const shown = (type, table) =>
  type.columns.filter((c) => c.table === table).map((c) => c.field);
const checked = (type, table) =>
  type.columns
    .filter((c) => c.table === table && c.checked)
    .map((c) => c.field);

test("the XML parser rejects malformed files", () => {
  const ok = parseXml('<?xml version="1.0"?><a x="1"><b>t</b><c/></a>');
  assert.deepEqual(
    ok.children.map((c) => c.name),
    ["b", "c"],
  );
  for (const bad of [
    "<a><b></a>",
    "<a>",
    "<a></a><b></b>",
    "<a>x < y</a>",
    "<a>></a>",
  ]) {
    assert.throws(() => parseXml(bad), bad);
  }
});

test("the report types folder has the two Revenant types only", () => {
  const files = readdirSync(join(ROOT, MAIN, "reportTypes")).sort();
  assert.deepEqual(
    files,
    Object.values(TYPES)
      .map((n) => `${n}.reportType-meta.xml`)
      .sort(),
  );
});

test("each type deploys to Report Builder with a Revenant label", () => {
  for (const name of Object.values(TYPES)) {
    const { xml } = loadType(name);
    assert.equal(value(xml, "baseObject"), INSTANCE, name);
    assert.equal(value(xml, "category"), "other", name);
    assert.equal(value(xml, "deployed"), "true", name);
    const label = value(xml, "label");
    assert.match(label, /^Revenant Workflow Instances/, name);
    assert.ok(label.length <= 50, `${name} label is over 50 characters`);
    const description = value(xml, "description") ?? "";
    assert.ok(description.length > 0, `${name} has no description`);
    assert.ok(description.length <= 255, `${name} description is over 255`);
  }
});

test("the instance type has no join and shows the operator fields by default", () => {
  const type = loadType(TYPES.instances);
  assert.equal(kids(type.xml, "join").length, 0);
  assert.equal(value(type.xml, "label"), "Revenant Workflow Instances");
  assert.deepEqual(type.sections.length, 1);
  assert.ok(type.columns.every((c) => c.table === INSTANCE));
  assert.deepEqual(
    INSTANCE_DEFAULTS.filter((f) => !checked(type, INSTANCE).includes(f)),
    [],
  );
});

test("the step type is an outer join on the master-detail relationship", () => {
  const type = loadType(TYPES.withSteps);
  assert.equal(
    value(type.xml, "label"),
    "Revenant Workflow Instances with Step Executions",
  );
  const joins = kids(type.xml, "join");
  assert.equal(joins.length, 1);
  assert.equal(value(joins[0], "outerJoin"), "true", "new instances must show");
  const master = FIELDS[STEP].get(INSTANCE);
  assert.match(master, /<type>MasterDetail<\/type>/);
  assert.match(master, new RegExp(`<referenceTo>${INSTANCE}</referenceTo>`));
  const relationship = /<relationshipName>(\w+)<\/relationshipName>/.exec(
    master,
  )[1];
  assert.equal(value(joins[0], "relationship"), `${relationship}__r`);
  assert.equal(STEPS_TABLE, `${INSTANCE}.${relationship}__r`);
  assert.equal(kids(joins[0], "join").length, 0, "no second join level");
});

test("the step type shows name, retries, status and duration timestamps", () => {
  const type = loadType(TYPES.withSteps);
  assert.deepEqual(
    type.sections.map((s) => s.label),
    ["Workflow Instances", "Workflow Step Executions"],
  );
  assert.deepEqual(
    STEP_DEFAULTS.filter((f) => !checked(type, STEPS_TABLE).includes(f)),
    [],
  );
  for (const f of ["Workflow_Name__c", "Status__c", "Correlation_Key__c"]) {
    assert.ok(checked(type, INSTANCE).includes(f), `instance ${f} not checked`);
  }
  assert.deepEqual(
    INSTANCE_DEFAULTS.filter((f) => !shown(type, INSTANCE).includes(f)),
    [],
    "each instance default is available in the step type",
  );
});

test("each column is a real field of its table, once", () => {
  for (const name of Object.values(TYPES)) {
    const type = loadType(name);
    const seen = new Set();
    for (const { field, table } of type.columns) {
      assert.ok(
        [INSTANCE, STEPS_TABLE].includes(table),
        `${name}: table ${table}`,
      );
      const known =
        STANDARD_FIELDS.has(field) || FIELDS[objectOf(table)].has(field);
      assert.ok(known, `${name}: ${table}.${field} does not exist`);
      assert.ok(!seen.has(`${table}.${field}`), `${name}: ${field} twice`);
      seen.add(`${table}.${field}`);
    }
  }
});

test("no type shows a pointer field or an engine internal", () => {
  for (const name of Object.values(TYPES)) {
    const type = loadType(name);
    for (const table of [INSTANCE, STEPS_TABLE]) {
      const object = objectOf(table);
      const hidden = [
        ...POINTER_FIELDS[object],
        ...Object.keys(INTERNAL_FIELDS[object]),
      ];
      const leaks = shown(type, table).filter((f) => hidden.includes(f));
      assert.deepEqual(leaks, [], `${name} shows ${table} ${leaks}`);
    }
  }
});

test("each custom field is shown or excluded on purpose", () => {
  const withSteps = loadType(TYPES.withSteps);
  for (const [object, table] of [
    [INSTANCE, INSTANCE],
    [STEP, STEPS_TABLE],
  ]) {
    const decided = new Set([
      ...shown(withSteps, table),
      ...POINTER_FIELDS[object],
      ...Object.keys(INTERNAL_FIELDS[object]),
    ]);
    const open = [...FIELDS[object].keys()].filter((f) => !decided.has(f));
    assert.deepEqual(
      open,
      [],
      `${object}: add to a type or to an excluded list`,
    );
  }
  const instances = loadType(TYPES.instances);
  assert.deepEqual(shown(instances, INSTANCE), shown(withSteps, INSTANCE));
});

test("the excluded pointer fields include each field the engine writes a stored form to", () => {
  // A stored form comes from these calls. The field is the last `X__c =` before the call.
  const writers =
    /WorkflowPayloadOffload\.savePayloadIfNeeded\(|WorkflowPayloadCodecs\.encode\(|WorkflowFailureDetails\.build\(/g;
  const known = new Set([...FIELDS[INSTANCE].keys(), ...FIELDS[STEP].keys()]);
  const pointers = new Set(Object.values(POINTER_FIELDS).flat());
  const found = new Set();
  const dir = join(ROOT, MAIN, "classes");
  for (const file of readdirSync(dir).filter((f) => f.endsWith(".cls"))) {
    if (/Test\w*\.cls$/.test(file)) continue;
    const source = readFileSync(join(dir, file), "utf8");
    for (const m of source.matchAll(writers)) {
      const before = source.slice(0, m.index);
      const statement = before.slice(
        Math.max(...[";", "{", "}"].map((c) => before.lastIndexOf(c))) + 1,
      );
      const target = [...statement.matchAll(/(\w+__c)\s*=(?!=)/g)].at(-1)?.[1];
      if (target && known.has(target)) found.add(target);
    }
  }
  for (const f of [
    "Input__c",
    "Output__c",
    "Progress__c",
    "Captured_Values__c",
    "Error_Details__c",
  ]) {
    assert.ok(found.has(f), `scan did not find the writer of ${f}`);
  }
  assert.deepEqual(
    [...found].filter((f) => !pointers.has(f)),
    [],
  );
});

test("Revenant_Operator and Revenant_Admin can read each custom column", () => {
  const withSteps = loadType(TYPES.withSteps);
  for (const set of ["Revenant_Operator", "Revenant_Admin"]) {
    const xml = parseXml(
      read(`${MAIN}/permissionsets/${set}.permissionset-meta.xml`),
    );
    const readable = new Set(
      kids(xml, "fieldPermissions")
        .filter((p) => value(p, "readable") === "true")
        .map((p) => value(p, "field")),
    );
    const objects = new Set(
      kids(xml, "objectPermissions")
        .filter((p) => value(p, "allowRead") === "true")
        .map((p) => value(p, "object")),
    );
    assert.ok(objects.has(INSTANCE) && objects.has(STEP), `${set} object read`);
    for (const { field, table } of withSteps.columns) {
      const object = objectOf(table);
      // Object read gives read on standard and required fields. They have no FLS row.
      if (STANDARD_FIELDS.has(field)) continue;
      if (/<required>true<\/required>/.test(FIELDS[object].get(field)))
        continue;
      assert.ok(
        readable.has(`${object}.${field}`),
        `${set} cannot read ${object}.${field}`,
      );
    }
  }
});

test("the doc names the types, the excluded fields, FLS and the category", () => {
  const doc = read("docs/report-types.md");
  for (const text of [
    "Revenant Workflow Instances",
    "Revenant Workflow Instances with Step Executions",
    "Other Reports",
    "Revenant_Operator",
    "field-level security",
    "LAST N DAYS:1",
    "Subscribe",
  ]) {
    assert.ok(doc.includes(text), `docs/report-types.md does not name ${text}`);
  }
  for (const f of new Set(Object.values(POINTER_FIELDS).flat())) {
    assert.ok(
      doc.includes(`\`${f}\``),
      `docs/report-types.md does not name ${f}`,
    );
  }
  assert.ok(
    read("README.md").includes("(docs/report-types.md)"),
    "README link",
  );
});
