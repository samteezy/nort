/**
 * DEMO / TEST FIXTURE — throws an unhandled exception in async (Queueable)
 * context so Salesforce reliably sends an Apex exception email for nort
 * end-to-end testing. Enqueued by LeadErrorDemo when a Lead named "error" is
 * saved. Deliberately NOT Nort-prefixed (see LeadErrorDemo). Delete together
 * with the rest of the demo fixture.
 *
 * NOTE on Salesforce email dedup: "If duplicate exceptions occur ... subsequent
 * exception emails are suppressed and only the first email is sent" (~1 hr per
 * unique exception). To re-test within that window, change the exception TYPE or
 * its throw location below so Salesforce treats it as a new, non-duplicate
 * exception — varying only the message is not enough.
 */
public with sharing class LeadErrorDemoQueueable implements Queueable {
    /** Distinct type so each probe isn't deduped against earlier DemoException throws. */
    public class ProbeException extends Exception {}

    public void execute(QueueableContext context) {
        throw new ProbeException(
            'nort end-to-end probe: unhandled async exception from LeadErrorDemoQueueable.'
        );
    }
}
