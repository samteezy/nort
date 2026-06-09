/**
 * Tests for NortCaseService recurrence rules: new fingerprint creates a case,
 * recurrence on an open case adds a comment (no duplicate), and recurrence after
 * close creates a new case linked to the prior one.
 *
 * Case persistence is mocked via TestDataFactory.CaseGatewayStub so these tests
 * never perform real Case DML — they verify nort's routing logic independent of
 * whatever Case automation (triggers/flows) the deployment org carries.
 */
@isTest
private class NortCaseServiceTest {
    private static Error_Signature__c buildSignature(Id caseId) {
        // Built, not inserted: route() works on the in-memory record, and a real
        // insert carrying a synthetic Case__c lookup would fail referential checks.
        return new Error_Signature__c(
            Fingerprint_Hash__c = 'e'.repeat(64),
            Source__c = 'Apex',
            Apex_Class__c = 'AccountService',
            Exception_Type__c = 'System.NullPointerException',
            Occurrence_Count__c = 3,
            Root_Cause__c = 'Null dereference in recalculate().',
            Recommendation__c = 'Guard against null before access.',
            First_Seen__c = System.now(),
            Diagnosis_Status__c = 'Diagnosed',
            Case__c = caseId
        );
    }

    @isTest
    static void shouldCreateCase_WhenNoExistingCase() {
        NortConfig.configOverride = TestDataFactory.config();
        TestDataFactory.CaseGatewayStub gateway = new TestDataFactory.CaseGatewayStub();
        NortCaseService.setGateway(gateway);
        Error_Signature__c sig = buildSignature(null);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Assert.areEqual(1, gateway.insertedCases.size(), 'A new case should be created.');
        Case created = gateway.insertedCases[0];
        Assert.isTrue(created.Subject.startsWith('[nort]'), 'Subject should carry the nort prefix.');
        Assert.isTrue(created.Description.contains('Null dereference'), 'Description should carry the root cause.');
        Assert.isNotNull(sig.Case__c, 'The signature should be linked to the new case.');
        Assert.areEqual(1, gateway.updatedSignatures.size(), 'The linked signature should be persisted.');
    }

    @isTest
    static void shouldComment_WhenCaseOpen() {
        NortConfig.configOverride = TestDataFactory.config();
        TestDataFactory.CaseGatewayStub gateway = new TestDataFactory.CaseGatewayStub();
        Id existingId = gateway.seedExisting(false);
        NortCaseService.setGateway(gateway);
        Error_Signature__c sig = buildSignature(existingId);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Assert.areEqual(0, gateway.insertedCases.size(), 'No new case should be created for an open recurrence.');
        Assert.areEqual(1, gateway.insertedComments.size(), 'A comment should be added to the open case.');
        Assert.areEqual(existingId, gateway.insertedComments[0].ParentId, 'The comment should target the open case.');
    }

    @isTest
    static void shouldCreateLinkedCase_WhenPriorCaseClosed() {
        NortConfig.configOverride = TestDataFactory.config();
        TestDataFactory.CaseGatewayStub gateway = new TestDataFactory.CaseGatewayStub();
        Id existingId = gateway.seedExisting(true);
        NortCaseService.setGateway(gateway);
        Error_Signature__c sig = buildSignature(existingId);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Assert.areEqual(1, gateway.insertedCases.size(), 'A new case should be created after close.');
        Case linked = gateway.insertedCases[0];
        Assert.areEqual(existingId, linked.ParentId, 'The new case should link back to the prior one.');
        Assert.areNotEqual(existingId, sig.Case__c, 'The signature should point to the new case, not the closed one.');
    }

    @isTest
    static void shouldNoOp_WhenEmptyList() {
        TestDataFactory.CaseGatewayStub gateway = new TestDataFactory.CaseGatewayStub();
        NortCaseService.setGateway(gateway);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>());
        Test.stopTest();

        Assert.areEqual(0, gateway.insertedCases.size(), 'No cases should be created for an empty list.');
    }
}
