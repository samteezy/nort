/**
 * DEMO / TEST FIXTURE — throws an unhandled exception in async (Queueable)
 * context so Salesforce reliably sends an Apex exception email for nort
 * end-to-end testing. Enqueued by LeadErrorDemo when a Lead named "error" is
 * saved. Deliberately NOT Nort-prefixed (see LeadErrorDemo). Delete together
 * with the rest of the demo fixture.
 */
public with sharing class LeadErrorDemoQueueable implements Queueable {
    public void execute(QueueableContext context) {
        throw new LeadErrorDemo.DemoException(
            'Intentional nort end-to-end test error: Lead LastName set to "error" (async).'
        );
    }
}
