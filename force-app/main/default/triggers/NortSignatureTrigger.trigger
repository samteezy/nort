/**
 * Thin trigger that turns the Force_Reprocess__c "action checkbox" on an Error
 * Signature into an immediate agent re-diagnosis. All logic lives in the
 * Nort-prefixed handler (preserving the self-exclusion loop guard); the trigger
 * only delegates. Runs before update so the handler's field writes persist with
 * no extra DML, and so System.enqueueJob is permitted (the agent callout fires
 * later, inside NortDiagnosisQueueable — never from this trigger).
 */
trigger NortSignatureTrigger on Error_Signature__c (before update) {
    NortSignatureReprocessHandler.handle(Trigger.new, Trigger.oldMap);
}
