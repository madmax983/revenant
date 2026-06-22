import { createElement } from "lwc";
import WorkflowInstanceDetail from "c/workflowInstanceDetail";

const DETAIL = {
  instance: {
    Id: "a01000000000001AAA",
    Name: "WFI-000001",
    Workflow_Name__c: "OrderFulfillment",
    Status__c: "Failed",
    Correlation_Key__c: "001000000000001AAA",
    CreatedDate: "2026-06-20T10:00:00.000Z",
    Error_Message__c: "Endpoint down",
  },
  steps: [
    {
      Id: "b01000000000001AAA",
      Step_Name__c: "OrderFulfillment.ChargeCard",
      Status__c: "Failed",
      Retry_Count__c: 2,
      CreatedDate: "2026-06-20T10:01:00.000Z",
      Error_Details__c: "boom",
    },
  ],
  children: [],
  successor: null,
  waitingOn: null,
  pendingCompensations: [],
  pendingCompensationCount: 0,
  payloadFiles: {},
};

function createComponent(props = {}) {
  const element = createElement("c-workflow-instance-detail", {
    is: WorkflowInstanceDetail,
  });
  Object.assign(element, props);
  document.body.appendChild(element);
  return element;
}

describe("c-workflow-instance-detail", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  it("renders the instance summary and step timeline from the detail map", async () => {
    const element = createComponent({ detail: DETAIL });
    await Promise.resolve();

    const text = element.shadowRoot.textContent;
    expect(text).toContain("WFI-000001");
    expect(text).toContain("OrderFulfillment.ChargeCard");
    expect(text).toContain("Failed");
  });

  it("hides all write actions when readOnly is true", async () => {
    const element = createComponent({ detail: DETAIL, readOnly: true });
    await Promise.resolve();

    // No action buttons (retry/resume/cancel) should be rendered in read-only mode.
    const buttons = element.shadowRoot.querySelectorAll("lightning-button");
    expect(buttons.length).toBe(0);
  });

  it("renders write actions and emits a retry event when not readOnly", async () => {
    const element = createComponent({ detail: DETAIL, readOnly: false });
    await Promise.resolve();

    const handler = jest.fn();
    element.addEventListener("retry", handler);

    const retryButton = element.shadowRoot.querySelector(
      '[data-action="retry"]',
    );
    expect(retryButton).not.toBeNull();
    retryButton.click();
    expect(handler).toHaveBeenCalled();
  });

  it("emits selectrelated with the target id when a related link is clicked", async () => {
    const detailWithChild = {
      ...DETAIL,
      children: [
        {
          Id: "a01000000000009AAA",
          Name: "WFI-000009",
          Workflow_Name__c: "SubFlow",
          Status__c: "Completed",
          Correlation_Key__c: "child-key",
        },
      ],
    };
    const element = createComponent({
      detail: detailWithChild,
      readOnly: true,
    });
    await Promise.resolve();

    const handler = jest.fn();
    element.addEventListener("selectrelated", handler);

    const childLink = element.shadowRoot.querySelector(".wf-related");
    expect(childLink).not.toBeNull();
    childLink.click();

    expect(handler).toHaveBeenCalled();
    expect(handler.mock.calls[0][0].detail.id).toBe("a01000000000009AAA");
  });
});
