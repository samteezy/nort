/**
 * Tests for NortDedupBatch — the credit-discipline spine. The headline test
 * proves a storm of events collapses to one signature per unique fingerprint
 * BEFORE any agent spend, and that each signature is scheduled for diagnosis at
 * most once. Combined with NortDiagnosisQueueableTest (exactly one invocation
 * per signature), this demonstrates total spend = unique signatures, not events.
 */
@isTest
private class NortDedupBatchTest {
    private static final String FP_A = 'a'.repeat(64);
    private static final String FP_B = 'b'.repeat(64);
    private static final String FP_C = 'c'.repeat(64);

    @TestSetup
    static void setup() {
        List<Error_Event__c> events = new List<Error_Event__c>();
        events.addAll(TestDataFactory.buildParsedEvents(FP_A, 'AccountService', 298));
        events.addAll(TestDataFactory.buildParsedEvents(FP_B, 'ContactService', 1));
        events.addAll(TestDataFactory.buildParsedEvents(FP_C, 'LeadService', 1));
        insert events;
    }

    @isTest
    static void shouldCollapseStormToUniqueSignatures_BeforeAnySpend() {
        NortConfig.configOverride = TestDataFactory.config();
        NortAgentInvoker.setClient(new MockAgentClient());

        Test.startTest();
        Database.executeBatch(new NortDedupBatch(), 2000);
        Test.stopTest();

        List<Error_Signature__c> signatures = [
            SELECT Fingerprint_Hash__c, Occurrence_Count__c, Diagnosis_Status__c, Agent_Invocation_Count__c
            FROM Error_Signature__c
        ];
        Assert.areEqual(3, signatures.size(), '300 events across 3 fingerprints must collapse to 3 signatures.');

        Map<String, Error_Signature__c> byFingerprint = new Map<String, Error_Signature__c>();
        for (Error_Signature__c signature : signatures) {
            byFingerprint.put(signature.Fingerprint_Hash__c, signature);
            Assert.isTrue(
                signature.Agent_Invocation_Count__c <= 1,
                'A signature must be scheduled for diagnosis at most once (no per-event spend).'
            );
        }
        Assert.areEqual(298, byFingerprint.get(FP_A).Occurrence_Count__c, 'Occurrences should accumulate on the signature.');
        Assert.areEqual(1, byFingerprint.get(FP_B).Occurrence_Count__c, 'Single-occurrence fingerprint count should be 1.');
    }

    @isTest
    static void shouldMarkSignaturesQueued_WhenNewAndEligible() {
        NortConfig.configOverride = TestDataFactory.config();

        Test.startTest();
        // Run the batch only; the finish-dispatched queueable does not execute in-test,
        // so signatures remain in the Queued state set by the dedup gate.
        Database.executeBatch(new NortDedupBatch(), 2000);
        Test.stopTest();

        Integer queued = [SELECT COUNT() FROM Error_Signature__c WHERE Diagnosis_Status__c = 'Queued'];
        Assert.areEqual(3, queued, 'All three new signatures should be Queued for diagnosis.');
    }

    @isTest
    static void shouldMarkOneRepresentativePerFingerprint() {
        NortConfig.configOverride = TestDataFactory.config();

        Test.startTest();
        Database.executeBatch(new NortDedupBatch(), 2000);
        Test.stopTest();

        Integer representatives = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Representative'];
        Integer duplicates = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Duplicate'];
        Assert.areEqual(3, representatives, 'Exactly one representative event per unique fingerprint.');
        Assert.areEqual(297, duplicates, 'The remaining events should be marked Duplicate.');
    }

    @isTest
    static void shouldRespectVolumeCap_WhenConfigured() {
        nort_Config__mdt config = TestDataFactory.config();
        config.Volume_Cap__c = 2;
        NortConfig.configOverride = config;

        Test.startTest();
        Database.executeBatch(new NortDedupBatch(), 2000);
        Test.stopTest();

        Integer queued = [SELECT COUNT() FROM Error_Signature__c WHERE Diagnosis_Status__c = 'Queued'];
        Integer deferred = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Deferred'];
        Assert.areEqual(2, queued, 'Only the capped number of signatures should be Queued.');
        Assert.isTrue(deferred > 0, 'Over-cap fingerprints should defer their events for a later window.');
    }

    /** Minimal mock so any dispatched diagnosis does not hit a real agent. */
    private class MockAgentClient implements NortAgentInvoker.Client {
        public NortAgentInvoker.DiagnosisResult diagnose(NortAgentInvoker.DiagnosisRequest request) {
            NortAgentInvoker.DiagnosisResult result = new NortAgentInvoker.DiagnosisResult();
            result.success = true;
            result.rootCause = 'mock';
            result.recommendation = 'mock';
            return result;
        }
    }
}
