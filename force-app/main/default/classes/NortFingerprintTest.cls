/**
 * Tests for NortFingerprint: volatile-token stripping, determinism, and the
 * source-aware key composition that the entire dedup gate depends on.
 */
@isTest
private class NortFingerprintTest {
    private static NortFingerprint.FingerprintInput apexInput(String message) {
        NortFingerprint.FingerprintInput input = new NortFingerprint.FingerprintInput();
        input.source = NortFingerprint.SOURCE_APEX;
        input.className = 'AccountService';
        input.methodName = 'recalculate';
        input.exceptionType = 'System.NullPointerException';
        input.rawMessage = message;
        return input;
    }

    @isTest
    static void shouldStripRecordIds_WhenNormalizing() {
        String result = NortFingerprint.normalizeMessage('Bad id 001A00000ABCDEFGHI here', 200);
        Assert.areEqual('Bad id {id} here', result, 'An 18-char record id should be replaced with {id}.');
    }

    @isTest
    static void shouldStripNumbers_WhenNormalizing() {
        String result = NortFingerprint.normalizeMessage('Row 42 of 1000 failed', 200);
        Assert.areEqual('Row {n} of {n} failed', result, 'Numeric literals should be replaced with {n}.');
    }

    @isTest
    static void shouldStripQuotedValues_WhenNormalizing() {
        String result = NortFingerprint.normalizeMessage('Value \'abc123\' rejected', 200);
        Assert.areEqual('Value \'{s}\' rejected', result, 'Single-quoted values should be collapsed.');
    }

    @isTest
    static void shouldStripTimestamps_WhenNormalizing() {
        String result = NortFingerprint.normalizeMessage('Failed at 2026-06-08T10:30:00Z today', 200);
        Assert.areEqual('Failed at {ts} today', result, 'Timestamps should be replaced with {ts}.');
    }

    @isTest
    static void shouldTruncate_WhenMessageExceedsSnippetLength() {
        String result = NortFingerprint.normalizeMessage('abcdefghij', 4);
        Assert.areEqual('abcd', result, 'The snippet should be truncated to the configured length.');
    }

    @isTest
    static void shouldReturnEmpty_WhenMessageBlank() {
        Assert.areEqual('', NortFingerprint.normalizeMessage(null, 200), 'Null message should normalize to empty.');
    }

    @isTest
    static void shouldHashEqual_WhenOnlyVolatileTokensDiffer() {
        NortFingerprint.FingerprintResult first = NortFingerprint.compute(
            apexInput('Null at row 12 for id 001A00000ABCDEFGHI')
        );
        NortFingerprint.FingerprintResult second = NortFingerprint.compute(
            apexInput('Null at row 999 for id 001A00000ZYXWVUTSR')
        );
        Assert.areEqual(first.hash, second.hash, 'Messages differing only by volatile tokens must collapse to one hash.');
    }

    @isTest
    static void shouldHashDiffer_WhenMethodDiffers() {
        NortFingerprint.FingerprintInput a = apexInput('boom');
        NortFingerprint.FingerprintInput b = apexInput('boom');
        b.methodName = 'differentMethod';
        Assert.areNotEqual(
            NortFingerprint.compute(a).hash,
            NortFingerprint.compute(b).hash,
            'Different methods must produce different fingerprints.'
        );
    }

    @isTest
    static void shouldProduce64CharHex_WhenComputing() {
        NortFingerprint.FingerprintResult result = NortFingerprint.compute(apexInput('boom'));
        Assert.areEqual(64, result.hash.length(), 'SHA-256 hex must be 64 characters.');
        Assert.isTrue(Pattern.matches('[0-9a-f]{64}', result.hash), 'Hash must be lowercase hex.');
    }

    @isTest
    static void shouldKeyOnFlowFields_WhenSourceIsFlow() {
        NortFingerprint.FingerprintInput apex = apexInput('boom');
        NortFingerprint.FingerprintInput flow = new NortFingerprint.FingerprintInput();
        flow.source = NortFingerprint.SOURCE_FLOW;
        flow.flowApiName = 'My_Flow';
        flow.faultingElement = 'Update_Records';
        flow.rawMessage = 'boom';
        Assert.areNotEqual(
            NortFingerprint.compute(apex).hash,
            NortFingerprint.compute(flow).hash,
            'Apex and Flow sources must not collide for the same message.'
        );
    }

    @isTest
    static void shouldThrow_WhenInputNull() {
        try {
            NortFingerprint.compute(null);
            Assert.fail('Expected NortFingerprintException for null input.');
        } catch (NortFingerprint.NortFingerprintException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message should indicate null input.');
        }
    }
}
