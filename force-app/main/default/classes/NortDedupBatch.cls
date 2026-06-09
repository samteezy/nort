/**
 * The dedup/throttle gate — the spine of the credit-discipline design. Scans
 * newly staged Error_Event__c rows, groups them by fingerprint, upserts the
 * owning Error_Signature__c (resolving duplicates at the database via the unique
 * external id), increments occurrence/seen accounting, and marks eligible
 * signatures Queued for diagnosis.
 *
 * It fully resolves dedup BEFORE any agent spend: this batch never invokes the
 * agent. finish() kicks off a single self-chaining diagnosis Queueable that
 * drains the Queued signatures one at a time, so a storm of thousands of events
 * collapses to one agent invocation per unique fingerprint.
 *
 * Volume cap (off by default = dedup-only) bounds how many new signatures are
 * Queued per run; the remainder are Deferred and re-evaluated next window.
 */
public with sharing class NortDedupBatch implements Database.Batchable<SObject>, Database.Stateful {
    @TestVisible
    private Integer queuedThisRun = 0;
    @TestVisible
    private Boolean shouldDispatch = false;

    /**
     * Selects events awaiting dedup: freshly parsed rows plus any deferred by a
     * prior window's volume cap.
     *
     * @param batchContext The batch context.
     * @return A QueryLocator over eligible Error_Event__c rows.
     */
    public Database.QueryLocator start(Database.BatchableContext batchContext) {
        Set<String> statuses = new Set<String>{
            NortConstants.EVENT_PARSED,
            NortConstants.EVENT_DEFERRED
        };
        return Database.getQueryLocator([
            SELECT Id, Fingerprint_Hash__c, Source__c, Apex_Class__c, Apex_Method__c,
                   Parsed_Exception_Type__c, Flow_API_Name__c, Faulting_Element__c,
                   Message_Snippet__c, Raw_Payload__c, Parse_Degraded__c, Received_At__c
            FROM Error_Event__c
            WHERE Status__c IN :statuses AND Fingerprint_Hash__c != null
            WITH SYSTEM_MODE
            ORDER BY Received_At__c ASC
        ]);
    }

    /**
     * Dedups one scope: groups by fingerprint, upserts signatures, links events,
     * and marks eligible signatures Queued (respecting the optional volume cap).
     *
     * @param batchContext The batch context.
     * @param scope The events in this chunk.
     */
    public void execute(Database.BatchableContext batchContext, List<Error_Event__c> scope) {
        Map<String, List<Error_Event__c>> eventsByFingerprint = groupByFingerprint(scope);
        Map<String, Error_Signature__c> signaturesByFingerprint = loadSignatures(eventsByFingerprint.keySet());

        Datetime now = System.now();
        Datetime cooldownThreshold = now.addHours(-NortConfig.cooldownHours());
        Integer cap = NortConfig.volumeCap();

        List<Error_Signature__c> signaturesToUpsert = new List<Error_Signature__c>();
        Set<String> queuedFingerprints = new Set<String>();
        Set<String> deferredFingerprints = new Set<String>();

        for (String fingerprint : eventsByFingerprint.keySet()) {
            List<Error_Event__c> groupedEvents = eventsByFingerprint.get(fingerprint);
            Error_Signature__c signature = signaturesByFingerprint.get(fingerprint);
            Boolean isNew = signature == null;
            if (isNew) {
                signature = newSignature(fingerprint, groupedEvents[0], now);
            }
            signature.Last_Seen__c = now;
            signature.Occurrence_Count__c = zeroIfNull(signature.Occurrence_Count__c) + groupedEvents.size();

            if (isEligible(signature, cooldownThreshold) && withinCap(cap)) {
                signature.Diagnosis_Status__c = NortConstants.DIAG_QUEUED;
                queuedFingerprints.add(fingerprint);
                queuedThisRun++;
                shouldDispatch = true;
            } else if (isEligible(signature, cooldownThreshold)) {
                // Eligible but over the cap this window: defer to a later window.
                deferredFingerprints.add(fingerprint);
            }
            signaturesToUpsert.add(signature);
        }

        Database.upsert(signaturesToUpsert, Error_Signature__c.Fingerprint_Hash__c, false, AccessLevel.SYSTEM_MODE);

        Map<String, Id> signatureIdByFingerprint = mapSignatureIds(eventsByFingerprint.keySet());
        List<Error_Event__c> eventsToUpdate = linkEvents(
            eventsByFingerprint, signatureIdByFingerprint, queuedFingerprints, deferredFingerprints
        );
        Database.update(eventsToUpdate, false, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Dispatches diagnosis once dedup is fully resolved, if any signature was Queued.
     *
     * @param batchContext The batch context.
     */
    public void finish(Database.BatchableContext batchContext) {
        if (shouldDispatch) {
            NortDiagnosisQueueable.dispatch();
        }
    }

    private Map<String, List<Error_Event__c>> groupByFingerprint(List<Error_Event__c> scope) {
        Map<String, List<Error_Event__c>> grouped = new Map<String, List<Error_Event__c>>();
        for (Error_Event__c event : scope) {
            if (!grouped.containsKey(event.Fingerprint_Hash__c)) {
                grouped.put(event.Fingerprint_Hash__c, new List<Error_Event__c>());
            }
            grouped.get(event.Fingerprint_Hash__c).add(event);
        }
        return grouped;
    }

    private Map<String, Error_Signature__c> loadSignatures(Set<String> fingerprints) {
        Map<String, Error_Signature__c> byFingerprint = new Map<String, Error_Signature__c>();
        for (Error_Signature__c signature : [
            SELECT Id, Fingerprint_Hash__c, Occurrence_Count__c, Diagnosis_Status__c,
                   Last_Diagnosed_At__c, First_Seen__c
            FROM Error_Signature__c
            WHERE Fingerprint_Hash__c IN :fingerprints
            WITH SYSTEM_MODE
        ]) {
            byFingerprint.put(signature.Fingerprint_Hash__c, signature);
        }
        return byFingerprint;
    }

    private Error_Signature__c newSignature(String fingerprint, Error_Event__c representative, Datetime now) {
        return new Error_Signature__c(
            Fingerprint_Hash__c = fingerprint,
            Source__c = representative.Source__c,
            Apex_Class__c = representative.Apex_Class__c,
            Apex_Method__c = representative.Apex_Method__c,
            Exception_Type__c = representative.Parsed_Exception_Type__c,
            Flow_API_Name__c = representative.Flow_API_Name__c,
            Faulting_Element__c = representative.Faulting_Element__c,
            Message_Template__c = representative.Message_Snippet__c,
            Raw_Sample__c = representative.Raw_Payload__c,
            Parse_Degraded__c = representative.Parse_Degraded__c == true,
            First_Seen__c = now,
            Occurrence_Count__c = 0,
            Agent_Invocation_Count__c = 0,
            Diagnosis_Status__c = NortConstants.DIAG_NONE
        );
    }

    /**
     * A signature is eligible for (re)diagnosis when it is not already in flight
     * and either has never been diagnosed or was last diagnosed before the
     * cooldown threshold.
     */
    private Boolean isEligible(Error_Signature__c signature, Datetime cooldownThreshold) {
        String status = signature.Diagnosis_Status__c;
        if (NortConstants.DIAG_QUEUED == status || NortConstants.DIAG_DIAGNOSING == status) {
            return false;
        }
        if (NortConstants.DIAG_NONE == status || signature.Last_Diagnosed_At__c == null) {
            return true;
        }
        return signature.Last_Diagnosed_At__c < cooldownThreshold;
    }

    private Boolean withinCap(Integer cap) {
        return cap == null || queuedThisRun < cap;
    }

    private Map<String, Id> mapSignatureIds(Set<String> fingerprints) {
        Map<String, Id> idByFingerprint = new Map<String, Id>();
        for (Error_Signature__c signature : [
            SELECT Id, Fingerprint_Hash__c
            FROM Error_Signature__c
            WHERE Fingerprint_Hash__c IN :fingerprints
            WITH SYSTEM_MODE
        ]) {
            idByFingerprint.put(signature.Fingerprint_Hash__c, signature.Id);
        }
        return idByFingerprint;
    }

    private List<Error_Event__c> linkEvents(
        Map<String, List<Error_Event__c>> eventsByFingerprint,
        Map<String, Id> signatureIdByFingerprint,
        Set<String> queuedFingerprints,
        Set<String> deferredFingerprints
    ) {
        List<Error_Event__c> toUpdate = new List<Error_Event__c>();
        for (String fingerprint : eventsByFingerprint.keySet()) {
            Id signatureId = signatureIdByFingerprint.get(fingerprint);
            List<Error_Event__c> groupedEvents = eventsByFingerprint.get(fingerprint);
            Boolean isQueued = queuedFingerprints.contains(fingerprint);
            Boolean isDeferred = deferredFingerprints.contains(fingerprint);

            for (Integer i = 0; i < groupedEvents.size(); i++) {
                Error_Event__c event = groupedEvents[i];
                event.Signature__c = signatureId;
                if (isDeferred) {
                    event.Status__c = NortConstants.EVENT_DEFERRED;
                } else if (isQueued && i == 0) {
                    event.Status__c = NortConstants.EVENT_REPRESENTATIVE;
                } else {
                    event.Status__c = NortConstants.EVENT_DUPLICATE;
                }
                toUpdate.add(event);
            }
        }
        return toUpdate;
    }

    private Decimal zeroIfNull(Decimal value) {
        return value == null ? 0 : value;
    }
}
