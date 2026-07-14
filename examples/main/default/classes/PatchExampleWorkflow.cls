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
  /**
   * @description The saga workflow definition whose routing evolves via the
   * 'insert-flight' patch marker, optionally inserting BookFlight between BookHotel
   * and BookCar.
   */
  public class PatchSagaWorkflow implements WorkflowDefinition {
    /**
     * @description Declares the ordered step names comprising the booking saga.
     * @return The list of BookHotel, BookFlight, and BookCar step names.
     */
    public List<String> getSteps() {
      return new List<String>{
        'PatchExampleWorkflow.BookHotel',
        'PatchExampleWorkflow.BookFlight',
        'PatchExampleWorkflow.BookCar'
      };
    }

    /**
     * @description Names the step the engine runs first for a new instance.
     * @return The BookHotel step name.
     */
    public String getInitialStep() {
      return 'PatchExampleWorkflow.BookHotel';
    }

    /**
     * @description Routes to the next step, branching after BookHotel to include
     * BookFlight only when the completed step signalled insertFlight in its output.
     * @param currentStepName The name of the step that just completed.
     * @param result The result of the completed step, whose output drives the branch.
     * @return The next step name, or null when the saga is complete.
     */
    public String getNextStep(String currentStepName, StepResult result) {
      if (currentStepName == 'PatchExampleWorkflow.BookHotel') {
        if (result.directive().outputJson != null) {
          Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(
            result.directive().outputJson
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

  /**
   * @description Books the hotel and, via the 'insert-flight' patch marker, decides
   * whether newer instances route through BookFlight; compensates by cancelling.
   */
  public class BookHotel implements WorkflowStep, CompensatableStep {
    /**
     * @description Books the hotel, reads the 'insert-flight' patch to flag flight
     * insertion for routing, and demonstrates deprecated() throwing on retired patches.
     * @param ctx The durable step context exposing patched()/deprecated() and input.
     * @return A completed StepResult carrying hotelBooked and the insertFlight flag.
     */
    public StepResult execute(StepContext ctx) {
      // Determine if we should insert the flight step.
      // Brand new instances get true; in-flight instances past this point get false.
      Boolean insertFlight = ctx.captures().patched('insert-flight');

      // We can also demonstrate deprecated: if some retired patch is queried, it throws.
      if (
        ctx.inputJson != null && ctx.inputJson.contains('triggerRetiredError')
      ) {
        ctx.captures().deprecated('retired-patch'); // Should throw since 'retired-patch' defaults to false/deprecated if not recorded
      }

      return StepResult.complete(
        null,
        new Map<String, Object>{
          'hotelBooked' => true,
          'insertFlight' => insertFlight
        }
      );
    }

    /**
     * @description Compensates the hotel booking by recording its cancellation
     * when the saga unwinds.
     * @param ctx The durable step context for the compensation invocation.
     * @return A completed StepResult carrying hotelCancelled.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'hotelCancelled' => true }
      );
    }
  }

  /**
   * @description The patch-inserted flight-booking step, present only on instances
   * routed through it by the 'insert-flight' marker; compensates by cancelling.
   */
  public class BookFlight implements WorkflowStep, CompensatableStep {
    /**
     * @description Books the flight.
     * @param ctx The durable step context for this execution.
     * @return A completed StepResult carrying flightBooked.
     */
    public StepResult execute(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'flightBooked' => true }
      );
    }

    /**
     * @description Compensates the flight booking by recording its cancellation
     * when the saga unwinds.
     * @param ctx The durable step context for the compensation invocation.
     * @return A completed StepResult carrying flightCancelled.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'flightCancelled' => true }
      );
    }
  }

  /**
   * @description Books the car, upgrading the class when the 'insert-flight' patch
   * indicates a flight was booked; compensates by cancelling.
   */
  public class BookCar implements WorkflowStep, CompensatableStep {
    /**
     * @description Books the car, choosing a Luxury SUV when the 'insert-flight'
     * patch is active and an Economy Sedan otherwise.
     * @param ctx The durable step context exposing the patched() marker.
     * @return A completed StepResult carrying carBooked and the chosen carType.
     */
    public StepResult execute(StepContext ctx) {
      Boolean hasFlight = ctx.captures().patched('insert-flight');
      String carType = hasFlight ? 'Luxury SUV' : 'Economy Sedan';

      return StepResult.complete(
        null,
        new Map<String, Object>{ 'carBooked' => true, 'carType' => carType }
      );
    }

    /**
     * @description Compensates the car booking by recording its cancellation when
     * the saga unwinds.
     * @param ctx The durable step context for the compensation invocation.
     * @return A completed StepResult carrying carCancelled.
     */
    public StepResult compensate(StepContext ctx) {
      return StepResult.complete(
        null,
        new Map<String, Object>{ 'carCancelled' => true }
      );
    }
  }
}
