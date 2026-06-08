/**
 * Tests for NortCaseService recurrence rules: new fingerprint creates a case,
 * recurrence on an open case adds a comment (no duplicate), and recurrence after
 * close creates a new case linked to the prior one.
 */
@isTest
private class NortCaseServiceTest {
    private static Error_Signature__c signature(Id caseId) {
        Error_Signature__c sig = new Error_Signature__c(
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
        insert sig;
        return sig;
    }

    @isTest
    static void shouldCreateCase_WhenNoExistingCase() {
        NortConfig.configOverride = TestDataFactory.config();
        Error_Signature__c sig = signature(null);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Error_Signature__c updated = [SELECT Case__c FROM Error_Signature__c WHERE Id = :sig.Id];
        Assert.isNotNull(updated.Case__c, 'A new case should be created and linked.');
        Case created = [SELECT Subject, Description FROM Case WHERE Id = :updated.Case__c];
        Assert.isTrue(created.Subject.startsWith('[nort]'), 'Subject should carry the nort prefix.');
        Assert.isTrue(created.Description.contains('Null dereference'), 'Description should carry the root cause.');
    }

    @isTest
    static void shouldComment_WhenCaseOpen() {
        NortConfig.configOverride = TestDataFactory.config();
        Case existing = new Case(Subject = 'existing', Status = 'New', Origin = 'nort');
        insert existing;
        Error_Signature__c sig = signature(existing.Id);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Case], 'No new case should be created for an open recurrence.');
        Assert.areEqual(
            1, [SELECT COUNT() FROM CaseComment WHERE ParentId = :existing.Id],
            'A comment should be added to the open case.'
        );
    }

    @isTest
    static void shouldCreateLinkedCase_WhenPriorCaseClosed() {
        NortConfig.configOverride = TestDataFactory.config();
        Case existing = new Case(Subject = 'existing', Status = 'New', Origin = 'nort');
        insert existing;
        existing.Status = 'Closed';
        update existing;
        Error_Signature__c sig = signature(existing.Id);

        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>{ sig });
        Test.stopTest();

        Error_Signature__c updated = [SELECT Case__c FROM Error_Signature__c WHERE Id = :sig.Id];
        Assert.areNotEqual(existing.Id, updated.Case__c, 'A new case should be created after close.');
        Case newCase = [SELECT ParentId FROM Case WHERE Id = :updated.Case__c];
        Assert.areEqual(existing.Id, newCase.ParentId, 'The new case should link back to the prior one.');
    }

    @isTest
    static void shouldNoOp_WhenEmptyList() {
        Test.startTest();
        NortCaseService.route(new List<Error_Signature__c>());
        Test.stopTest();
        Assert.areEqual(0, [SELECT COUNT() FROM Case], 'No cases should be created for an empty list.');
    }
}
