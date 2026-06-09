/**
 * Unit tests for NortAgentDiagnosisAction, the Flow-callable wrapper around the
 * agent. A mock Client is injected via NortAgentInvoker.setClient so these never
 * touch the live agent (per the project's no-real-agent-in-tests rule).
 */
@isTest
private class NortAgentDiagnosisActionTest {

    @isTest
    static void shouldMapAgentDiagnosisToResponse_WhenSingleRequest() {
        NortAgentInvoker.setClient(new EchoClient());

        NortAgentDiagnosisAction.Request request = new NortAgentDiagnosisAction.Request();
        request.className = 'NortIngestionService';
        request.methodName = 'publish';
        request.messageTemplate = 'Attempt to de-reference a null object';

        Test.startTest();
        List<NortAgentDiagnosisAction.Response> responses =
            NortAgentDiagnosisAction.diagnose(new List<NortAgentDiagnosisAction.Request>{ request });
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'One request should yield one response.');
        NortAgentDiagnosisAction.Response response = responses[0];
        Assert.isTrue(response.isSuccess, 'Successful diagnosis should map isSuccess=true.');
        Assert.areEqual('Root: Attempt to de-reference a null object', response.rootCause, 'Root cause should pass through from the agent.');
        Assert.areEqual('Add a null check.', response.recommendation, 'Recommendation should pass through from the agent.');
        Assert.isNull(response.errorMessage, 'A successful diagnosis should carry no error message.');
    }

    @isTest
    static void shouldReturnOneOrderedResponsePerRequest_WhenBulk() {
        NortAgentInvoker.setClient(new EchoClient());

        List<NortAgentDiagnosisAction.Request> requests = new List<NortAgentDiagnosisAction.Request>();
        for (Integer i = 0; i < 3; i++) {
            NortAgentDiagnosisAction.Request request = new NortAgentDiagnosisAction.Request();
            request.messageTemplate = 'msg-' + i;
            requests.add(request);
        }

        Test.startTest();
        List<NortAgentDiagnosisAction.Response> responses = NortAgentDiagnosisAction.diagnose(requests);
        Test.stopTest();

        Assert.areEqual(3, responses.size(), 'Each request should yield exactly one response.');
        for (Integer i = 0; i < 3; i++) {
            Assert.areEqual('Root: msg-' + i, responses[i].rootCause, 'Responses must stay in request order.');
        }
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        NortAgentInvoker.setClient(new EchoClient());

        Test.startTest();
        List<NortAgentDiagnosisAction.Response> nullCase = NortAgentDiagnosisAction.diagnose(null);
        List<NortAgentDiagnosisAction.Response> emptyCase =
            NortAgentDiagnosisAction.diagnose(new List<NortAgentDiagnosisAction.Request>());
        Test.stopTest();

        Assert.areEqual(0, nullCase.size(), 'Null input should return an empty list, not fail.');
        Assert.areEqual(0, emptyCase.size(), 'Empty input should return an empty list.');
    }

    @isTest
    static void shouldSurfaceErrorMessage_WhenAgentFails() {
        NortAgentInvoker.setClient(new FailureClient());

        NortAgentDiagnosisAction.Request request = new NortAgentDiagnosisAction.Request();
        request.className = 'NortIngestionService';

        Test.startTest();
        List<NortAgentDiagnosisAction.Response> responses =
            NortAgentDiagnosisAction.diagnose(new List<NortAgentDiagnosisAction.Request>{ request });
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'One request should yield one response even on failure.');
        Assert.isFalse(responses[0].isSuccess, 'A failed diagnosis should map isSuccess=false.');
        Assert.areEqual('agent unavailable', responses[0].errorMessage, 'The failure message should surface to the caller.');
    }

    /** Echoes request fields into a successful result so ordering/mapping is assertable. */
    private class EchoClient implements NortAgentInvoker.Client {
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
