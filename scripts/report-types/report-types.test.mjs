// Static checks of the Custom Report Types (issue #137). Run: npm run test:report-types
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { checkOrder, parseXml } from "./xml.mjs";
import { scanStoredFormFields } from "./stored-form-scan.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const MAIN = "force-app/main/default";
const read = (path) => readFileSync(join(ROOT, path), "utf8");
const DOC = "docs/report-types.md";

const INSTANCE = "Workflow_Instance__c";
const STEP = "Workflow_Step_Execution__c";
const STEPS_TABLE = `${INSTANCE}.Workflow_Step_Executions__r`;
const TYPES = {
  instances: "Revenant_Workflow_Instances",
  withSteps: "Revenant_Workflow_Instances_with_Steps",
};
const STANDARD_FIELDS = new Set(["Name", "CreatedDate", "LastModifiedDate"]);
// The Metadata API element order of the parts that the types use.
const REPORT_TYPE_SCHEMA = {
  ReportType: [
    "baseObject",
    "category",
    "deployed",
    "description",
    "join?",
    "label",
    "sections+",
  ],
  join: ["outerJoin", "relationship"],
  sections: ["columns+", "masterLabel"],
  columns: ["checkedByDefault", "field", "table"],
};

// Fields that can hold a stored form: a pointer to a file or an encoded value.
const STORED_FORM_FIELDS = {
  [INSTANCE]: ["Input__c", "Output__c", "Progress__c"],
  [STEP]: ["Input__c", "Output__c", "Captured_Values__c", "Error_Details__c"],
};
// Other fields that the types leave out, with the reason.
const INTERNAL_FIELDS = {
  [INSTANCE]: {
    Active_Correlation_Key__c: "duplicate check key",
    Admission_Key__c: "admission sort key",
    Async_Job_Id__c: "engine job Id",
    Compensation_Stack__c: "engine JSON",
    Definition_Fingerprint__c: "definition hash",
    Definition_Shape__c: "engine JSON",
  },
  [STEP]: {
    Decision_Record__c: "determinism record",
    Workflow_Instance__c: "the instance section shows the parent",
  },
};

// Default (checked) columns, in XML order.
const INSTANCE_DEFAULTS = [
  "Name",
  "Workflow_Name__c",
  "Status__c",
  "Correlation_Key__c",
  "Definition_Version__c",
  "Current_Step__c",
  "Terminal_At__c",
  "Error_Message__c",
  "Failure_Category__c",
  "Parent_Instance__c",
  "Concurrency_Parked__c",
  "CreatedDate",
  "LastModifiedDate",
];
const JOIN_INSTANCE_DEFAULTS = [
  "Name",
  "Workflow_Name__c",
  "Status__c",
  "Correlation_Key__c",
];
const STEP_DEFAULTS = [
  "Name",
  "Step_Name__c",
  "Status__c",
  "Retry_Count__c",
  "Transient_Retry_Count__c",
  "CreatedDate",
  "LastModifiedDate",
];

const kids = (node, name) => node.children.filter((c) => c.name === name);
const value = (node, name) => kids(node, name)[0]?.text;

function loadType(name) {
  const path = `${MAIN}/reportTypes/${name}.reportType-meta.xml`;
  assert.ok(existsSync(join(ROOT, path)), `missing ${path}`);
  const source = read(path);
  const xml = parseXml(source);
  assert.equal(xml.name, "ReportType");
  checkOrder(xml, REPORT_TYPE_SCHEMA);
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

test("the report types folder has the two Revenant types only", () => {
  const files = readdirSync(join(ROOT, MAIN, "reportTypes")).sort();
  assert.deepEqual(
    files,
    Object.values(TYPES)
      .map((n) => `${n}.reportType-meta.xml`)
      .sort(),
  );
});

test("each type has the base object, category other, deployed true and a Revenant label", () => {
  for (const name of Object.values(TYPES)) {
    const { xml } = loadType(name);
    assert.equal(value(xml, "baseObject"), INSTANCE, name);
    assert.equal(value(xml, "category"), "other", name);
    assert.equal(value(xml, "deployed"), "true", name);
    const label = value(xml, "label");
    assert.match(label, /^Revenant Workflow Instances/, name);
    assert.ok(label.length <= 50, `${name} label is over 50 characters`);
    const description = value(xml, "description");
    assert.ok(description.length > 0, `${name} has no description`);
    assert.ok(description.length <= 255, `${name} description is over 255`);
  }
});

test("the instance type has no join and checks the operator fields only", () => {
  const type = loadType(TYPES.instances);
  assert.equal(kids(type.xml, "join").length, 0);
  assert.equal(value(type.xml, "label"), "Revenant Workflow Instances");
  assert.equal(type.sections.length, 1);
  assert.ok(type.columns.every((c) => c.table === INSTANCE));
  assert.deepEqual(checked(type, INSTANCE), INSTANCE_DEFAULTS);
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
  );
  assert.ok(relationship, "the master-detail field has no relationshipName");
  assert.equal(value(joins[0], "relationship"), `${relationship[1]}__r`);
  assert.equal(STEPS_TABLE, `${INSTANCE}.${relationship[1]}__r`);
});

