/**
 * Tests for NortAgentInvoker: response parsing (JSON and plain text), prompt
 * construction, client injection, and the default client's guard/exception
 * handling. No real agent is invoked.
 */
@isTest
private class NortAgentInvokerTest {
    private static NortAgentInvoker.DiagnosisRequest request() {
        NortAgentInvoker.DiagnosisRequest request = new NortAgentInvoker.DiagnosisRequest();
        request.source = 'Apex';
        request.className = 'AccountService';
        request.methodName = 'recalculate';
        request.exceptionType = 'System.NullPointerException';
        request.messageTemplate = 'null deref';
        return request;
    }

    @isTest
    static void shouldParseJsonResponse() {
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.parseResponse(
            '{"rootCause":"NPE in recalculate","recommendation":"null-check"}'
        );
        Assert.isTrue(result.success, 'Valid JSON should parse successfully.');
        Assert.areEqual('NPE in recalculate', result.rootCause, 'Root cause should be extracted.');
        Assert.areEqual('null-check', result.recommendation, 'Recommendation should be extracted.');
    }

    @isTest
    static void shouldUnwrapEnvelopedJsonResponse() {
        // The live generateAiAgentResponse action wraps the agent reply as
        // {"type":"Text","value":"<inner JSON string>"}; parsing must unwrap it.
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.parseResponse(
            '{"type":"Text","value":"{\\"rootCause\\":\\"NPE in recalculate\\",\\"recommendation\\":\\"null-check\\"}"}'
        );
        Assert.isTrue(result.success, 'Enveloped JSON should parse successfully.');
        Assert.areEqual('NPE in recalculate', result.rootCause, 'Root cause should be extracted from the envelope.');
        Assert.areEqual('null-check', result.recommendation, 'Recommendation should be extracted from the envelope.');
    }

    @isTest
    static void shouldUnwrapEnvelopedPlainText() {
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.parseResponse(
            '{"type":"Text","value":"Just a plain explanation."}'
        );
        Assert.isTrue(result.success, 'Enveloped plain text should still be usable.');
        Assert.areEqual('Just a plain explanation.', result.rootCause, 'Envelope value becomes the root cause.');
    }

    @isTest
    static void shouldTreatPlainTextAsRootCause() {
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.parseResponse('Just a plain explanation.');
        Assert.isTrue(result.success, 'Plain text should still be a usable result.');
        Assert.areEqual('Just a plain explanation.', result.rootCause, 'Plain text becomes the root cause.');
    }

    @isTest
    static void shouldFail_WhenResponseBlank() {
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.parseResponse('');
        Assert.isFalse(result.success, 'A blank response is a failure.');
    }

    @isTest
    static void shouldBuildPrompt_WithTargetDetails() {
        String prompt = NortAgentInvoker.buildPrompt(request());
        Assert.isTrue(prompt.contains('AccountService'), 'Prompt should name the failing class.');
        Assert.isTrue(prompt.contains('rootCause'), 'Prompt should instruct a JSON shape.');
    }

    @isTest
    static void shouldIncludeRawNotification_WhenProvided() {
        NortAgentInvoker.DiagnosisRequest req = request();
        req.rawMessage = 'VERBATIM_RAW_EMAIL_CONTENT';
        String prompt = NortAgentInvoker.buildPrompt(req);
        Assert.isTrue(prompt.contains('Raw notification'), 'Prompt should include a raw notification section.');
        Assert.isTrue(prompt.contains('VERBATIM_RAW_EMAIL_CONTENT'), 'Prompt should embed the raw payload.');
    }

    @isTest
    static void shouldBuildSensiblePrompt_WhenDegradedWithNoStructuredFields() {
        // Degraded request: no class/flow, only the raw notification.
        NortAgentInvoker.DiagnosisRequest req = new NortAgentInvoker.DiagnosisRequest();
        req.source = 'Unknown';
        req.rawMessage = 'an unparsed error blob';
        String prompt = NortAgentInvoker.buildPrompt(req);
        Assert.isFalse(prompt.contains('"null"'), 'Degraded prompt must not emit a "null" target.');
        Assert.isTrue(prompt.contains('unparsed'), 'Degraded prompt should describe an unparsed notification.');
        Assert.isTrue(prompt.contains('an unparsed error blob'), 'Degraded prompt should carry the raw blob.');
    }

    @isTest
    static void shouldUseInjectedClient() {
        NortAgentInvoker.setClient(new StubClient());
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.diagnose(request());
        Assert.isTrue(result.success, 'Injected client result should be returned.');
        Assert.areEqual('stub', result.rootCause, 'Injected client should drive the result.');
    }

    @isTest
    static void shouldReturnError_WhenRequestNull() {
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.diagnose(null);
        Assert.isFalse(result.success, 'Null request should not succeed.');
        Assert.isNotNull(result.errorMessage, 'An error message should be provided.');
    }

    @isTest
    static void shouldFail_WhenNoAgentConfigured() {
        nort_Config__mdt config = TestDataFactory.config();
        config.Agent_API_Name__c = null;
        NortConfig.configOverride = config;
        NortAgentInvoker.clientOverride = null;

        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.diagnose(request());
        Assert.isFalse(result.success, 'Without an agent API name the default client should fail cleanly.');
        Assert.isTrue(result.errorMessage.contains('agent API name'), 'Error should explain the missing config.');
    }

    @isTest
    static void shouldFailGracefully_WhenAgentActionUnavailable() {
        NortConfig.configOverride = TestDataFactory.config();
        NortAgentInvoker.clientOverride = null;

        Test.startTest();
        NortAgentInvoker.DiagnosisResult result = NortAgentInvoker.diagnose(request());
        Test.stopTest();

        // The action does not exist in the test org; the seam must catch and report.
        Assert.isFalse(result.success, 'An unavailable agent action should yield a failed result, not an unhandled error.');
        Assert.isNotNull(result.errorMessage, 'The failure should be reported on the result.');
    }

    private class StubClient implements NortAgentInvoker.Client {
        public NortAgentInvoker.DiagnosisResult diagnose(NortAgentInvoker.DiagnosisRequest request) {
            NortAgentInvoker.DiagnosisResult result = new NortAgentInvoker.DiagnosisResult();
            result.success = true;
            result.rootCause = 'stub';
            return result;
        }
    }
}
