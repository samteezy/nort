/**
 * Tests for NortDiagnosisQueueable: exactly one agent invocation per signature,
 * diagnosis fields persisted, case created, and representative events advanced
 * to Cased on success / Failed on failure. The agent is mocked via dependency
 * injection so no real Agentforce credits are spent.
 */
@isTest
private class NortDiagnosisQueueableTest {
    private static final String FP = 'd'.repeat(64);

    private static Error_Signature__c queuedSignature() {
        Error_Signature__c signature = new Error_Signature__c(
            Fingerprint_Hash__c = FP,
            Source__c = 'Apex',
            Apex_Class__c = 'AccountService',
            Apex_Method__c = 'recalculate',
            Exception_Type__c = 'System.NullPointerException',
            Message_Template__c = 'null deref',
            Occurrence_Count__c = 5,
            Agent_Invocation_Count__c = 0,
            First_Seen__c = System.now(),
            Last_Seen__c = System.now(),
            Diagnosis_Status__c = 'Queued'
        );
        insert signature;
        return signature;
    }

    @isTest
    static void shouldDiagnoseAndCase_WhenAgentSucceeds() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c signature = queuedSignature();
        insert new Error_Event__c(
            Status__c = 'Representative', Source__c = 'Apex', Fingerprint_Hash__c = FP,
            Signature__c = signature.Id, Received_At__c = System.now()
        );
        NortAgentInvoker.setClient(new SuccessClient());
        // Mock Case persistence so the test never performs real Case DML.
        TestDataFactory.CaseGatewayStub gateway = new TestDataFactory.CaseGatewayStub();
        NortCaseService.setGateway(gateway);

        Test.startTest();
        NortDiagnosisQueueable.dispatch();
        Test.stopTest();

        Error_Signature__c result = [
            SELECT Diagnosis_Status__c, Agent_Invocation_Count__c, Root_Cause__c, Recommendation__c
            FROM Error_Signature__c WHERE Id = :signature.Id
        ];
        Assert.areEqual('Diagnosed', result.Diagnosis_Status__c, 'Signature should be Diagnosed on success.');
        Assert.areEqual(1, result.Agent_Invocation_Count__c, 'Exactly one invocation should be charged per signature.');
        Assert.areEqual('Root: null deref', result.Root_Cause__c, 'Root cause should be persisted.');
        Assert.areEqual(1, gateway.insertedCases.size(), 'A case should be created and linked.');

        Integer casedEvents = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Cased'];
        Assert.areEqual(1, casedEvents, 'Representative events should advance to Cased.');
    }

    @isTest
    static void shouldMarkFailed_WhenAgentFails() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c signature = queuedSignature();
        insert new Error_Event__c(
            Status__c = 'Representative', Source__c = 'Apex', Fingerprint_Hash__c = FP,
            Signature__c = signature.Id, Received_At__c = System.now()
        );
        NortAgentInvoker.setClient(new FailureClient());

        Test.startTest();
        NortDiagnosisQueueable.dispatch();
        Test.stopTest();

        Error_Signature__c result = [
            SELECT Diagnosis_Status__c, Agent_Invocation_Count__c, Case__c
            FROM Error_Signature__c WHERE Id = :signature.Id
        ];
        Assert.areEqual('Failed', result.Diagnosis_Status__c, 'Signature should be Failed when the agent fails.');
        Assert.areEqual(1, result.Agent_Invocation_Count__c, 'The failed attempt still counts as one invocation.');
        Assert.isNull(result.Case__c, 'No case should be created on failure.');

        Integer failedEvents = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Failed'];
        Assert.areEqual(1, failedEvents, 'Representative events should be marked Failed.');
    }

    @isTest
    static void shouldNoOp_WhenNoQueuedSignatures() {
        NortConfig.configOverride = TestDataFactory.config();
        NortAgentInvoker.setClient(new SuccessClient());

        Test.startTest();
        NortDiagnosisQueueable.dispatch();
        Test.stopTest();

        Integer signatures = [SELECT COUNT() FROM Error_Signature__c];
        Assert.areEqual(0, signatures, 'With nothing queued, the dispatcher should do nothing.');
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

    private class FailureClient implements NortAgentInvoker.Client {
        public NortAgentInvoker.DiagnosisResult diagnose(NortAgentInvoker.DiagnosisRequest request) {
            NortAgentInvoker.DiagnosisResult result = new NortAgentInvoker.DiagnosisResult();
            result.success = false;
            result.errorMessage = 'agent unavailable';
            return result;
        }
    }
}
