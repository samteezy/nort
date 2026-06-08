/**
 * Shared string constants for the nort error remediation loop: source
 * discriminators, Error Event lifecycle states, and Error Signature diagnosis
 * states. Centralized so the picklist API values are declared once and reused
 * across the ingestion, dedup, diagnosis, and case layers.
 */
public with sharing class NortConstants {
    private NortConstants() {
        // Constants holder; never instantiated.
    }

    // Source discriminators (Error_Event__c.Source__c / Error_Signature__c.Source__c).
    public static final String SOURCE_APEX = 'Apex';
    public static final String SOURCE_FLOW = 'Flow';
    public static final String SOURCE_PLATFORM_EVENT = 'PlatformEvent';

    // Error_Event__c.Status__c lifecycle.
    public static final String EVENT_RECEIVED = 'Received';
    public static final String EVENT_PARSED = 'Parsed';
    public static final String EVENT_PARSE_ERROR = 'ParseError';
    public static final String EVENT_EXCLUDED = 'Excluded';
    public static final String EVENT_DUPLICATE = 'Duplicate';
    public static final String EVENT_REPRESENTATIVE = 'Representative';
    public static final String EVENT_DIAGNOSING = 'Diagnosing';
    public static final String EVENT_DIAGNOSED = 'Diagnosed';
    public static final String EVENT_CASED = 'Cased';
    public static final String EVENT_FAILED = 'Failed';
    public static final String EVENT_DEFERRED = 'Deferred';

    // Error_Signature__c.Diagnosis_Status__c lifecycle.
    public static final String DIAG_NONE = 'None';
    public static final String DIAG_QUEUED = 'Queued';
    public static final String DIAG_DIAGNOSING = 'Diagnosing';
    public static final String DIAG_DIAGNOSED = 'Diagnosed';
    public static final String DIAG_FAILED = 'Failed';
}
