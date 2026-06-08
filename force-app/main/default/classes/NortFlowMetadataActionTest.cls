/**
 * Tests for NortFlowMetadataAction: not-found and empty handling. The success
 * path requires a deployed flow and is exercised in integration, not unit tests.
 */
@isTest
private class NortFlowMetadataActionTest {
    @isTest
    static void shouldReturnNotFound_WhenFlowMissing() {
        NortFlowMetadataAction.Request request = new NortFlowMetadataAction.Request();
        request.flowApiName = 'No_Such_Flow_Xyzzy';

        Test.startTest();
        List<NortFlowMetadataAction.Response> responses = NortFlowMetadataAction.readFlowMetadata(
            new List<NortFlowMetadataAction.Request>{ request }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'One response per request.');
        Assert.isFalse(responses[0].isSuccess, 'A missing flow should not resolve.');
        Assert.areEqual('NotFound', responses[0].errorType, 'Error type should be NotFound.');
        Assert.isNotNull(responses[0].note, 'The degradation note should always be present.');
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        Assert.areEqual(
            0, NortFlowMetadataAction.readFlowMetadata(new List<NortFlowMetadataAction.Request>()).size(),
            'No requests should yield no responses.'
        );
    }

    @isTest
    static void shouldHandleBlankFlowName() {
        NortFlowMetadataAction.Request request = new NortFlowMetadataAction.Request();
        request.flowApiName = '  ';
        List<NortFlowMetadataAction.Response> responses = NortFlowMetadataAction.readFlowMetadata(
            new List<NortFlowMetadataAction.Request>{ request }
        );
        Assert.isFalse(responses[0].isSuccess, 'A blank flow name should not resolve.');
    }
}
