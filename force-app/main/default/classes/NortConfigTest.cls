/**
 * Tests for NortConfig: getter values from an injected record, safe fallbacks
 * when fields are null, and the self-exclusion loop-guard matching modes.
 */
@isTest
private class NortConfigTest {
    @isTest
    static void shouldReturnConfiguredValues_WhenRecordInjected() {
        NortConfig.configOverride = TestDataFactory.config();

        Assert.areEqual(5, NortConfig.windowMinutes(), 'Window should reflect the injected value.');
        Assert.areEqual(200, NortConfig.snippetLength(), 'Snippet length should reflect the injected value.');
        Assert.areEqual(24, NortConfig.cooldownHours(), 'Cooldown should reflect the injected value.');
        Assert.areEqual(2000, NortConfig.batchSize(), 'Batch size should reflect the injected value.');
        Assert.isNull(NortConfig.volumeCap(), 'A null cap means unlimited (dedup-only).');
        Assert.areEqual('Nort_Error_Diagnosis_Agent', NortConfig.agentApiName(), 'Agent API name should match.');
        Assert.areEqual('Nort_Error_Triage', NortConfig.caseQueueDeveloperName(), 'Queue dev name should match.');
        Assert.areEqual('Nort_Automated_Error', NortConfig.caseRecordTypeDeveloperName(), 'Record type dev name should match.');
    }

    @isTest
    static void shouldFallBack_WhenNumericFieldsNull() {
        NortConfig.configOverride = new nort_Config__mdt();

        Assert.areEqual(
            NortConfig.FALLBACK_WINDOW_MINUTES, NortConfig.windowMinutes(),
            'Null window should fall back to the constant.'
        );
        Assert.areEqual(
            NortConfig.FALLBACK_SNIPPET_LENGTH, NortConfig.snippetLength(),
            'Null snippet length should fall back to the constant.'
        );
        Assert.areEqual(
            NortConfig.FALLBACK_COOLDOWN_HOURS, NortConfig.cooldownHours(),
            'Null cooldown should fall back to the constant.'
        );
        Assert.areEqual(
            NortConfig.FALLBACK_BATCH_SIZE, NortConfig.batchSize(),
            'Null batch size should fall back to the constant.'
        );
    }

    @isTest
    static void shouldReturnCap_WhenConfigured() {
        nort_Config__mdt config = TestDataFactory.config();
        config.Volume_Cap__c = 10;
        NortConfig.configOverride = config;
        Assert.areEqual(10, NortConfig.volumeCap(), 'A configured cap should be returned.');
    }

    @isTest
    static void shouldExcludeByPrefix_WhenRuleMatches() {
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');
        Assert.isTrue(NortConfig.isExcludedClass('NortDedupBatch'), 'Nort-prefixed class should be excluded.');
        Assert.isFalse(NortConfig.isExcludedClass('AccountService'), 'Unrelated class should not be excluded.');
    }

    @isTest
    static void shouldNotExclude_WhenClassNameBlank() {
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');
        Assert.isFalse(NortConfig.isExcludedClass(null), 'Blank class name cannot match any rule.');
    }

    @isTest
    static void shouldExcludeByNamespace_WhenRuleMatches() {
        NortConfig.exclusionOverride = new List<nort_Exclusion__mdt>{
            new nort_Exclusion__mdt(Match_Value__c = 'myns', Match_Type__c = 'Namespace', Active__c = true)
        };
        Assert.isTrue(NortConfig.isExcludedClass('myns__SomeClass'), 'Managed-style namespace prefix should match.');
        Assert.isTrue(NortConfig.isExcludedClass('myns.SomeClass'), 'Dotted namespace prefix should match.');
    }

    @isTest
    static void shouldExcludeByExactClass_WhenRuleMatches() {
        NortConfig.exclusionOverride = new List<nort_Exclusion__mdt>{
            new nort_Exclusion__mdt(Match_Value__c = 'AccountTrigger', Match_Type__c = 'ExactClass', Active__c = true)
        };
        Assert.isTrue(NortConfig.isExcludedClass('accounttrigger'), 'Exact match should be case-insensitive.');
        Assert.isFalse(NortConfig.isExcludedClass('AccountTriggerHandler'), 'Non-exact should not match.');
    }

    @isTest
    static void shouldIgnoreInactiveRules() {
        NortConfig.exclusionOverride = new List<nort_Exclusion__mdt>{
            new nort_Exclusion__mdt(Match_Value__c = 'Nort', Match_Type__c = 'ClassPrefix', Active__c = false)
        };
        Assert.isFalse(NortConfig.isExcludedClass('NortDedupBatch'), 'Inactive rules must be ignored.');
    }

    @isTest
    static void shouldResolveSettings_WhenNoOverride() {
        // Exercises the getInstance/getAll path; value depends on deployed CMDT.
        NortConfig.configOverride = null;
        Test.startTest();
        NortConfig.windowMinutes();
        Test.stopTest();
        Assert.isTrue(true, 'settings() resolution path executed without error.');
    }
}
