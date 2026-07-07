/**
 * Reference example demonstrating inline named change markers (patched and deprecated)
 * to evolve a live workflow definition.
 *
 * Demonstrates:
 * 1. Inserting a new step ('BookFlight') between 'BookHotel' and 'BookCar' using patched('insert-flight').
 * 2. Conditionally adding flight info to 'BookCar' based on the same patch marker.
 * 3. Using deprecated('retired-patch') to retire older paths safely.
 */
public inherited sharing class PatchExampleWorkflow {
  public class PatchSagaWorkflow implements WorkflowDefinition {
    public List<String> getSteps() {
      return new List<String>{
        'PatchExampleWorkflow.BookHotel',
        'PatchExampleWorkflow.BookFlight',
        'PatchExampleWorkflow.BookCar'
      };
    }

    public String getInitialStep() {
      return 'PatchExampleWorkflow.BookHotel';
    }

    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'PatchExampleWorkflow.BookHotel') {
        if (result.outputJson != null) {
          Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
            result.outputJson
          );
          Boolean insertFlight =
            output.get('insertFlight') != null &&
            (Boolean) output.get('insertFlight');
          return insertFlight
            ? 'PatchExampleWorkflow.BookFlight'
            : 'PatchExampleWorkflow.BookCar';
        }
        return 'PatchExampleWorkflow.BookCar';
      }
      if (currentStepName == 'PatchExampleWorkflow.BookFlight') {
        return 'PatchExampleWorkflow.BookCar';
      }
      return null; // End of workflow
    }
  }

  public class BookHotel implements WorkflowStep, CompensatableStep {
    public StepResult execute(StepContext ctx) {
      // Determine if we should insert the flight step.
      // Brand new instances get true; in-flight instances past this point get false.
      Boolean insertFlight = ctx.patched('insert-flight');

      // We can also demonstrate deprecated: if some retired patch is queried, it throws.
      if (
        ctx.inputJson != null && ctx.inputJson.contains('triggerRetiredError')
      ) {
        ctx.deprecated('retired-patch'); // Should throw since 'retired-patch' defaults to false/deprecated if not recorded
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'hotelBooked' => true,
          'insertFlight' => insertFlight
        }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'hotelCancelled' => true }
      );
    }
  }

  public class BookFlight implements WorkflowStep, CompensatableStep {
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'flightBooked' => true }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'flightCancelled' => true }
      );
    }
  }

  public class BookCar implements WorkflowStep, CompensatableStep {
    public StepResult execute(StepContext ctx) {
      Boolean hasFlight = ctx.patched('insert-flight');
      String carType = hasFlight ? 'Luxury SUV' : 'Economy Sedan';

      return StepResult.complete(
        null,
        new Map<String, Object>{ 'carBooked' => true, 'carType' => carType }
      );
    }

    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'carCancelled' => true }
      );
    }
  }
}
