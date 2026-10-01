/**
 * @description Builds and dispatches the HTML email notifications used by the workflow
 * alerting subsystem. Encapsulates recipient parsing, HTML escaping and the failure and
 * stall email templates so the alert manager stays focused on orchestration. All dispatch
 * is best-effort and swallows failures so alerting can never disrupt callers.
 */
public inherited sharing class WorkflowAlertEmailBuilder {
  private static final Integer MAX_ADDRESS_LENGTH = 254;
  private static final Integer MAX_LOCAL_LENGTH = 64;
  private static final Integer MAX_LABEL_LENGTH = 63;
  // Dot-separated local atoms, then two or more dot-separated domain labels.
  private static final String LOCAL_ATOM = '[A-Za-z0-9!#$%&\'*+/=?^_`{|}~-]+';
  private static final String DOMAIN_LABEL = '[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?';
  private static final String ADDRESS_REGEX =
    LOCAL_ATOM +
    '(?:\\.' +
    LOCAL_ATOM +
    ')*@' +
    DOMAIN_LABEL +
    '(?:\\.' +
    DOMAIN_LABEL +
    ')+';

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
        '<tr><td style="padding: 6px 0; font-weight: bold;">Current Step:</td><td>' +
        escapedStep(instance) +
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
   * @description Sends one email and checks the result (issue #113). Keeps
   * one email invocation free for the caller. Does not throw.
   * @param mail The email to send.
   * @return True when the platform accepted the email.
   */
  public static Boolean sendEmail(Messaging.SingleEmailMessage mail) {
    if (
      mail == null ||
      Limits.getEmailInvocations() + 1 >= Limits.getLimitEmailInvocations()
    ) {
      return false;
    }
    try {
      if (Test.isRunningTest()) {
        if (WorkflowAlertManager.throwTestException) {
          throw new IllegalArgumentException('Simulated email exception');
        }
      } else {
        for (
          Messaging.SendEmailResult result : Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ mail },
            false
          )
        ) {
          if (!result.isSuccess()) {
            return false;
          }
        }
      }
      WorkflowAlertManager.sentEmailsCount += 1;
      return true;
    } catch (Exception ex) {
      return false;
    }
  }

  /**
   * @description Sends the emails in one call (issue #139). Keeps one email
   * invocation free for the caller. Does not throw.
   * @param mails The emails to send.
   * @return One result for each email, in the same order: true when the
   * platform accepted it.
   */
  public static List<Boolean> sendEmails(
    List<Messaging.SingleEmailMessage> mails
  ) {
    List<Boolean> results = new List<Boolean>();
    for (Integer i = 0; i < mails.size(); i++) {
      results.add(false);
    }
    if (
      mails.isEmpty() ||
      Limits.getEmailInvocations() + 1 >= Limits.getLimitEmailInvocations()
    ) {
      return results;
    }
    try {
      if (Test.isRunningTest()) {
        if (WorkflowAlertManager.throwTestException) {
          throw new IllegalArgumentException('Simulated email exception');
        }
        for (Integer i = 0; i < mails.size(); i++) {
          results[i] = true;
        }
      } else {
        List<Messaging.SendEmailResult> sent = Messaging.sendEmail(
          mails,
          false
        );
        for (Integer i = 0; i < sent.size(); i++) {
          results[i] = sent[i].isSuccess();
        }
      }
    } catch (Exception ex) {
      // A failed call leaves each result false.
    }
    for (Boolean ok : results) {
      if (ok) {
        WorkflowAlertManager.sentEmailsCount += 1;
      }
    }
    return results;
  }

  /**
   * @description Builds a watchdog stall email (issue #113). Returns null
   * when no recipient is valid or the build fails.
   * @param recipients The raw, delimiter-separated recipient address list.
   * @param message The stall message. It contains no user data.
   * @return The email message, or null.
   */
  public static Messaging.SingleEmailMessage buildWatchdogStallEmail(
    String recipients,
    String message
  ) {
    try {
      List<String> toAddresses = parseRecipients(recipients);
      if (toAddresses.isEmpty()) {
        return null;
      }
      Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
      mail.setToAddresses(toAddresses);
      mail.setSubject('[Revenant Alert] Watchdog Stalled');
      String htmlBody =
        '<div style="font-family: sans-serif; padding: 20px; border: 1px solid #e2e8f0; border-radius: 8px; max-width: 600px;">' +
        '<h2 style="color: #e53e3e; margin-top: 0;">Watchdog Stalled</h2>' +
        '<p>' +
        message.escapeHtml4() +
        '</p>' +
        '<p style="font-size: 14px; color: #718096; margin-bottom: 0;">Open System Doctor in the Workflow Dashboard to examine the watchdog.</p>' +
        '</div>';
      mail.setHtmlBody(htmlBody);
      WorkflowAlertManager.lastHtmlBody = htmlBody;
      return mail;
    } catch (Exception ex) {
      return null;
    }
  }

  /**
   * @description True when the list has one or more addresses after the split. A list
   * of only separators has none.
   * @param recipients The raw, delimiter-separated recipient address list, or null.
   * @return True when an email can go to someone.
   */
  public static Boolean hasRecipients(String recipients) {
    return String.isNotBlank(recipients) &&
      !parseRecipients(recipients).isEmpty();
  }

  /**
   * @description Splits, trims and drops blank and invalid recipient addresses (#265).
   * A list with valid and invalid addresses keeps the valid ones.
   * @param recipients The raw, delimiter-separated recipient address list.
   * @return The valid recipient addresses.
   */
  public static List<String> parseRecipients(String recipients) {
    List<String> toAddresses = new List<String>();
    for (String token : tokens(recipients)) {
      if (isValidAddress(token)) {
        toAddresses.add(token);
      }
    }
    return toAddresses;
  }

  /**
   * @description Lists the non-blank tokens that are not valid addresses (#265).
   * @param recipients The raw, delimiter-separated recipient address list, or null.
   * @return The invalid tokens, in list order.
   */
  public static List<String> invalidRecipients(String recipients) {
    List<String> invalid = new List<String>();
    for (String token : tokens(recipients)) {
      if (!isValidAddress(token)) {
        invalid.add(token);
      }
    }
    return invalid;
  }

  /**
   * @description Conservative syntax check. It needs one @, a dotted domain, no
   * spaces, 254 characters or fewer, a local part of 64 or fewer and domain labels
   * of 63 or fewer. It does not check that the address can receive mail.
   * @param address One trimmed address, or null.
   * @return True when the address has a valid shape.
   */
  public static Boolean isValidAddress(String address) {
    if (
      address == null ||
      address.length() > MAX_ADDRESS_LENGTH ||
      !Pattern.matches(ADDRESS_REGEX, address)
    ) {
      return false;
    }
    Integer at = address.indexOf('@');
    if (at > MAX_LOCAL_LENGTH) {
      return false;
    }
    for (String label : address.substring(at + 1).split('\\.')) {
      if (label.length() > MAX_LABEL_LENGTH) {
        return false;
      }
    }
    return true;
  }

  private static List<String> tokens(String recipients) {
    List<String> result = new List<String>();
    if (recipients == null) {
      return result;
    }
    for (String part : recipients.split('[,;]')) {
      if (String.isNotBlank(part)) {
        result.add(part.trim());
      }
    }
    return result;
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

  // A caller of WorkflowAlertManager.buildStallEmail can give an instance
  // with no Current_Step__c in its query. A read of that field throws, so
  // check it first.
  private static String escapedStep(Workflow_Instance__c instance) {
    Object step = instance.getPopulatedFieldsAsMap().get('Current_Step__c');
    return step == null || String.isBlank((String) step)
      ? 'N/A'
      : ((String) step).escapeHtml4();
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
