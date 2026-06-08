/**
 * Source-agnostic ingestion service. Turns raw inbound notifications into staged
 * Error_Event__c records: parse, fingerprint, apply the self-exclusion loop
 * guard, resolve the triggering user (in bulk), and insert.
 *
 * This is the single publish path. The email inbound handler is a thin caller;
 * future feeds (Flow fault path, platform-event logging) publish through the
 * same method, which is why it accepts a list and bulkifies all SOQL/DML.
 */
public with sharing class NortIngestionService {
    private static final Integer SUBJECT_MAX = 255;
    private static final Integer REASON_MAX = 255;
    private static final Integer PAYLOAD_MAX = 131072;

    /** Lightweight, source-agnostic carrier for an inbound notification. */
    public class RawNotification {
        public String subject;
        public String fromAddress;
        public String body;

        public RawNotification(String subject, String fromAddress, String body) {
            this.subject = subject;
            this.fromAddress = fromAddress;
            this.body = body;
        }
    }

    /**
     * Stages a batch of raw notifications as Error_Event__c records.
     *
     * @param notifications The raw notifications to stage.
     * @return The inserted Error_Event__c records (with Ids populated).
     * @example
     * NortIngestionService.publish(new List<RawNotification>{ raw });
     */
    public static List<Error_Event__c> publish(List<RawNotification> notifications) {
        if (notifications == null || notifications.isEmpty()) {
            return new List<Error_Event__c>();
        }

        List<Error_Event__c> events = new List<Error_Event__c>();
        Map<Integer, Id> candidateUserByIndex = new Map<Integer, Id>();

        for (Integer i = 0; i < notifications.size(); i++) {
            RawNotification raw = notifications[i];
            Error_Event__c event = buildEvent(raw);
            NortEmailParser.ParsedError parsed = NortEmailParser.parse(raw?.subject, raw?.body);
            applyParsed(event, parsed);

            Id candidate = toUserId(parsed.triggeringUserId);
            if (candidate != null) {
                candidateUserByIndex.put(i, candidate);
            }
            events.add(event);
        }

        resolveTriggeringUsers(events, candidateUserByIndex);

        // Partial-success insert so one bad row never blocks the rest of a batch.
        Database.insert(events, false, AccessLevel.SYSTEM_MODE);
        return events;
    }

    private static Error_Event__c buildEvent(RawNotification raw) {
        Error_Event__c event = new Error_Event__c(
            Received_At__c = System.now(),
            Status__c = NortConstants.EVENT_RECEIVED,
            Subject__c = truncate(raw?.subject, SUBJECT_MAX),
            From_Address__c = truncate(raw?.fromAddress, SUBJECT_MAX),
            Raw_Payload__c = truncate(raw?.body, PAYLOAD_MAX)
        );
        return event;
    }

    private static void applyParsed(Error_Event__c event, NortEmailParser.ParsedError parsed) {
        event.Source__c = sourceValue(parsed.source);
        event.Parsed_Exception_Type__c = truncate(parsed.exceptionType, SUBJECT_MAX);
        event.Apex_Class__c = truncate(parsed.className, SUBJECT_MAX);
        event.Apex_Method__c = truncate(parsed.methodName, SUBJECT_MAX);
        event.Flow_API_Name__c = truncate(parsed.flowApiName, SUBJECT_MAX);
        event.Faulting_Element__c = truncate(parsed.faultingElement, SUBJECT_MAX);

        if (parsed.parseFailed) {
            event.Status__c = NortConstants.EVENT_PARSE_ERROR;
            event.Status_Reason__c = truncate(parsed.parseError, REASON_MAX);
            return;
        }

        // Self-exclusion loop guard: never ingest nort's own (or configured) classes.
        if (NortConfig.isExcludedClass(event.Apex_Class__c)) {
            event.Status__c = NortConstants.EVENT_EXCLUDED;
            event.Status_Reason__c = truncate(
                'Matched self-exclusion rule for class ' + event.Apex_Class__c, REASON_MAX
            );
            return;
        }

        NortFingerprint.FingerprintResult fingerprint = NortFingerprint.compute(
            toFingerprintInput(parsed), NortConfig.snippetLength()
        );
        event.Fingerprint_Hash__c = fingerprint.hash;
        event.Message_Snippet__c = fingerprint.normalizedSnippet;
        event.Status__c = NortConstants.EVENT_PARSED;
    }

    private static NortFingerprint.FingerprintInput toFingerprintInput(NortEmailParser.ParsedError parsed) {
        NortFingerprint.FingerprintInput input = new NortFingerprint.FingerprintInput();
        input.source = parsed.source;
        input.className = parsed.className;
        input.methodName = parsed.methodName;
        input.exceptionType = parsed.exceptionType;
        input.flowApiName = parsed.flowApiName;
        input.faultingElement = parsed.faultingElement;
        input.rawMessage = parsed.message;
        return input;
    }

    private static void resolveTriggeringUsers(List<Error_Event__c> events, Map<Integer, Id> candidateUserByIndex) {
        if (candidateUserByIndex.isEmpty()) {
            return;
        }
        Set<Id> candidateIds = new Set<Id>(candidateUserByIndex.values());
        Map<Id, User> usersById = new Map<Id, User>(
            [SELECT Id FROM User WHERE Id IN :candidateIds WITH SYSTEM_MODE]
        );
        for (Integer index : candidateUserByIndex.keySet()) {
            Id candidate = candidateUserByIndex.get(index);
            if (usersById.containsKey(candidate)) {
                events[index].Triggering_User__c = candidate;
            }
        }
    }

    private static String sourceValue(String parsedSource) {
        if (NortConstants.SOURCE_FLOW.equalsIgnoreCase(parsedSource)) {
            return NortConstants.SOURCE_FLOW;
        }
        if (NortConstants.SOURCE_APEX.equalsIgnoreCase(parsedSource)) {
            return NortConstants.SOURCE_APEX;
        }
        // Unknown/unrecognized formats default to Apex, the phase-1 wired source.
        return NortConstants.SOURCE_APEX;
    }

    private static Id toUserId(String value) {
        if (String.isBlank(value) || !value.startsWith('005')) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null) {
            return null;
        }
        return value.length() > maxLength ? value.substring(0, maxLength) : value;
    }
}
