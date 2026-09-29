// Anti-pattern: route on the running user. An operator re-drive runs as another user.
public class UserRoutingStep implements WorkflowStep {
  public StepResult execute(StepContext ctx) {
    if (UserInfo.getUserType() == 'Guest') { // expect: USER_CONTEXT
      return StepResult.fail('guest');
    }
    Id owner = UserInfo.getUserId(); // expect: USER_CONTEXT
    String locale = USERINFO.GETLOCALE(); // expect: USER_CONTEXT
    return StepResult.complete(null, owner + locale);
  }
}
