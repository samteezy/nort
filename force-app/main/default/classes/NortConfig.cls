/**
 * Centralized, transaction-cached accessor for nort configuration
 * (nort_Config__mdt) and the self-exclusion loop guard (nort_Exclusion__mdt).
 *
 * Custom Metadata is read via getInstance()/getAll() rather than SOQL. Every
 * getter falls back to a sensible default when the Default config record is
 * absent so that runtime and tests never fail on missing configuration.
 */
public with sharing class NortConfig {
    @TestVisible
    private static final String DEFAULT_RECORD = 'Default';

    @TestVisible
    private static final Integer FALLBACK_WINDOW_MINUTES = 5;
    @TestVisible
    private static final Integer FALLBACK_SNIPPET_LENGTH = 200;
    @TestVisible
    private static final Integer FALLBACK_COOLDOWN_HOURS = 24;
    @TestVisible
    private static final Integer FALLBACK_BATCH_SIZE = 200;

    // Tooling / analysis-grounding fallbacks (used when the Default config record is absent).
    @TestVisible
    private static final String FALLBACK_TOOLING_NAMED_CREDENTIAL = 'Nort_Tooling';
    @TestVisible
    private static final Integer FALLBACK_MAX_ANALYSIS_ITEMS = 8;
    @TestVisible
    private static final Integer FALLBACK_MAX_ITEM_CHARS = 6000;
    @TestVisible
    private static final Integer FALLBACK_MAX_TOTAL_CHARS = 24000;

    // Transaction-scoped caches. @TestVisible so tests can inject overrides.
    @TestVisible
    private static nort_Config__mdt configOverride;
    @TestVisible
    private static List<nort_Exclusion__mdt> exclusionOverride;

    private NortConfig() {
        // Utility class; never instantiated.
    }

    /**
     * Returns the active configuration record, preferring a test override, then
     * the Default record, then any available record.
     *
     * @return The configuration record, or null if none exists.
     */
    public static nort_Config__mdt settings() {
        if (configOverride != null) {
            return configOverride;
        }
        nort_Config__mdt record = nort_Config__mdt.getInstance(DEFAULT_RECORD);
        if (record != null) {
            return record;
        }
        List<nort_Config__mdt> all = nort_Config__mdt.getAll().values();
        return all.isEmpty() ? null : all[0];
    }

    /** @return Heartbeat cadence in minutes. */
    public static Integer windowMinutes() {
        return intValue(safeGet()?.Window_Minutes__c, FALLBACK_WINDOW_MINUTES);
    }

    /** @return Leading characters of the normalized message used for fingerprinting. */
    public static Integer snippetLength() {
        return intValue(safeGet()?.Snippet_Length__c, FALLBACK_SNIPPET_LENGTH);
    }

    /** @return Minimum hours between diagnoses of the same signature. */
    public static Integer cooldownHours() {
        return intValue(safeGet()?.Diagnosis_Cooldown_Hours__c, FALLBACK_COOLDOWN_HOURS);
    }

    /** @return Dedup batch scope size. */
    public static Integer batchSize() {
        return intValue(safeGet()?.Batch_Size__c, FALLBACK_BATCH_SIZE);
    }

    /**
     * @return Maximum new signatures diagnosed per window, or null for unlimited
     * (the configured dedup-only behavior).
     */
    public static Integer volumeCap() {
        Decimal cap = safeGet()?.Volume_Cap__c;
        return cap == null ? null : Integer.valueOf(cap);
    }

    /** @return API name of the diagnosis agent. */
    public static String agentApiName() {
        return safeGet()?.Agent_API_Name__c;
    }

    /** @return Developer name of the queue that owns auto-created cases. */
    public static String caseQueueDeveloperName() {
        return safeGet()?.Case_Queue_DeveloperName__c;
    }

    /** @return Developer name of the dedicated automated-error Case record type. */
    public static String caseRecordTypeDeveloperName() {
        return safeGet()?.Case_RecordType_DeveloperName__c;
    }

    /**
     * @return Developer name of the Named Credential the Tooling API client calls
     * through (callout:&lt;name&gt;/services/data/...). Falls back to 'Nort_Tooling'.
     */
    public static String toolingNamedCredential() {
        String configured = safeGet()?.Tooling_Named_Credential__c;
        return String.isBlank(configured) ? FALLBACK_TOOLING_NAMED_CREDENTIAL : configured;
    }

    /** @return Maximum metadata items resolved per analysis grounding call (primary spend guardrail). */
    public static Integer maxAnalysisItems() {
        return intValue(safeGet()?.Max_Analysis_Items__c, FALLBACK_MAX_ANALYSIS_ITEMS);
    }

    /** @return Maximum characters retained per resolved analysis item. */
    public static Integer maxItemChars() {
        return intValue(safeGet()?.Max_Item_Chars__c, FALLBACK_MAX_ITEM_CHARS);
    }

    /** @return Maximum characters for the assembled analysis grounding context. */
    public static Integer maxTotalChars() {
        return intValue(safeGet()?.Max_Total_Chars__c, FALLBACK_MAX_TOTAL_CHARS);
    }

    /**
     * Determines whether a failing class should be excluded from ingestion.
     * This is the self-exclusion loop guard that stops nort's own errors (and
     * other configured noise) from feeding back into the pipeline.
     *
     * @param className The failing class parsed from the notification.
     * @return true if an active exclusion rule matches.
     */
    public static Boolean isExcludedClass(String className) {
        if (String.isBlank(className)) {
            return false;
        }
        for (nort_Exclusion__mdt rule : exclusions()) {
            if (rule.Active__c != true || String.isBlank(rule.Match_Value__c)) {
                continue;
            }
            if (matches(className.trim(), rule)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean matches(String className, nort_Exclusion__mdt rule) {
        String value = rule.Match_Value__c.trim();
        String matchType = rule.Match_Type__c;
        if ('Namespace'.equalsIgnoreCase(matchType)) {
            return className.startsWithIgnoreCase(value + '.')
                || className.startsWithIgnoreCase(value + '__');
        }
        if ('ExactClass'.equalsIgnoreCase(matchType)) {
            return className.equalsIgnoreCase(value);
        }
        // Default and 'ClassPrefix'
        return className.startsWithIgnoreCase(value);
    }

    private static List<nort_Exclusion__mdt> exclusions() {
        if (exclusionOverride != null) {
            return exclusionOverride;
        }
        return nort_Exclusion__mdt.getAll().values();
    }

    private static nort_Config__mdt safeGet() {
        return settings();
    }

    private static Integer intValue(Decimal value, Integer fallback) {
        return value == null ? fallback : Integer.valueOf(value);
    }
}
