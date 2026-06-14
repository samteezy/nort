/**
 * Tests for NortToolingClient: the injectable-client seam (fetchFlowMetadata via
 * a mock ToolingClient) and the default HttpToolingClient's HTTP shaping/parsing
 * via Test.setMock(HttpCalloutMock). No test hits a live endpoint.
 */
@isTest
private class NortToolingClientTest {
    private static final String FLOW_VERSION_ID = '301000000000001';

    // ---- Injected-client seam ----

    @isTest
    static void shouldSummarizeFlow_ViaInjectedClient() {
        StubToolingClient stub = new StubToolingClient();
        stub.queryResult = new List<Object>{ new Map<String, Object>{ 'ActiveVersionId' => FLOW_VERSION_ID } };
        stub.recordResult = new Map<String, Object>{
            'Metadata' => new Map<String, Object>{
                'processType' => 'AutoLaunchedFlow',
                'decisions' => new List<Object>{ new Map<String, Object>{ 'name' => 'CheckStatus' } },
                'recordUpdates' => new List<Object>{
                    new Map<String, Object>{ 'name' => 'UpdateAcct', 'faultConnector' => new Map<String, Object>{ 'targetReference' => 'Fault' } }
                }
            }
        };
        NortToolingClient.setClient(stub);

        NortToolingClient.FlowMetadata result = NortToolingClient.fetchFlowMetadata('My_Flow');

        Assert.isTrue(result.success, 'A resolvable flow should succeed.');
        Assert.isTrue(result.summary.contains('CheckStatus'), 'Summary should name the decision element.');
        Assert.isTrue(result.summary.contains('has fault path'), 'Summary should flag elements with fault connectors.');
    }

    @isTest
    static void shouldReturnFailure_WhenFlowDefinitionMissing() {
        StubToolingClient stub = new StubToolingClient();
        stub.queryResult = new List<Object>();
        NortToolingClient.setClient(stub);

        NortToolingClient.FlowMetadata result = NortToolingClient.fetchFlowMetadata('Ghost_Flow');

        Assert.isFalse(result.success, 'A missing flow definition should not succeed.');
        Assert.isNotNull(result.errorMessage, 'A failure reason should be reported.');
    }

    @isTest
    static void shouldReturnFailure_WhenBlankFlowName() {
        NortToolingClient.FlowMetadata result = NortToolingClient.fetchFlowMetadata('  ');
        Assert.isFalse(result.success, 'A blank flow name should not succeed.');
    }

    @isTest
    static void shouldDegrade_WhenClientThrows() {
        NortToolingClient.setClient(new ThrowingToolingClient());
        NortToolingClient.FlowMetadata result = NortToolingClient.fetchFlowMetadata('Boom_Flow');
        Assert.isFalse(result.success, 'A thrown transport error must be caught, not propagated.');
        Assert.isNotNull(result.errorMessage, 'The error should be surfaced on the result.');
    }

    // ---- Default HttpToolingClient ----

    @isTest
    static void shouldParseRecords_FromDefaultClient() {
        NortConfig.configOverride = TestDataFactory.config();
        Test.setMock(HttpCalloutMock.class, new SingleResponseMock(200, '{"records":[{"Name":"A"},{"Name":"B"}]}'));

        Test.startTest();
        List<Object> records = NortToolingClient.query('SELECT Name FROM ApexClass');
        Test.stopTest();

        Assert.areEqual(2, records.size(), 'Both records should be parsed from the response.');
    }

    @isTest
    static void shouldThrow_OnNonSuccessStatus() {
        NortConfig.configOverride = TestDataFactory.config();
        Test.setMock(HttpCalloutMock.class, new SingleResponseMock(404, '[{"message":"Not found"}]'));

        Test.startTest();
        Boolean threw = false;
        try {
            NortToolingClient.query('SELECT Name FROM ApexClass');
        } catch (NortToolingClient.NortToolingException e) {
            threw = true;
            Assert.isTrue(e.getMessage().contains('404'), 'The exception should carry the HTTP status.');
        }
        Test.stopTest();

        Assert.isTrue(threw, 'A non-2xx status should raise NortToolingException.');
    }

    @isTest
    static void shouldFetchFlowMetadata_ViaDefaultClient() {
        NortConfig.configOverride = TestDataFactory.config();
        Test.setMock(HttpCalloutMock.class, new FlowMock());

        Test.startTest();
        NortToolingClient.FlowMetadata result = NortToolingClient.fetchFlowMetadata('Routing_Flow');
        Test.stopTest();

        Assert.isTrue(result.success, 'The default client should resolve the flow end to end.');
        Assert.isTrue(result.summary.contains('assignments'), 'Summary should include the assignment elements.');
    }

    // ---- Mocks ----

    private class StubToolingClient implements NortToolingClient.ToolingClient {
        List<Object> queryResult = new List<Object>();
        Map<String, Object> recordResult;
        public List<Object> query(String soql) {
            return queryResult;
        }
        public Map<String, Object> getRecord(String sObjectType, Id recordId) {
            return recordResult;
        }
    }

    private class ThrowingToolingClient implements NortToolingClient.ToolingClient {
        public List<Object> query(String soql) {
            throw new NortToolingClient.NortToolingException('boom');
        }
        public Map<String, Object> getRecord(String sObjectType, Id recordId) {
            throw new NortToolingClient.NortToolingException('boom');
        }
    }

    private class SingleResponseMock implements HttpCalloutMock {
        private Integer status;
        private String body;
        SingleResponseMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }

    private class FlowMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            if (request.getEndpoint().contains('/sobjects/Flow/')) {
                response.setBody('{"Metadata":{"assignments":[{"name":"SetField"}],"decisions":[{"name":"Branch"}]}}');
            } else {
                response.setBody('{"records":[{"ActiveVersionId":"' + FLOW_VERSION_ID + '"}]}');
            }
            return response;
        }
    }
}
