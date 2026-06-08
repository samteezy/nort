/**
 * DEMO / TEST FIXTURE — drives a real, reliable Apex exception email so the nort
 * loop can be exercised end to end against a live event. Saving a Lead whose Last
 * Name is "error" (case-insensitive) enqueues LeadErrorDemoQueueable, which throws
 * an unhandled exception in async context. Async unhandled exceptions reliably
 * email the Apex Exception Email recipients — including nort's inbound Email
 * Service address — without blocking the UI save.
 *
 * IMPORTANT: this class is deliberately NOT `Nort`-prefixed. nort's
 * self-exclusion guard (`nort_Exclusion__mdt`, ClassPrefix=Nort) drops events
 * originating from `Nort*` classes, so a Nort-prefixed name here would cause the
 * resulting event to be excluded and the test would silently produce nothing.
 *
 * Remove this class, LeadErrorDemoQueueable, and LeadErrorDemoTrigger once
 * end-to-end testing is done.
 */
public with sharing class LeadErrorDemo {
    @TestVisible
    private static final String TRIGGER_VALUE = 'error';

    /** Thrown intentionally to exercise the nort ingest pipeline. */
    public class DemoException extends Exception {}

    /**
     * Enqueues the failing async job if any incoming Lead's Last Name equals
     * "error" (case-insensitive). The Lead itself saves normally.
     *
     * @param leads The Leads being inserted/updated (Trigger.new).
     * @example
     * LeadErrorDemo.enqueueIfTriggered(Trigger.new);
     */
    public static void enqueueIfTriggered(List<Lead> leads) {
        if (leads == null) {
            return;
        }
        for (Lead candidate : leads) {
            if (candidate.LastName != null && candidate.LastName.equalsIgnoreCase(TRIGGER_VALUE)) {
                System.enqueueJob(new LeadErrorDemoQueueable());
                return;
            }
        }
    }
}
