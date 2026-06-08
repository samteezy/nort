/**
 * Tests for NortErrorEmailHandler: the thin inbound handler stages an event via
 * the ingestion service and always reports success.
 */
@isTest
private class NortErrorEmailHandlerTest {
    @isTest
    static void shouldStageEvent_WhenApexEmailReceived() {
        NortConfig.configOverride = TestDataFactory.config();
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Apex exception';
        email.fromAddress = 'noreply@salesforce.com';
        email.plainTextBody = TestDataFactory.apexExceptionEmail(
            UserInfo.getUserId(), 'AccountService', 'recalculate', 'System.NullPointerException', 'null deref'
        );
        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.fromAddress = 'noreply@salesforce.com';

        Test.startTest();
        Messaging.InboundEmailResult result = new NortErrorEmailHandler().handleInboundEmail(email, envelope);
        Test.stopTest();

        Assert.isTrue(result.success, 'The handler should always report success.');
        Assert.areEqual(1, [SELECT COUNT() FROM Error_Event__c], 'One event should be staged.');
    }

    @isTest
    static void shouldFallBackToHtmlBody_WhenNoPlainText() {
        NortConfig.configOverride = TestDataFactory.config();
        NortConfig.exclusionOverride = TestDataFactory.exclusionForPrefix('Nort');

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Apex script unhandled exception';
        email.htmlBody = TestDataFactory.apexExceptionEmail(
            UserInfo.getUserId(), 'AccountService', 'recalculate', 'System.NullPointerException', 'null deref'
        );
        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();

        Test.startTest();
        new NortErrorEmailHandler().handleInboundEmail(email, envelope);
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Error_Event__c], 'HTML body should be used when plain text is absent.');
    }
}
