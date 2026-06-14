/**
 * Tests for NortSignatureReprocessHandler: the Force_Reprocess__c action checkbox
 * requeues a signature, resets itself on save, and triggers an immediate agent
 * re-diagnosis — overriding the cooldown — while leaving untouched rows alone.
 * The agent is mocked via dependency injection so no real Agentforce credits are
 * spent, and Case persistence is stubbed.
 */
@isTest
private class NortSignatureReprocessHandlerTest {
    private static final String FP = 'e'.repeat(64);
    private static final String FP2 = 'f'.repeat(64);

    private static Error_Signature__c diagnosedSignature(String fingerprint) {
        Error_Signature__c signature = new Error_Signature__c(
            Fingerprint_Hash__c = fingerprint,
            Source__c = 'Apex',
            Apex_Class__c = 'AccountService',
            Apex_Method__c = 'recalculate',
            Exception_Type__c = 'System.NullPointerException',
            Message_Template__c = 'null deref',
            Occurrence_Count__c = 5,
            Agent_Invocation_Count__c = 1,
            First_Seen__c = System.now(),
            Last_Seen__c = System.now(),
            Last_Diagnosed_At__c = System.now(),
            Root_Cause__c = 'Stale root cause',
            Recommendation__c = 'Stale recommendation',
            Diagnosis_Status__c = 'Diagnosed'
        );
        insert signature;
        return signature;
    }

    @isTest
    static void shouldRequeueResetAndRediagnose_WhenForceChecked() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c signature = diagnosedSignature(FP);
        insert new Error_Event__c(
            Status__c = 'Representative', Source__c = 'Apex', Fingerprint_Hash__c = FP,
            Signature__c = signature.Id, Received_At__c = System.now()
        );
        NortAgentInvoker.setClient(new SuccessClient());
        NortCaseService.setGateway(new TestDataFactory.CaseGatewayStub());

        Test.startTest();
        signature.Force_Reprocess__c = true;
        update signature;

        // Synchronous handler effect, before the queued job runs at stopTest.
        Error_Signature__c afterSave = [
            SELECT Diagnosis_Status__c, Force_Reprocess__c
            FROM Error_Signature__c WHERE Id = :signature.Id
        ];
        Assert.areEqual('Queued', afterSave.Diagnosis_Status__c, 'Forcing should requeue the signature.');
        Assert.areEqual(false, afterSave.Force_Reprocess__c, 'The action checkbox should reset itself on save.');
        Test.stopTest();

        // Async diagnosis chain has now run.
        Error_Signature__c result = [
            SELECT Diagnosis_Status__c, Agent_Invocation_Count__c, Root_Cause__c
            FROM Error_Signature__c WHERE Id = :signature.Id
        ];
        Assert.areEqual('Diagnosed', result.Diagnosis_Status__c, 'Re-diagnosis should complete and mark Diagnosed.');
        Assert.areEqual(2, result.Agent_Invocation_Count__c, 'The forced re-run charges one additional invocation.');
        Assert.areEqual('Root: null deref', result.Root_Cause__c, 'Fresh diagnosis should overwrite the stale root cause.');
    }

    @isTest
    static void shouldDoNothing_WhenForceNotChecked() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c signature = diagnosedSignature(FP);
        NortAgentInvoker.setClient(new SuccessClient());
        NortCaseService.setGateway(new TestDataFactory.CaseGatewayStub());

        Test.startTest();
        // An unrelated edit that leaves Force_Reprocess__c false must not requeue.
        signature.Occurrence_Count__c = 6;
        update signature;
        Test.stopTest();

        Error_Signature__c result = [
            SELECT Diagnosis_Status__c, Agent_Invocation_Count__c
            FROM Error_Signature__c WHERE Id = :signature.Id
        ];
        Assert.areEqual('Diagnosed', result.Diagnosis_Status__c, 'A non-forcing update must not change diagnosis status.');
        Assert.areEqual(1, result.Agent_Invocation_Count__c, 'A non-forcing update must not charge an invocation.');
    }

    @isTest
    static void shouldRequeueAll_WhenForcedInBulk() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c first = diagnosedSignature(FP);
        Error_Signature__c second = diagnosedSignature(FP2);
        NortAgentInvoker.setClient(new SuccessClient());
        NortCaseService.setGateway(new TestDataFactory.CaseGatewayStub());

        Test.startTest();
        first.Force_Reprocess__c = true;
        second.Force_Reprocess__c = true;
        update new List<Error_Signature__c>{ first, second };

        // Assert the handler's deterministic synchronous effect: every forced row is
        // requeued and reset. (One dispatch drains them serially; in a test only the
        // first drains because the queueable suppresses self-chaining under
        // Test.isRunningTest — draining itself is covered by NortDiagnosisQueueableTest.)
        Map<Id, Error_Signature__c> byId = new Map<Id, Error_Signature__c>([
            SELECT Force_Reprocess__c, Diagnosis_Status__c
            FROM Error_Signature__c WHERE Id IN (:first.Id, :second.Id)
        ]);
        for (Error_Signature__c row : byId.values()) {
            Assert.areEqual('Queued', row.Diagnosis_Status__c, 'Every forced row should be requeued.');
            Assert.areEqual(false, row.Force_Reprocess__c, 'Every forced checkbox should reset itself.');
        }
        Test.stopTest();
    }

    private class SuccessClient implements NortAgentInvoker.Client {
        public NortAgentInvoker.DiagnosisResult diagnose(NortAgentInvoker.DiagnosisRequest request) {
            NortAgentInvoker.DiagnosisResult result = new NortAgentInvoker.DiagnosisResult();
            result.success = true;
            result.rootCause = 'Root: ' + request.messageTemplate;
            result.recommendation = 'Add a null check.';
            return result;
        }
    }
}
