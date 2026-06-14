/**
 * Tests for NortAnalysisGroundingProvider: descriptor parsing (good/unknown/
 * malformed/over-cap), per-type resolution (apex via SOQL; flow/field/symboltable
 * via an injected NortToolingClient mock), the error-context header, and the
 * read-only (no-DML) contract. The prompt template, its model, and the agent's
 * item choices are platform config with no Apex test surface (manual smoke test).
 */
@isTest
private class NortAnalysisGroundingProviderTest {
    private static final String FLOW_VERSION_ID = '301000000000001';

    private static NortAnalysisGroundingProvider.Request request(String items) {
        NortConfig.configOverride = TestDataFactory.config();
        NortAnalysisGroundingProvider.Request request = new NortAnalysisGroundingProvider.Request();
        request.requestedItems = items;
        return request;
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        Assert.areEqual(
            0,
            NortAnalysisGroundingProvider.build(new List<NortAnalysisGroundingProvider.Request>()).size(),
            'No requests should yield no responses.'
        );
    }

    @isTest
    static void shouldAssembleApexSection_FromRealClass() {
        // NortConstants exists in the org; NortApexSourceAction reads it via SOQL (no callout).
        String context = NortAnalysisGroundingProvider.buildContext(request('apex:NortConstants'));
        Assert.isTrue(context.contains('// ===== apex:NortConstants ====='), 'Apex section header should be present.');
        Assert.isTrue(context.contains('NortConstants'), 'Apex section should include the class source.');
    }

    @isTest
    static void shouldNoteUnknownAndMalformedTokens() {
        String context = NortAnalysisGroundingProvider.buildContext(
            request('bogus:Foo\nnoSeparatorHere\nfield:')
        );
        Assert.isTrue(context.contains('skipped (unknown type): bogus:Foo'), 'Unknown types should be noted, not errored.');
        Assert.isTrue(context.contains('skipped (malformed): noSeparatorHere'), 'Tokens without a separator should be noted.');
        Assert.isTrue(context.contains('skipped (malformed): field:'), 'Tokens with an empty identifier should be noted.');
    }

    @isTest
    static void shouldCapToMaxItems() {
        nort_Config__mdt config = TestDataFactory.config();
        config.Max_Analysis_Items__c = 1;
        NortConfig.configOverride = config;

        NortAnalysisGroundingProvider.Request req = new NortAnalysisGroundingProvider.Request();
        req.requestedItems = 'apex:NortConstants\napex:NortConfig';
        String context = NortAnalysisGroundingProvider.buildContext(req);

        Assert.isTrue(context.contains('skipped (over max 1 items)'), 'Items beyond the cap should be dropped with a note.');
    }

    @isTest
    static void shouldDedupeIdenticalTokens() {
        String context = NortAnalysisGroundingProvider.buildContext(request('apex:NortConstants\napex:NortConstants'));
        Assert.isFalse(
            context.indexOf('// ===== apex:NortConstants =====') != context.lastIndexOf('// ===== apex:NortConstants ====='),
            'Identical tokens should resolve only once.'
        );
    }

    @isTest
    static void shouldResolveFlowInternals_ViaInjectedClient() {
        StubToolingClient stub = new StubToolingClient();
        stub.queryResult = new List<Object>{ new Map<String, Object>{ 'ActiveVersionId' => FLOW_VERSION_ID } };
        stub.recordResult = new Map<String, Object>{
            'Metadata' => new Map<String, Object>{
                'decisions' => new List<Object>{ new Map<String, Object>{ 'name' => 'RouteDecision' } }
            }
        };
        NortToolingClient.setClient(stub);

        String context = NortAnalysisGroundingProvider.buildContext(request('flow:Lead_Routing'));

        Assert.isTrue(context.contains('// ===== flow:Lead_Routing ====='), 'Flow section header should be present.');
        Assert.isTrue(context.contains('internal logic:'), 'Flow internals from the Tooling client should be included.');
        Assert.isTrue(context.contains('RouteDecision'), 'The decision element name should appear in the summary.');
    }

    @isTest
    static void shouldResolveField_ViaInjectedClient() {
        StubToolingClient stub = new StubToolingClient();
        stub.queryResult = new List<Object>{
            new Map<String, Object>{ 'DataType' => 'Picklist', 'Label' => 'Industry', 'IsNillable' => true }
        };
        NortToolingClient.setClient(stub);

        String context = NortAnalysisGroundingProvider.buildContext(request('field:Account.Industry'));

        Assert.isTrue(context.contains('// ===== field:Account.Industry ====='), 'Field section header should be present.');
        Assert.isTrue(context.contains('dataType: Picklist'), 'Field metadata should be summarized.');
    }

    @isTest
    static void shouldResolveSymbolTable_ViaInjectedClient() {
        StubToolingClient stub = new StubToolingClient();
        stub.queryResult = new List<Object>{
            new Map<String, Object>{
                'Name' => 'NortConstants',
                'SymbolTable' => new Map<String, Object>{
                    'methods' => new List<Object>{ new Map<String, Object>{ 'name' => 'doThing' } }
                }
            }
        };
        NortToolingClient.setClient(stub);

        String context = NortAnalysisGroundingProvider.buildContext(request('symboltable:NortConstants'));

        Assert.isTrue(context.contains('// ===== symboltable:NortConstants ====='), 'Symbol table header should be present.');
        Assert.isTrue(context.contains('doThing'), 'Method names should appear in the symbol-table summary.');
    }

    @isTest
    static void shouldEchoErrorContextHeader() {
        NortAnalysisGroundingProvider.Request req = request('apex:NortConstants');
        req.exceptionType = 'System.NullPointerException';
        req.messageTemplate = 'attempt to de-reference a null object';
        String context = NortAnalysisGroundingProvider.buildContext(req);

        Assert.isTrue(context.contains('// ===== error context ====='), 'A context header should be emitted when fields are present.');
        Assert.isTrue(context.contains('System.NullPointerException'), 'The exception type should be echoed.');
    }

    @isTest
    static void shouldReturnPlaceholder_WhenNothingRetrievable() {
        String context = NortAnalysisGroundingProvider.buildContext(request('   '));
        Assert.isTrue(context.contains('No retrievable'), 'A blank request should yield an explicit placeholder.');
    }

    @isTest
    static void shouldPerformNoDml() {
        Integer before = Limits.getDmlStatements();
        NortToolingClient.setClient(new StubToolingClient());
        NortAnalysisGroundingProvider.buildContext(request('apex:NortConstants\nfield:Account.Industry'));
        Assert.areEqual(before, Limits.getDmlStatements(), 'Grounding must not perform DML (callout-ordering contract).');
    }

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
}
