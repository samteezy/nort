/**
 * Source-detecting parser for inbound error notifications. Detects whether an
 * email is an Apex exception email or a Flow fault email and branches to the
 * appropriate extraction logic, returning a structured ParsedError.
 *
 * The Apex branch is fully wired for phase 1. The Flow branch is implemented to
 * degrade gracefully: it extracts what standard email content allows (flow API
 * name, faulting element, error text) and leaves the rest null. Deeper flow
 * logic is unavailable via standard SOQL and is deferred to a Tooling API phase.
 *
 * Parsing never throws — failures are reported on ParsedError so the inbound
 * handler can stage the raw payload rather than bounce or lose the email.
 */
public with sharing class NortEmailParser {
    private static final String SOURCE_APEX = 'Apex';
    private static final String SOURCE_FLOW = 'Flow';
    private static final String SOURCE_UNKNOWN = 'Unknown';

    // Source-detection signals.
    private static final List<String> FLOW_SIGNALS = new List<String>{
        'error occurred during flow',
        'flow details',
        'flow api name',
        'flow interview details'
    };
    private static final List<String> APEX_SIGNALS = new List<String>{
        'apex script unhandled exception',
        'developer script exception',
        'apex script unhandled trigger exception'
    };

    // Extraction patterns. Compiled lazily and cached per transaction.
    private static final String RE_CAUSED_BY = '(?i)caused by:\\s*([\\w\\.]+):\\s*([^\\n\\r]*)';
    private static final String RE_EXCEPTION = '([\\w\\.]*Exception):\\s*([^\\n\\r]*)';
    private static final String RE_CLASS_FRAME = '(?i)Class\\.([\\w.<>$ ]+?):\\s*line\\s*\\d+';
    private static final String RE_TRIGGER_FRAME = '(?i)Trigger\\.([\\w]+):\\s*line\\s*\\d+';
    private static final String RE_USER_ID = '(?i)user/organization/(005[A-Za-z0-9]{12,15})';
    private static final String RE_FLOW_API = '(?i)Flow API Name[:\\s]+([A-Za-z0-9_]+)';
    private static final String RE_FLOW_ELEMENT = '(?i)error occurred at element[:\\s]+([A-Za-z0-9_]+)';

    /** Structured result of parsing an inbound notification. */
    public class ParsedError {
        public String source = SOURCE_UNKNOWN;
        public String exceptionType;
        public String className;
        public String methodName;
        public String flowApiName;
        public String faultingElement;
        public String message;
        public String triggeringUserId;
        public Boolean parseFailed = false;
        public String parseError;
    }

    /**
     * Parses an inbound notification into structured fields.
     *
     * @param subject The email subject (may be null).
     * @param body The email plain-text body (may be null).
     * @return A ParsedError; check parseFailed/source before trusting fields.
     * @example
     * NortEmailParser.ParsedError parsed = NortEmailParser.parse(subject, body);
     */
    public static ParsedError parse(String subject, String body) {
        ParsedError result = new ParsedError();
        try {
            String haystack = ((subject == null ? '' : subject) + '\n' + (body == null ? '' : body));
            String lower = haystack.toLowerCase();

            result.source = detectSource(lower);
            if (SOURCE_FLOW == result.source) {
                parseFlow(body, result);
            } else if (SOURCE_APEX == result.source) {
                parseApex(body, result);
            } else {
                result.parseFailed = true;
                result.parseError = 'Unrecognized notification format; no Apex or Flow signals detected.';
            }
        } catch (Exception e) {
            result.parseFailed = true;
            result.parseError = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    /**
     * Detects the notification source from lowercased content signals.
     *
     * @param lowerContent Lowercased subject+body.
     * @return One of Apex, Flow, or Unknown.
     */
    @TestVisible
    private static String detectSource(String lowerContent) {
        for (String signal : FLOW_SIGNALS) {
            if (lowerContent.contains(signal)) {
                return SOURCE_FLOW;
            }
        }
        for (String signal : APEX_SIGNALS) {
            if (lowerContent.contains(signal)) {
                return SOURCE_APEX;
            }
        }
        return SOURCE_UNKNOWN;
    }

    private static void parseApex(String body, ParsedError result) {
        if (String.isBlank(body)) {
            result.parseFailed = true;
            result.parseError = 'Apex notification had an empty body.';
            return;
        }
        result.source = SOURCE_APEX;

        // Exception type + message: prefer the "caused by" line, else any Exception line.
        List<String> causedBy = firstMatch(RE_CAUSED_BY, body, new List<Integer>{ 1, 2 });
        if (causedBy != null) {
            result.exceptionType = causedBy[0];
            result.message = causedBy[1];
        } else {
            List<String> exc = firstMatch(RE_EXCEPTION, body, new List<Integer>{ 1, 2 });
            if (exc != null) {
                result.exceptionType = exc[0];
                result.message = exc[1];
            }
        }

        // Innermost stack frame: class + method (line/column intentionally discarded).
        List<String> classFrame = firstMatch(RE_CLASS_FRAME, body, new List<Integer>{ 1 });
        if (classFrame != null) {
            assignClassAndMethod(classFrame[0], result);
        } else {
            List<String> triggerFrame = firstMatch(RE_TRIGGER_FRAME, body, new List<Integer>{ 1 });
            if (triggerFrame != null) {
                result.className = triggerFrame[0];
                result.methodName = 'trigger';
            }
        }

        // Best-effort triggering user id; frequently absent, which is expected.
        List<String> userMatch = firstMatch(RE_USER_ID, body, new List<Integer>{ 1 });
        if (userMatch != null) {
            result.triggeringUserId = userMatch[0];
        }

        if (String.isBlank(result.exceptionType) && String.isBlank(result.className)) {
            result.parseFailed = true;
            result.parseError = 'Apex notification matched signals but no exception type or stack frame was extractable.';
        }
    }

    private static void parseFlow(String body, ParsedError result) {
        result.source = SOURCE_FLOW;
        if (String.isBlank(body)) {
            result.parseFailed = true;
            result.parseError = 'Flow notification had an empty body.';
            return;
        }

        List<String> flowApi = firstMatch(RE_FLOW_API, body, new List<Integer>{ 1 });
        if (flowApi != null) {
            result.flowApiName = flowApi[0];
        }
        List<String> element = firstMatch(RE_FLOW_ELEMENT, body, new List<Integer>{ 1 });
        if (element != null) {
            result.faultingElement = element[0];
        }
        // Message: prefer an explicit error line, else fall back to the element line context.
        List<String> exc = firstMatch(RE_EXCEPTION, body, new List<Integer>{ 1, 2 });
        if (exc != null) {
            result.exceptionType = exc[0];
            result.message = exc[1];
        }
        if (String.isBlank(result.message)) {
            result.message = body.length() > 1000 ? body.substring(0, 1000) : body;
        }

        if (String.isBlank(result.flowApiName) && String.isBlank(result.faultingElement)) {
            result.parseFailed = true;
            result.parseError = 'Flow notification matched signals but neither flow API name nor faulting element was extractable.';
        }
    }

    /**
     * Splits a dotted stack-frame path into class and method, treating the final
     * segment as the method and the remainder as the (possibly nested) class.
     *
     * @param framePath The dotted path captured between "Class." and ": line".
     * @param result The ParsedError to populate.
     */
    @TestVisible
    private static void assignClassAndMethod(String framePath, ParsedError result) {
        String path = framePath == null ? '' : framePath.trim();
        Integer lastDot = path.lastIndexOf('.');
        if (lastDot > 0) {
            result.className = path.substring(0, lastDot);
            result.methodName = path.substring(lastDot + 1);
        } else {
            result.className = path;
            result.methodName = '';
        }
    }

    /**
     * Returns the requested capture groups from the first regex match, or null.
     *
     * @param regex The pattern to apply.
     * @param input The text to search.
     * @param groups Capture-group indices to return, in order.
     * @return A list of trimmed group values, or null if no match.
     */
    private static List<String> firstMatch(String regex, String input, List<Integer> groups) {
        Matcher matcher = Pattern.compile(regex).matcher(input);
        if (!matcher.find()) {
            return null;
        }
        List<String> values = new List<String>();
        for (Integer groupIndex : groups) {
            String value = matcher.group(groupIndex);
            values.add(value == null ? null : value.trim());
        }
        return values;
    }
}
