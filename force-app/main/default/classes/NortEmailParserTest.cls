/**
 * Tests for NortEmailParser: source detection, Apex stack-frame extraction,
 * Flow metadata extraction, triggering-user parsing, and graceful failure.
 */
@isTest
private class NortEmailParserTest {
    @isTest
    static void shouldParseApexEmail_WhenWellFormed() {
        Id userId = UserInfo.getUserId();
        String body = TestDataFactory.apexExceptionEmail(
            userId, 'AccountService', 'recalculate', 'System.NullPointerException', 'Attempt to de-reference a null object'
        );

        NortEmailParser.ParsedError parsed = NortEmailParser.parse('Apex exception', body);

        Assert.areEqual('Apex', parsed.source, 'Source should be detected as Apex.');
        Assert.isFalse(parsed.parseFailed, 'A well-formed Apex email should parse.');
        Assert.areEqual('System.NullPointerException', parsed.exceptionType, 'Exception type should be extracted.');
        Assert.areEqual('AccountService', parsed.className, 'Class should be the innermost frame class.');
        Assert.areEqual('recalculate', parsed.methodName, 'Method should be the innermost frame method.');
        Assert.areEqual(String.valueOf(userId), parsed.triggeringUserId, 'Triggering user id should be extracted.');
    }

    @isTest
    static void shouldParseFlowEmail_WhenWellFormed() {
        String body = TestDataFactory.flowFaultEmail('My_Flow', 'Update_Records');

        NortEmailParser.ParsedError parsed = NortEmailParser.parse('Flow error', body);

        Assert.areEqual('Flow', parsed.source, 'Source should be detected as Flow.');
        Assert.isFalse(parsed.parseFailed, 'A well-formed Flow email should parse.');
        Assert.areEqual('My_Flow', parsed.flowApiName, 'Flow API name should be extracted.');
        Assert.areEqual('Update_Records', parsed.faultingElement, 'Faulting element should be extracted.');
    }

    @isTest
    static void shouldParseRealFlowEmailFormat_WithBoldMarkersAndErrorElement() {
        // Mirrors the actual Salesforce flow-fault email: bold labels render as "*...*"
        // and the faulting element appears as "Error element X (Type)".
        String body = 'An Error Occurred with Your "FlowErrorDemo" Flow\n\n'
            + 'Error element Force_Validation_Failure (FlowRecordUpdate).\n'
            + 'This error occurred: FIELD_CUSTOM_VALIDATION_EXCEPTION: deliberate failure.\n\n'
            + 'Flow Error Details\n'
            + 'Flow Details\n'
            + '*Flow API Name: *FlowErrorDemo\n'
            + '*Type: *Autolaunched Flow\n';

        NortEmailParser.ParsedError parsed = NortEmailParser.parse(
            'An error occurred with your "FlowErrorDemo" flow', body
        );

        Assert.areEqual('Flow', parsed.source, 'Real flow email should detect Flow source.');
        Assert.isFalse(parsed.parseFailed, 'Real flow email format should parse cleanly.');
        Assert.areEqual('FlowErrorDemo', parsed.flowApiName, 'Flow API name should parse past the bold marker.');
        Assert.areEqual('Force_Validation_Failure', parsed.faultingElement, '"Error element X" phrasing should be extracted.');
    }

    @isTest
    static void shouldFlagParseFailed_WhenUnrecognized() {
        NortEmailParser.ParsedError parsed = NortEmailParser.parse('Newsletter', 'Just some marketing content.');
        Assert.areEqual('Unknown', parsed.source, 'Unrecognized content should be Unknown.');
        Assert.isTrue(parsed.parseFailed, 'Unrecognized content should be flagged as parse failed.');
    }

    @isTest
    static void shouldFlagParseFailed_WhenApexBodyEmpty() {
        NortEmailParser.ParsedError parsed = NortEmailParser.parse('Apex script unhandled exception', null);
        Assert.areEqual('Apex', parsed.source, 'Signal in subject should still detect Apex.');
        Assert.isTrue(parsed.parseFailed, 'Empty Apex body should be flagged as parse failed.');
    }

    @isTest
    static void shouldParseTriggerFrame_WhenTriggerException() {
        String body = 'Apex script unhandled trigger exception by user/organization/' + UserInfo.getUserId() + '/00D\n\n'
            + 'caused by: System.DmlException: Insert failed.\n\n'
            + 'Trigger.AccountTrigger: line 5, column 1\n';

        NortEmailParser.ParsedError parsed = NortEmailParser.parse('trigger', body);

        Assert.areEqual('AccountTrigger', parsed.className, 'Trigger name should be captured as the class.');
        Assert.areEqual('trigger', parsed.methodName, 'Trigger frames use the synthetic method name "trigger".');
    }

    @isTest
    static void shouldNeverThrow_WhenInputsNull() {
        NortEmailParser.ParsedError parsed = NortEmailParser.parse(null, null);
        Assert.areEqual('Unknown', parsed.source, 'Null inputs should yield Unknown, not an exception.');
    }
}
