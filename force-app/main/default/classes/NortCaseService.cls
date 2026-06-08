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

        List<Error_Signature__c> signaturesToUpdate = new List<Error_Signature__c>();
        if (!casesToInsert.isEmpty()) {
            Database.insert(casesToInsert, true, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < casesToInsert.size(); i++) {
                Error_Signature__c signature = signaturesForNewCase[i];
                signature.Case__c = casesToInsert[i].Id;
                signaturesToUpdate.add(signature);
            }
        }
        if (!commentsToInsert.isEmpty()) {
            Database.insert(commentsToInsert, false, AccessLevel.SYSTEM_MODE);
        }
        if (!signaturesToUpdate.isEmpty()) {
            Database.update(signaturesToUpdate, false, AccessLevel.SYSTEM_MODE);
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
        return new Map<Id, Case>([
            SELECT Id, IsClosed, CaseNumber FROM Case WHERE Id IN :caseIds WITH SYSTEM_MODE
        ]);
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
}
