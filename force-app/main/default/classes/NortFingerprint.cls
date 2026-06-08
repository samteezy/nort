/**
 * Pure, side-effect-free utility that reduces a parsed runtime error to a
 * normalized, deterministic fingerprint. This is the spine of the dedup gate:
 * identical-modulo-volatile-tokens errors must collapse to the same hash so the
 * Agentforce agent is invoked at most once per unique fingerprint.
 *
 * Normalization strips volatile tokens (record IDs, numbers, quoted values,
 * timestamps, emails/URLs, and crucially line/column numbers, which shift on
 * every deploy) before composing the key. The key is then SHA-256 hashed to a
 * 64-char hex string used as the Error Signature external id.
 */
public with sharing class NortFingerprint {
    /** Source discriminators understood by the fingerprint key composition. */
    public static final String SOURCE_APEX = 'Apex';
    public static final String SOURCE_FLOW = 'Flow';

    /** Default leading-message length when no configuration is supplied. */
    @TestVisible
    private static final Integer DEFAULT_SNIPPET_LENGTH = 200;

    /** Field delimiter for the canonical key. Chosen to not occur in inputs. */
    private static final String KEY_DELIMITER = '␟';

    private static final String TOKEN_ID = '{id}';
    private static final String TOKEN_NUMBER = '{n}';
    private static final String TOKEN_TIMESTAMP = '{ts}';
    private static final String TOKEN_EMAIL = '{email}';
    private static final String TOKEN_URL = '{url}';

    // Ordering matters: URLs/emails/timestamps are stripped before bare numbers,
    // and Salesforce IDs before numbers so a long digit run is not split.
    private static final String RE_SF_ID = '\\b[a-zA-Z0-9]{18}\\b|\\b[a-zA-Z0-9]{15}\\b';
    private static final String RE_URL = '(?i)\\bhttps?://\\S+';
    private static final String RE_EMAIL = '[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}';
    private static final String RE_TIMESTAMP = '\\d{4}-\\d{2}-\\d{2}([T ]\\d{2}:\\d{2}:\\d{2}(\\.\\d+)?(Z|[+\\-]\\d{2}:?\\d{2})?)?|\\d{1,2}/\\d{1,2}/\\d{2,4}';
    private static final String RE_SINGLE_QUOTED = '\'[^\']*\'';
    private static final String RE_DOUBLE_QUOTED = '"[^"]*"';
    private static final String RE_NUMBER = '\\d+(\\.\\d+)?';
    private static final String RE_WHITESPACE = '\\s+';

    private NortFingerprint() {
        // Utility class; never instantiated.
    }

    /**
     * Structured input describing a single parsed error occurrence. Volatile
     * line/column data is intentionally absent — it must never reach the key.
     */
    public class FingerprintInput {
        public String source;
        public String className;
        public String methodName;
        public String exceptionType;
        public String flowApiName;
        public String faultingElement;
        public String rawMessage;
    }

    /** Result of fingerprinting: the hash plus the normalized snippet kept for display. */
    public class FingerprintResult {
        public String hash;
        public String normalizedSnippet;

        public FingerprintResult(String hash, String normalizedSnippet) {
            this.hash = hash;
            this.normalizedSnippet = normalizedSnippet;
        }
    }

    /**
     * Computes the fingerprint for a parsed error using the default snippet length.
     *
     * @param input Parsed error components.
     * @return The fingerprint hash and the normalized message snippet.
     * @example
     * NortFingerprint.FingerprintResult r = NortFingerprint.compute(input);
     */
    public static FingerprintResult compute(FingerprintInput input) {
        return compute(input, DEFAULT_SNIPPET_LENGTH);
    }

    /**
     * Computes the fingerprint for a parsed error.
     *
     * @param input Parsed error components (source-aware).
     * @param snippetLength Leading characters of the normalized message to retain.
     * @return The fingerprint hash and the normalized message snippet.
     */
    public static FingerprintResult compute(FingerprintInput input, Integer snippetLength) {
        if (input == null) {
            throw new NortFingerprintException('FingerprintInput must not be null.');
        }
        Integer effectiveLength = (snippetLength == null || snippetLength <= 0)
            ? DEFAULT_SNIPPET_LENGTH
            : snippetLength;

        String snippet = normalizeMessage(input.rawMessage, effectiveLength);
        String canonicalKey = buildCanonicalKey(input, snippet);
        String hash = sha256Hex(canonicalKey);
        return new FingerprintResult(hash, snippet);
    }

    /**
     * Normalizes a raw error message by stripping volatile tokens and truncating.
     *
     * @param message Raw message text (may be null).
     * @param snippetLength Leading characters to retain after normalization.
     * @return The normalized, truncated message snippet (never null).
     */
    public static String normalizeMessage(String message, Integer snippetLength) {
        if (String.isBlank(message)) {
            return '';
        }
        Integer effectiveLength = (snippetLength == null || snippetLength <= 0)
            ? DEFAULT_SNIPPET_LENGTH
            : snippetLength;

        String working = message;
        working = working.replaceAll(RE_SF_ID, TOKEN_ID);
        working = working.replaceAll(RE_URL, TOKEN_URL);
        working = working.replaceAll(RE_EMAIL, TOKEN_EMAIL);
        working = working.replaceAll(RE_TIMESTAMP, TOKEN_TIMESTAMP);
        working = working.replaceAll(RE_SINGLE_QUOTED, '\'' + '{s}' + '\'');
        working = working.replaceAll(RE_DOUBLE_QUOTED, '"{s}"');
        working = working.replaceAll(RE_NUMBER, TOKEN_NUMBER);
        working = working.replaceAll(RE_WHITESPACE, ' ').trim();

        if (working.length() > effectiveLength) {
            working = working.substring(0, effectiveLength);
        }
        return working;
    }

    /**
     * Builds the canonical, source-aware key string prior to hashing.
     *
     * @param input Parsed error components.
     * @param normalizedSnippet The already-normalized message snippet.
     * @return The delimiter-joined canonical key.
     */
    @TestVisible
    private static String buildCanonicalKey(FingerprintInput input, String normalizedSnippet) {
        List<String> parts = new List<String>();
        if (SOURCE_FLOW.equalsIgnoreCase(input.source)) {
            parts.add(SOURCE_FLOW.toLowerCase());
            parts.add(normalizePart(input.flowApiName));
            parts.add(normalizePart(input.faultingElement));
            parts.add(normalizedSnippet == null ? '' : normalizedSnippet);
        } else {
            parts.add(SOURCE_APEX.toLowerCase());
            parts.add(normalizePart(input.className));
            parts.add(normalizePart(input.methodName));
            parts.add(normalizePart(input.exceptionType));
            parts.add(normalizedSnippet == null ? '' : normalizedSnippet);
        }
        return String.join(parts, KEY_DELIMITER);
    }

    private static String normalizePart(String value) {
        return String.isBlank(value) ? '' : value.trim();
    }

    /**
     * Produces a lowercase hex SHA-256 digest of the supplied string.
     *
     * @param value The canonical key to hash.
     * @return 64-character lowercase hex string.
     */
    @TestVisible
    private static String sha256Hex(String value) {
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(value));
        return EncodingUtil.convertToHex(digest);
    }

    /** Thrown when fingerprint inputs are invalid. */
    public class NortFingerprintException extends Exception {}
}
