// Unit tests of the report type test helpers (issue #137).
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkOrder, parseXml } from "./xml.mjs";
import { scanStoredFormFields } from "./stored-form-scan.mjs";

const SCHEMA = {
  root: ["a", "b?", "c+"],
  c: ["d", "e"],
};

test("parseXml reads elements, text and self-closed tags", () => {
  const xml = parseXml(
    '<?xml version="1.0"?><r x="1"><a>t &amp; u</a><b/></r>',
  );
  assert.equal(xml.name, "r");
  assert.deepEqual(
    xml.children.map((c) => c.name),
    ["a", "b"],
  );
  assert.equal(xml.children[0].text, "t &amp; u");
});

test("parseXml rejects malformed files", () => {
  for (const bad of [
    "<a><b></a>",
    "<a>",
    "<a></a><b></b>",
    "<a>x < y</a>",
    "<a>></a>",
    "<a>x & y</a>",
    "<a></a>junk",
    "<a>text<b>1</b></a>",
    "<a><b> padded </b></a>",
  ]) {
    assert.throws(() => parseXml(bad), undefined, bad);
  }
});

test("checkOrder accepts the schema order", () => {
  checkOrder(parseXml("<root><a>1</a><c><d/><e/></c></root>"), SCHEMA);
  checkOrder(
    parseXml("<root><a>1</a><b>2</b><c><d/><e/></c><c><d/><e/></c></root>"),
    SCHEMA,
  );
});

test("checkOrder rejects order, typo, unknown, missing and duplicate elements", () => {
  for (const bad of [
    "<root><b>2</b><a>1</a><c><d/><e/></c></root>",
    "<root><aa>1</aa><c><d/><e/></c></root>",
    "<root><a>1</a><c><d/><x/><e/></c></root>",
    "<root><a>1</a><c><d/></c></root>",
    "<root><a>1</a><a>1</a><c><d/><e/></c></root>",
    "<root><a>1</a></root>",
    "<root><a><x/></a><c><d/><e/></c></root>",
  ]) {
    assert.throws(() => checkOrder(parseXml(bad), SCHEMA), undefined, bad);
  }
});

const cls = (name, body) => ({
  name: `${name}.cls`,
  source: `public class ${name} {\n${body}\n}`,
});
const scan = (...args) => {
  const options = args.at(-1)?.copyFrom ? args.pop() : {};
  return [...scanStoredFormFields(args, options)].sort();
};
const ENCODE = "WorkflowPayloadCodecs.encode(x, k)";

test("scan finds a direct assignment and a put call", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          i.Output__c = WorkflowPayloadOffload.savePayloadIfNeeded(a, b, c);
          i.put('Hold_Reason__c', ${ENCODE});
          i.Input__c = ok ? ${ENCODE} : null;
          Workflow_Instance__c n = new Workflow_Instance__c(Status__c = 'x', Progress__c = ${ENCODE});
        }`,
      ),
    ),
    ["Hold_Reason__c", "Input__c", "Output__c", "Progress__c"],
  );
});

test("scan follows a local variable and a helper method", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          String s = ${ENCODE};
          i.Error_Message__c = s;
        }`,
      ),
      cls(
        "Helper",
        `public static String wrap(String x) {
          String stored = WorkflowPayloadOffload.savePayloadIfNeeded(p, x, t);
          return 'r' + stored;
        }
        public static String other(String x) { return x; }`,
      ),
      cls(
        "B",
        `void m() {
          e.Error_Details__c = Helper.wrap(y);
          e.Status__c = Helper.other(y);
        }`,
      ),
    ),
    ["Error_Details__c", "Error_Message__c"],
  );
});

test("scan sees through literals, strings and nested calls", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          i.Correlation_Key__c = foo(new Map<String, Object>{ 'a' => ${ENCODE} });
          i.Root_Correlation_Key__c = '{;}' + ${ENCODE};
        }`,
      ),
    ),
    ["Correlation_Key__c", "Root_Correlation_Key__c"],
  );
});

test("scan ignores comments, other statements and test classes", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          // i.Status__c = ${ENCODE};
          /* i.Current_Step__c = ${ENCODE}; */
          if (x) { i.Output__c = y; }
          i.Input__c = z;
          ${ENCODE};
        }`,
      ),
      {
        name: "ATest.cls",
        source: `@IsTest\nprivate class ATest {\n void t() { i.Output__c = ${ENCODE}; }\n}`,
      },
    ),
    [],
  );
});

test("scan handles spaced dots, comments with ; and copies of a pointer field", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          i.Current_Step__c = WorkflowPayloadOffload . savePayloadIfNeeded(a, b, c);
          i.Hold_Reason__c = cond // note; more
            ? ${ENCODE} : null;
          i.Error_Message__c = s.Error_Details__c;
          i.Status__c = String.isBlank(s.Output__c) ? 'a' : 'b';
        }`,
      ),
      { copyFrom: ["Error_Details__c", "Output__c"] },
    ),
    ["Current_Step__c", "Error_Message__c", "Hold_Reason__c"],
  );
});

test("scan does not count a self-copy and needs a real writer", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          n.Input__c = old.Input__c;
          n.Progress__c = old.Progress__c;
        }`,
      ),
      { copyFrom: ["Input__c", "Progress__c"] },
    ),
    [],
  );
});

test("scan skips SOQL binds and follows unbraced returns, += and two locals", () => {
  assert.deepEqual(
    scan(
      cls(
        "A",
        `void m() {
          r.Hold_Reason__c = foo([SELECT Id FROM X WHERE Name__c = :n], ${ENCODE});
          String a = ${ENCODE};
          String b = a;
          i.Current_Step__c = b;
          String c = 'x';
          c += ${ENCODE};
          i.Error_Message__c = c;
        }`,
      ),
      cls(
        "H",
        `public static String w(Boolean c) {
          if (c) return ${ENCODE};
          else return null;
        }
        public static List<String> encode(String x) { return null; }`,
      ),
      cls("B", `void m() { i.Causation_Id__c = H.w(true); }`),
    ),
    [
      "Causation_Id__c",
      "Current_Step__c",
      "Error_Message__c",
      "Hold_Reason__c",
    ],
  );
});

test("parseXml rejects a raw & in an attribute", () => {
  assert.throws(() => parseXml('<a x="b & c"></a>'));
});

test("checkOrder matches a schema name literally", () => {
  assert.throws(() => checkOrder(parseXml("<r><aXb/></r>"), { r: ["a.b"] }));
});
