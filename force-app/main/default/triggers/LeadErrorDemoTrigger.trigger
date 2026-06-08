/**
 * DEMO / TEST FIXTURE — enqueues LeadErrorDemoQueueable when a Lead whose Last
 * Name is "error" is saved, producing a reliable async Apex exception email for
 * nort end-to-end testing. The Lead saves normally. Deliberately NOT
 * Nort-prefixed (see LeadErrorDemo). Delete together with the rest of the demo
 * fixture (LeadErrorDemo, LeadErrorDemoQueueable).
 */
trigger LeadErrorDemoTrigger on Lead (after insert, after update) {
    LeadErrorDemo.enqueueIfTriggered(Trigger.new);
}
