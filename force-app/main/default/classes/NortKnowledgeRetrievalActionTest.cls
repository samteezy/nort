/**
 * Tests for NortKnowledgeRetrievalAction: it succeeds whether or not Knowledge
 * is enabled (degrading to a no-op seam) and validates input.
 */
@isTest
private class NortKnowledgeRetrievalActionTest {
    @isTest
    static void shouldSucceed_RegardlessOfKnowledgeAvailability() {
        NortKnowledgeRetrievalAction.Request request = new NortKnowledgeRetrievalAction.Request();
        request.searchText = 'NullPointerException recalculate';

        Test.startTest();
        List<NortKnowledgeRetrievalAction.Response> responses = NortKnowledgeRetrievalAction.retrieve(
            new List<NortKnowledgeRetrievalAction.Request>{ request }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'One response per request.');
        Assert.isTrue(responses[0].isSuccess, 'Retrieval should succeed even when Knowledge is unavailable (no-op seam).');
    }

    @isTest
    static void shouldReturnError_WhenSearchTextBlank() {
        NortKnowledgeRetrievalAction.Request request = new NortKnowledgeRetrievalAction.Request();
        request.searchText = '';
        List<NortKnowledgeRetrievalAction.Response> responses = NortKnowledgeRetrievalAction.retrieve(
            new List<NortKnowledgeRetrievalAction.Request>{ request }
        );
        Assert.isFalse(responses[0].isSuccess, 'Blank search text should be rejected.');
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        Assert.areEqual(
            0, NortKnowledgeRetrievalAction.retrieve(new List<NortKnowledgeRetrievalAction.Request>()).size(),
            'No requests should yield no responses.'
        );
    }
}
