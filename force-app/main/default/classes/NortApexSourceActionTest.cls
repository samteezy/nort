/**
 * Tests for NortApexSourceAction: reads a real class body, scopes output, and
 * handles not-found and empty inputs.
 */
@isTest
private class NortApexSourceActionTest {
    @isTest
    static void shouldReturnSource_WhenClassExists() {
        NortApexSourceAction.Request request = new NortApexSourceAction.Request();
        request.className = 'NortFingerprint';

        Test.startTest();
        List<NortApexSourceAction.Response> responses = NortApexSourceAction.readSource(
            new List<NortApexSourceAction.Request>{ request }
        );
        Test.stopTest();

        Assert.areEqual(1, responses.size(), 'One response per request.');
        Assert.isTrue(responses[0].isSuccess, 'An existing class should resolve.');
        Assert.isTrue(responses[0].source.contains('class NortFingerprint'), 'Source should contain the class body.');
    }

    @isTest
    static void shouldReturnNotFound_WhenClassMissing() {
        NortApexSourceAction.Request request = new NortApexSourceAction.Request();
        request.className = 'No_Such_Class_Xyzzy';

        Test.startTest();
        List<NortApexSourceAction.Response> responses = NortApexSourceAction.readSource(
            new List<NortApexSourceAction.Request>{ request }
        );
        Test.stopTest();

        Assert.isFalse(responses[0].isSuccess, 'A missing class should not resolve.');
        Assert.areEqual('NotFound', responses[0].errorType, 'Error type should be NotFound.');
    }

    @isTest
    static void shouldReturnEmpty_WhenNoRequests() {
        Assert.areEqual(
            0, NortApexSourceAction.readSource(new List<NortApexSourceAction.Request>()).size(),
            'No requests should yield no responses.'
        );
    }

    @isTest
    static void shouldHandleBlankClassName() {
        NortApexSourceAction.Request request = new NortApexSourceAction.Request();
        request.className = '   ';
        List<NortApexSourceAction.Response> responses = NortApexSourceAction.readSource(
            new List<NortApexSourceAction.Request>{ request }
        );
        Assert.isFalse(responses[0].isSuccess, 'A blank class name should not resolve.');
    }
}