test("the step type checks name, retries, status and duration timestamps", () => {
  const type = loadType(TYPES.withSteps);
  assert.deepEqual(
    type.sections.map((s) => s.label),
    ["Workflow Instances", "Workflow Step Executions"],
  );
  assert.deepEqual(checked(type, INSTANCE), JOIN_INSTANCE_DEFAULTS);
  assert.deepEqual(checked(type, STEPS_TABLE), STEP_DEFAULTS);
});

test("the doc default-column table matches the XML", () => {
  const doc = read(DOC);
  const table = doc.slice(doc.indexOf("## Default columns"));
  const row = (label) => {
    const line = table.split("\n").find((l) => l.startsWith(`| ${label}`));
    assert.ok(line, `no row ${label}`);
    return [...line.split("|")[2].matchAll(/`(\w+)`/g)].map((m) => m[1]);
  };
  assert.deepEqual(row("Instance (first type)"), INSTANCE_DEFAULTS);
  assert.deepEqual(row("Instance (second type)"), JOIN_INSTANCE_DEFAULTS);
  assert.deepEqual(row("Step (second type)"), STEP_DEFAULTS);
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

test("no type shows a stored-form field or an engine internal", () => {
  for (const name of Object.values(TYPES)) {
    const type = loadType(name);
    for (const table of [INSTANCE, STEPS_TABLE]) {
      const object = objectOf(table);
      const hidden = [
        ...STORED_FORM_FIELDS[object],
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
      ...STORED_FORM_FIELDS[object],
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

test("the stored-form fields are the fields that the engine Apex writes a stored form to", () => {
  const dir = join(ROOT, MAIN, "classes");
  const files = readdirSync(dir)
    .filter((f) => f.endsWith(".cls"))
    .map((f) => ({ name: f, source: readFileSync(join(dir, f), "utf8") }));
  const expected = [
    ...new Set(Object.values(STORED_FORM_FIELDS).flat()),
  ].sort();
  const known = new Set([...FIELDS[INSTANCE].keys(), ...FIELDS[STEP].keys()]);
  const found = [...scanStoredFormFields(files)]
    .filter((f) => known.has(f))
    .sort();
  assert.deepEqual(found, expected);
  // The scan knows the field name only. Thus no column can have a found name.
  for (const name of Object.values(TYPES)) {
    const leaks = loadType(name).columns.filter((c) => found.includes(c.field));
    assert.deepEqual(leaks, [], `${name} shows a stored-form field name`);
  }
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
      if (/<required>true<\/required>/.test(FIELDS[object].get(field))) {
        continue;
      }
      assert.ok(
        readable.has(`${object}.${field}`),
        `${set} cannot read ${object}.${field}`,
      );
    }
  }
});

test("the doc names the types, the excluded fields, access and plaintext columns", () => {
  const doc = read(DOC);
  for (const text of [
    "Revenant Workflow Instances",
    "Revenant Workflow Instances with Step Executions",
    "Other Reports",
    "Revenant_Operator",
    "field-level security",
    "## Plaintext columns",
    "payload-codec.md",
    "`YESTERDAY`",
    "`CompensationFailed`",
    "Subscribe",
  ]) {
    assert.ok(doc.includes(text), `${DOC} does not name ${text}`);
  }
  const excluded = [
    ...Object.values(STORED_FORM_FIELDS).flat(),
    ...Object.values(INTERNAL_FIELDS).flatMap(Object.keys),
  ];
  for (const f of new Set(excluded)) {
    assert.ok(doc.includes(`\`${f}\``), `${DOC} does not name ${f}`);
  }
  assert.ok(
    read("README.md").includes("(docs/report-types.md)"),
    "README link",
  );
});
