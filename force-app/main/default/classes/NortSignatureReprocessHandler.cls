/**
 * Handles the Force_Reprocess__c "action checkbox" on Error Signatures. When an
 * admin checks the box and saves, this requeues the signature for diagnosis and
 * kicks off the drain chain — the same two steps an operator would otherwise run
 * by hand (set Diagnosis_Status__c = Queued, then NortDiagnosisQueueable.dispatch()).
 *
 * It never invokes the agent itself: spend stays confined to NortDiagnosisQueueable
 * (the project invariant). The handler only flips state and dispatches; the one
 * agent callout per signature happens later, inside the queueable.
 *
 * Designed for the before-update context, so the status change and the momentary
 * reset of Force_Reprocess__c persist with no second DML. Edge-triggered (only
 * acts when the box transitions to true) and bulk-safe: dispatch() is called at
 * most once and its singleton guard lets a live chain sweep up every newly
 * queued row via NortDiagnosisQueueable.nextQueuedSignature (First_Seen__c ASC).
 */
public with sharing class NortSignatureReprocessHandler {
    private NortSignatureReprocessHandler() {
        // Stateless handler; never instantiated.
    }

    /**
     * Requeues signatures whose Force_Reprocess__c just became true and resets
     * the box, then dispatches the diagnosis chain once if any were forced.
     *
     * @param newRows Trigger.new rows (mutated in place; before-update only).
     * @param oldMap  Trigger.oldMap, to detect the false→true transition.
     */
    public static void handle(List<Error_Signature__c> newRows, Map<Id, Error_Signature__c> oldMap) {
        Boolean anyForced = false;

        for (Error_Signature__c row : newRows) {
            Error_Signature__c priorRow = oldMap.get(row.Id);
            Boolean justChecked = row.Force_Reprocess__c == true
                && (priorRow == null || priorRow.Force_Reprocess__c != true);
            if (!justChecked) {
                continue;
            }

            // Requeue regardless of current status (including Diagnosing): a deliberate
            // admin override of both the cooldown and any in-flight diagnosis.
            row.Diagnosis_Status__c = NortConstants.DIAG_QUEUED;
            // Momentary reset: persists with this same before-update save, so the
            // checkbox behaves like a button rather than a sticky flag.
            row.Force_Reprocess__c = false;
            anyForced = true;
        }

        if (anyForced) {
            NortDiagnosisQueueable.dispatch();
        }
    }
}
