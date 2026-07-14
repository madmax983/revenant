/**
 * @description Builds and dispatches the HTML email notifications used by the workflow
 * alerting subsystem. Encapsulates recipient parsing, HTML escaping and the failure and
 * stall email templates so the alert manager stays focused on orchestration. All dispatch
 * is best-effort and swallows failures so alerting can never disrupt callers.
 */
public inherited sharing class WorkflowAlertEmailBuilder {
  /**
   * @description Escaped, display-safe view of a workflow instance's identifying fields,
   * shared by the failure and stall email bodies.
   */
  private class EscapedInstance {
    /** @description HTML-escaped workflow developer name. */
    public String workflowName;
    /** @description HTML-escaped instance record name. */
    public String instanceName;
    /** @description HTML-escaped instance record id. */
    public String instanceId;
    /** @description HTML-escaped correlation key, or 'N/A' when absent. */
    public String correlationKey;
    /** @description HTML-escaped current instance status. */
    public String status;
  }

  /**
   * @description Builds and sends a failure alert email for a workflow instance. No email is
   * sent when the recipient list is empty. Failures are swallowed so alerting never disrupts
   * the caller.
   * @param instance The failed workflow instance to describe in the email.
   * @param recipients The raw, delimiter-separated recipient address list.
   * @param errorMsg The error detail to include in the email body.
   */
  public static void dispatchEmail(
    Workflow_Instance__c instance,
    String recipients,
    String errorMsg
  ) {
    List<String> toAddresses = parseRecipients(recipients);
    if (toAddresses.isEmpty()) {
      return;
    }

    Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
    mail.setToAddresses(toAddresses);

    String subject =
      '[Revenant Alert] Workflow Failure: ' + instance.Workflow_Name__c;
    mail.setSubject(subject);

    EscapedInstance esc = escapeInstance(instance);
    String escapedErrorMsg = escapeErrorForEmail(errorMsg);

    String htmlBody =
      '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
      '<h2 style="color: #e53e3e; margin-top: 0;">Workflow Execution Failed</h2>' +
      '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
      '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
      '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
      esc.workflowName +
      '</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
      esc.instanceName +
      ' (' +
      esc.instanceId +
      ')</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
      esc.correlationKey +
      '</td></tr>' +
      '<tr><td style="padding: 6px 0; font-weight: bold;">Failed Time:</td><td>' +
      Datetime.now().format() +
      '</td></tr>' +
      '</table>' +
      '<div style="background-color: #fff5f5; border: 1px solid #fed7d7; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c53030;">' +
      '<strong>Error Details:</strong><br/><pre style="white-space: pre-wrap; font-family: monospace; margin: 5px 0 0 0;">' +
      escapedErrorMsg +
      '</pre>' +
      '</div>' +
      '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and retry this workflow, open the Workflow Dashboard in Salesforce.</p>' +
      '</div>';

    mail.setHtmlBody(htmlBody);
    WorkflowAlertManager.lastHtmlBody = htmlBody;

    try {
      if (!Test.isRunningTest()) {
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
      } else if (WorkflowAlertManager.throwTestException) {
        throw new IllegalArgumentException('Simulated email exception');
      }
    } catch (Exception ignored) {
    }
    WorkflowAlertManager.sentEmailsCount += 1;
  }

  /**
   * @description Builds a stall alert email message without sending it, returning null when
   * alerting is disabled, no recipients are configured, or construction fails.
   * @param request The stall alert inputs (instance, config, idle and threshold minutes).
   * @return A ready-to-send email message, or null when no email should be sent.
   */
  public static Messaging.SingleEmailMessage buildStallEmail(
    WorkflowAlertManager.StallAlertRequest request
  ) {
    try {
      Workflow_Alert_Config__mdt config = request.config;
      if (
        config == null ||
        !config.Enable_Alerts__c ||
        String.isBlank(config.Email_Recipients__c)
      ) {
        return null;
      }

      List<String> toAddresses = parseRecipients(config.Email_Recipients__c);
      if (toAddresses.isEmpty()) {
        return null;
      }

      Workflow_Instance__c instance = request.instance;
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(toAddresses);

      String subject =
        '[Revenant Alert] Workflow Stalled: ' + instance.Workflow_Name__c;
      mail.setSubject(subject);

      EscapedInstance esc = escapeInstance(instance);
      Integer idleMinutes = request.idleMinutes;
      Integer thresholdMinutes = request.thresholdMinutes;

      String htmlBody =
        '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
        '<h2 style="color: #dd6b20; margin-top: 0;">Workflow Execution Stalled</h2>' +
        '<hr style="border: 0; border-top: 1px solid #e2e8f0; margin-bottom: 20px;"/>' +
        '<table style="width: 100%; border-collapse: collapse; margin-bottom: 20px;">' +
        '<tr><td style="padding: 6px 0; font-weight: bold; width: 150px;">Workflow Name:</td><td>' +
        esc.workflowName +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Instance ID:</td><td>' +
        esc.instanceName +
        ' (' +
        esc.instanceId +
        ')</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Correlation Key:</td><td>' +
        esc.correlationKey +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Current Status:</td><td>' +
        esc.status +
        '</td></tr>' +
        '<tr><td style="padding: 6px 0; font-weight: bold;">Idle Duration:</td><td>' +
        idleMinutes +
        ' minutes (threshold: ' +
        thresholdMinutes +
        ' minutes)</td></tr>' +
        '</table>' +
        '<div style="background-color: #fffaf0; border: 1px solid #feebc8; border-radius: 4px; padding: 15px; margin-bottom: 20px; color: #c05621;">' +
        '<strong>Stall Details:</strong><br/>' +
        'The workflow has been inactive for ' +
        idleMinutes +
        ' minutes in status ' +
        esc.status +
        '.' +
        '</div>' +
        '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">To view and manage this workflow, open the Workflow Dashboard in Salesforce.</p>' +
        '</div>';

      mail.setHtmlBody(htmlBody);
      WorkflowAlertManager.lastHtmlBody = htmlBody;

      return mail;
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * @description Splits, trims and drops blank recipient addresses.
   * @param recipients The raw, delimiter-separated recipient address list.
   * @return The cleaned list of individual recipient addresses.
   */
  private static List<String> parseRecipients(String recipients) {
    List<String> toAddresses = new List<String>();
    for (String email : recipients.split('[,;]')) {
      if (String.isNotBlank(email)) {
        toAddresses.add(email.trim());
      }
    }
    return toAddresses;
  }

  /**
   * @description Escapes the instance fields shared by the failure and stall email bodies.
   * @param instance The workflow instance whose fields should be display-escaped.
   * @return A display-safe, HTML-escaped view of the instance's identifying fields.
   */
  private static EscapedInstance escapeInstance(Workflow_Instance__c instance) {
    EscapedInstance esc = new EscapedInstance();
    esc.workflowName = String.isBlank(instance.Workflow_Name__c)
      ? ''
      : instance.Workflow_Name__c.escapeHtml4();
    esc.instanceName = String.isBlank(instance.Name)
      ? ''
      : instance.Name.escapeHtml4();
    esc.instanceId = instance.Id == null
      ? ''
      : String.valueOf(instance.Id).escapeHtml4();
    esc.correlationKey = String.isNotBlank(instance.Correlation_Key__c)
      ? instance.Correlation_Key__c.escapeHtml4()
      : 'N/A';
    esc.status = String.isBlank(instance.Status__c)
      ? ''
      : instance.Status__c.escapeHtml4();
    return esc;
  }

  /**
   * @description Truncates (to 5000 chars) and HTML-escapes the failure error message.
   * @param errorMsg The raw error message to sanitize for the email body.
   * @return The truncated, HTML-escaped error message, or an empty string when blank.
   */
  private static String escapeErrorForEmail(String errorMsg) {
    String truncatedErrorMsg = errorMsg;
    if (
      String.isNotBlank(truncatedErrorMsg) && truncatedErrorMsg.length() > 5000
    ) {
      truncatedErrorMsg =
        truncatedErrorMsg.substring(0, 5000) + '... (truncated)';
    }
    return String.isBlank(truncatedErrorMsg)
      ? ''
      : truncatedErrorMsg.escapeHtml4();
  }
}
