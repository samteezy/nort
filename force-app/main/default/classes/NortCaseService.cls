/**
 * Maps diagnosed Error Signatures to support cases with the configured hygiene
 * and recurrence rules:
 *   - New fingerprint  -> create a case on the dedicated record type + queue.
 *   - Recurring, case open -> add a comment (increment), do not duplicate.
 *   - Recurrence after close -> create a NEW case linked (ParentId) to the prior.
 *
 * Auto-created cases land on the Nort Automated Error record type and the
 * internal triage queue so they stay out of entitlement/SLA/CSAT metrics.
 *
 * The public API is list-based and bulkified (all SOQL/DML outside loops); the
 * diagnosis Queueable passes one signature at a time.
 */
public with sharing class NortCaseService {
    private static final String CASE_ORIGIN = 'nort';
    private static final String STATUS_NEW = 'New';
    private static final Integer SUBJECT_MAX = 255;

    // Transaction-cached describe/queue lookups.
    private static Id cachedRecordTypeId;
    private static Boolean recordTypeResolved = false;
    private static Id cachedQueueId;
    private static Boolean queueResolved = false;

    private NortCaseService() {
        // Static service; never instantiated.
    }

    /**
     * Persistence seam for Case reads/writes. Isolated behind an interface so
     * tests can inject an in-memory fake and never depend on the target org's
     * Case automation (triggers/flows that fire on Case insert). Mirrors the
     * dependency-injection pattern used by NortAgentInvoker.Client.
     */
    public interface CaseGateway {
        Map<Id, Case> findCasesByIds(Set<Id> caseIds);
        void insertCases(List<Case> cases);
        void insertComments(List<CaseComment> comments);
        // Persists the Case lookup back onto routed signatures. Behind the seam
        // because tests assign synthetic Case Ids, which a real lookup update
        // would reject as an invalid cross-reference.
        void updateSignatures(List<Error_Signature__c> signatures);
    }

    @TestVisible
    private static CaseGateway gatewayOverride;

    /**
     * Injects a CaseGateway (used by tests to avoid real Case DML).
     *
     * @param gateway The gateway implementation to use for this transaction.
     */
    @TestVisible
    public static void setGateway(CaseGateway gateway) {
        gatewayOverride = gateway;
    }

    private static CaseGateway resolveGateway() {
        return gatewayOverride != null ? gatewayOverride : new DmlCaseGateway();
    }

    /**
     * Routes each diagnosed signature to a created or updated case and updates
     * the signature's Case lookup. Signatures must already carry their diagnosis
     * fields (Root_Cause__c, Recommendation__c) and identity fields.
     *
     * @param signatures Diagnosed signatures to map to cases.
     * @example
     * NortCaseService.route(new List<Error_Signature__c>{ signature });
     */
    public static void route(List<Error_Signature__c> signatures) {
        if (signatures == null || signatures.isEmpty()) {
            return;
        }

        Map<Id, Case> existingCasesById = loadExistingCases(signatures);
        Id recordTypeId = resolveRecordTypeId();
        Id queueId = resolveQueueId();

        List<Case> casesToInsert = new List<Case>();
        List<Error_Signature__c> signaturesForNewCase = new List<Error_Signature__c>();
        List<CaseComment> commentsToInsert = new List<CaseComment>();

        for (Error_Signature__c signature : signatures) {
            Case existing = signature.Case__c == null ? null : existingCasesById.get(signature.Case__c);

            if (existing == null) {
                casesToInsert.add(buildCase(signature, recordTypeId, queueId, null));
                signaturesForNewCase.add(signature);
            } else if (!existing.IsClosed) {
                commentsToInsert.add(buildComment(existing.Id, signature));
            } else {
                // Recurrence after close: new case linked to the prior one.
                casesToInsert.add(buildCase(signature, recordTypeId, queueId, existing.Id));
                signaturesForNewCase.add(signature);
            }
        }

        CaseGateway gateway = resolveGateway();
        List<Error_Signature__c> signaturesToUpdate = new List<Error_Signature__c>();
        if (!casesToInsert.isEmpty()) {
            gateway.insertCases(casesToInsert);
            for (Integer i = 0; i < casesToInsert.size(); i++) {
                Error_Signature__c signature = signaturesForNewCase[i];
                signature.Case__c = casesToInsert[i].Id;
                signaturesToUpdate.add(signature);
            }
        }
        if (!commentsToInsert.isEmpty()) {
            gateway.insertComments(commentsToInsert);
        }
        if (!signaturesToUpdate.isEmpty()) {
            gateway.updateSignatures(signaturesToUpdate);
        }
    }

    private static Map<Id, Case> loadExistingCases(List<Error_Signature__c> signatures) {
        Set<Id> caseIds = new Set<Id>();
        for (Error_Signature__c signature : signatures) {
            if (signature.Case__c != null) {
                caseIds.add(signature.Case__c);
            }
        }
        if (caseIds.isEmpty()) {
            return new Map<Id, Case>();
        }
        return resolveGateway().findCasesByIds(caseIds);
    }

    private static Case buildCase(Error_Signature__c signature, Id recordTypeId, Id queueId, Id parentCaseId) {
        Case newCase = new Case(
            Subject = buildSubject(signature),
            Description = buildDescription(signature),
            Status = STATUS_NEW,
            Origin = CASE_ORIGIN
        );
        if (recordTypeId != null) {
            newCase.RecordTypeId = recordTypeId;
        }
        if (queueId != null) {
            newCase.OwnerId = queueId;
        }
        if (parentCaseId != null) {
            newCase.ParentId = parentCaseId;
        }
        return newCase;
    }

    private static CaseComment buildComment(Id caseId, Error_Signature__c signature) {
        return new CaseComment(
            ParentId = caseId,
            IsPublished = false,
            CommentBody = 'Recurring error (' + signature.Fingerprint_Hash__c + '). '
                + 'Total occurrences: ' + signature.Occurrence_Count__c + '.\n\n'
                + 'Root cause: ' + nullToEmpty(signature.Root_Cause__c) + '\n\n'
                + 'Recommendation: ' + nullToEmpty(signature.Recommendation__c)
        );
    }

    private static String buildSubject(Error_Signature__c signature) {
        String descriptor = NortConstants.SOURCE_FLOW.equalsIgnoreCase(signature.Source__c)
            ? 'Flow ' + signature.Flow_API_Name__c
            : signature.Apex_Class__c;
        String subject = '[nort] ' + nullToEmpty(signature.Exception_Type__c) + ' in ' + nullToEmpty(descriptor);
        return subject.length() > SUBJECT_MAX ? subject.substring(0, SUBJECT_MAX) : subject;
    }

    private static String buildDescription(Error_Signature__c signature) {
        return String.join(new List<String>{
            'Auto-created by the nort error remediation loop.',
            'Fingerprint: ' + signature.Fingerprint_Hash__c,
            'Source: ' + nullToEmpty(signature.Source__c),
            'Occurrences: ' + signature.Occurrence_Count__c,
            '',
            'Root cause:',
            nullToEmpty(signature.Root_Cause__c),
            '',
            'Recommendation:',
            nullToEmpty(signature.Recommendation__c)
        }, '\n');
    }

    private static Id resolveRecordTypeId() {
        if (!recordTypeResolved) {
            recordTypeResolved = true;
            String developerName = NortConfig.caseRecordTypeDeveloperName();
            if (String.isNotBlank(developerName)) {
                Schema.RecordTypeInfo info = Case.SObjectType
                    .getDescribe(SObjectDescribeOptions.DEFERRED)
                    .getRecordTypeInfosByDeveloperName()
                    .get(developerName);
                cachedRecordTypeId = info == null ? null : info.getRecordTypeId();
            }
        }
        return cachedRecordTypeId;
    }

    private static Id resolveQueueId() {
        if (!queueResolved) {
            queueResolved = true;
            String developerName = NortConfig.caseQueueDeveloperName();
            if (String.isNotBlank(developerName)) {
                List<Group> queues = [
                    SELECT Id FROM Group
                    WHERE Type = 'Queue' AND DeveloperName = :developerName
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                cachedQueueId = queues.isEmpty() ? null : queues[0].Id;
            }
        }
        return cachedQueueId;
    }

    private static String nullToEmpty(String value) {
        return value == null ? '' : value;
    }

    /**
     * Default gateway: real SOQL/DML in system mode. The single place that
     * touches the Case object, so any org-side Case automation only runs here
     * (never in tests, which inject a fake).
     */
    private class DmlCaseGateway implements CaseGateway {
        public Map<Id, Case> findCasesByIds(Set<Id> caseIds) {
            return new Map<Id, Case>([
                SELECT Id, IsClosed, CaseNumber FROM Case WHERE Id IN :caseIds WITH SYSTEM_MODE
            ]);
        }

        public void insertCases(List<Case> cases) {
            Database.insert(cases, true, AccessLevel.SYSTEM_MODE);
        }

        public void insertComments(List<CaseComment> comments) {
            Database.insert(comments, false, AccessLevel.SYSTEM_MODE);
        }

        public void updateSignatures(List<Error_Signature__c> signatures) {
            Database.update(signatures, false, AccessLevel.SYSTEM_MODE);
        }
    }
}
