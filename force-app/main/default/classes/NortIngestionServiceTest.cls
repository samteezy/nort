/**
 * Tests for NortIngestionService.publish: staging, fingerprinting, the
 * self-exclusion loop guard, parse-error handling, and bulk triggering-user
 * resolution.
 */
@isTest
private class NortIngestionServiceTest {
    @isTest
    static void shouldStageParsedEvent_WhenApexEmail() {
        NortConfig.configOverride = TestDataFactory.config();
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');
        String body = TestDataFactory.apexExceptionEmail(
            UserInfo.getUserId(), 'AccountService', 'recalculate', 'System.NullPointerException', 'null deref at row 5'
        );

        Test.startTest();
        List<Error_Event__c> events = NortIngestionService.publish(
            new List<NortIngestionService.RawNotification>{
                new NortIngestionService.RawNotification('Apex exception', 'noreply@salesforce.com', body)
            }
        );
        Test.stopTest();

        Error_Event__c staged = [
            SELECT Status__c, Fingerprint_Hash__c, Apex_Class__c, Triggering_User__c, Source__c
            FROM Error_Event__c WHERE Id = :events[0].Id
        ];
        Assert.areEqual('Parsed', staged.Status__c, 'A parseable Apex email should be staged as Parsed.');
        Assert.isNotNull(staged.Fingerprint_Hash__c, 'Parsed events must carry a fingerprint.');
        Assert.areEqual('AccountService', staged.Apex_Class__c, 'Class should be captured.');
        Assert.areEqual(UserInfo.getUserId(), staged.Triggering_User__c, 'Existing triggering user should be resolved.');
    }

    @isTest
    static void shouldExcludeOwnClasses_WhenExclusionMatches() {
        NortConfig.configOverride = TestDataFactory.config();
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');
        String body = TestDataFactory.apexExceptionEmail(
            UserInfo.getUserId(), 'NortDedupBatch', 'execute', 'System.QueryException', 'boom'
        );

        Test.startTest();
        List<Error_Event__c> events = NortIngestionService.publish(
            new List<NortIngestionService.RawNotification>{
                new NortIngestionService.RawNotification('Apex exception', 'noreply@salesforce.com', body)
            }
        );
        Test.stopTest();

        Error_Event__c staged = [SELECT Status__c, Fingerprint_Hash__c FROM Error_Event__c WHERE Id = :events[0].Id];
        Assert.areEqual('Excluded', staged.Status__c, 'nort own classes must be excluded (loop guard).');
        Assert.isNull(staged.Fingerprint_Hash__c, 'Excluded events must not be fingerprinted.');
    }

    @isTest
    static void shouldStageParseError_WhenUnrecognized() {
        NortConfig.configOverride = TestDataFactory.config();

        Test.startTest();
        List<Error_Event__c> events = NortIngestionService.publish(
            new List<NortIngestionService.RawNotification>{
                new NortIngestionService.RawNotification('Newsletter', 'marketing@x.com', 'nothing useful here')
            }
        );
        Test.stopTest();

        Error_Event__c staged = [SELECT Status__c, Status_Reason__c FROM Error_Event__c WHERE Id = :events[0].Id];
        Assert.areEqual('ParseError', staged.Status__c, 'Unrecognized content should stage as ParseError, not be lost.');
        Assert.isNotNull(staged.Status_Reason__c, 'A parse error reason should be recorded.');
    }

    @isTest
    static void shouldReturnEmpty_WhenNoNotifications() {
        Test.startTest();
        List<Error_Event__c> events = NortIngestionService.publish(null);
        Test.stopTest();
        Assert.areEqual(0, events.size(), 'Null input should yield no events.');
    }

    @isTest
    static void shouldStageInBulk_WhenManyNotifications() {
        NortConfig.configOverride = TestDataFactory.config();
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');
        List<NortIngestionService.RawNotification> raws = new List<NortIngestionService.RawNotification>();
        for (Integer i = 0; i < 251; i++) {
            String body = TestDataFactory.apexExceptionEmail(
                UserInfo.getUserId(), 'AccountService', 'recalculate', 'System.NullPointerException', 'row ' + i
            );
            raws.add(new NortIngestionService.RawNotification('Apex exception', 'noreply@salesforce.com', body));
        }

        Test.startTest();
        NortIngestionService.publish(raws);
        Test.stopTest();

        Integer parsed = [SELECT COUNT() FROM Error_Event__c WHERE Status__c = 'Parsed'];
        Assert.areEqual(251, parsed, 'All 251 notifications should be staged as Parsed.');
    }
}
