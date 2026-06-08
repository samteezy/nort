/**
 * Drains Queued Error Signatures one at a time, invoking the Agentforce agent
 * per unique signature and handing the result to the case service. Self-chains
 * to the next Queued signature, so exactly one agent invocation happens per
 * transaction — pacing spend and staying clear of the per-transaction
 * enqueueJob limit even during a storm.
 *
 * Implements Database.AllowsCallouts because the agent invocation may perform a
 * callout. The Diagnosing status acts as a soft lock against double-processing.
 */
public with sharing class NortDiagnosisQueueable implements Queueable, Database.AllowsCallouts {
    /**
     * Enqueues the dispatcher to begin draining Queued signatures.
     *
     * @return The enqueued job Id, or null if enqueuing was skipped.
     */
    public static Id dispatch() {
        return System.enqueueJob(new NortDiagnosisQueueable());
    }

    /**
     * Processes the next Queued signature, then chains if more remain.
     *
     * @param context The queueable context.
     */
    public void execute(QueueableContext context) {
        Error_Signature__c signature = nextQueuedSignature();
        if (signature == null) {
            return;
        }

        markDiagnosing(signature);
        NortAgentInvoker.DiagnosisResult diagnosis = NortAgentInvoker.diagnose(toRequest(signature));
        applyResult(signature, diagnosis);

        chainIfMoreRemain();
    }

    private Error_Signature__c nextQueuedSignature() {
        List<Error_Signature__c> queued = [
            SELECT Id, Source__c, Apex_Class__c, Apex_Method__c, Exception_Type__c,
                   Message_Template__c, Flow_API_Name__c, Faulting_Element__c,
                   Fingerprint_Hash__c, Occurrence_Count__c, Agent_Invocation_Count__c,
                   Case__c, Root_Cause__c, Recommendation__c
            FROM Error_Signature__c
            WHERE Diagnosis_Status__c = :NortConstants.DIAG_QUEUED
            WITH SYSTEM_MODE
            ORDER BY First_Seen__c ASC
            LIMIT 1
        ];
        return queued.isEmpty() ? null : queued[0];
    }

    private void markDiagnosing(Error_Signature__c signature) {
        signature.Diagnosis_Status__c = NortConstants.DIAG_DIAGNOSING;
        Database.update(signature, true, AccessLevel.SYSTEM_MODE);
    }

    private NortAgentInvoker.DiagnosisRequest toRequest(Error_Signature__c signature) {
        NortAgentInvoker.DiagnosisRequest request = new NortAgentInvoker.DiagnosisRequest();
        request.signatureId = signature.Id;
        request.source = signature.Source__c;
        request.className = signature.Apex_Class__c;
        request.methodName = signature.Apex_Method__c;
        request.exceptionType = signature.Exception_Type__c;
        request.messageTemplate = signature.Message_Template__c;
        request.flowApiName = signature.Flow_API_Name__c;
        request.faultingElement = signature.Faulting_Element__c;
        return request;
    }

    private void applyResult(Error_Signature__c signature, NortAgentInvoker.DiagnosisResult diagnosis) {
        // Count every invocation attempt: this is the auditable spend ledger.
        signature.Agent_Invocation_Count__c = zeroIfNull(signature.Agent_Invocation_Count__c) + 1;
        signature.Last_Diagnosed_At__c = System.now();

        Boolean success = diagnosis != null && diagnosis.success == true;
        if (success) {
            signature.Root_Cause__c = diagnosis.rootCause;
            signature.Recommendation__c = diagnosis.recommendation;
            signature.Diagnosis_Status__c = NortConstants.DIAG_DIAGNOSED;
        } else {
            signature.Diagnosis_Status__c = NortConstants.DIAG_FAILED;
        }
        Database.update(signature, true, AccessLevel.SYSTEM_MODE);

        if (success) {
            NortCaseService.route(new List<Error_Signature__c>{ signature });
            transitionRepresentativeEvents(signature.Id, NortConstants.EVENT_CASED);
        } else {
            transitionRepresentativeEvents(signature.Id, NortConstants.EVENT_FAILED);
        }
    }

    private void transitionRepresentativeEvents(Id signatureId, String newStatus) {
        List<Error_Event__c> events = [
            SELECT Id, Status__c FROM Error_Event__c
            WHERE Signature__c = :signatureId AND Status__c = :NortConstants.EVENT_REPRESENTATIVE
            WITH SYSTEM_MODE
        ];
        if (events.isEmpty()) {
            return;
        }
        for (Error_Event__c event : events) {
            event.Status__c = newStatus;
        }
        Database.update(events, false, AccessLevel.SYSTEM_MODE);
    }

    private void chainIfMoreRemain() {
        if (Test.isRunningTest()) {
            return;
        }
        Integer remaining = [
            SELECT COUNT() FROM Error_Signature__c
            WHERE Diagnosis_Status__c = :NortConstants.DIAG_QUEUED
            WITH SYSTEM_MODE
        ];
        if (remaining > 0) {
            System.enqueueJob(new NortDiagnosisQueueable());
        }
    }

    private Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
