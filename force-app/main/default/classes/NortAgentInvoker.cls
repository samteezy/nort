/**
 * Headless invoker for the Agentforce diagnosis agent. Builds a grounded prompt
 * from an Error Signature, invokes the agent via the Invocable Action API, and
 * parses the structured root-cause / recommendation response.
 *
 * The actual agent call is isolated behind the Client interface so it can be
 * mocked in tests (dependency injection via setClient). The default
 * AgentforceClient contains the single integration seam — invokeAgent — whose
 * action type string and parameter keys must be verified against the target
 * org's published agent action in Summer '26.
 */
public with sharing class NortAgentInvoker {
    // Integration seam constants — verify against the org's published action.
    // Declared on the top-level class because Apex forbids static members on
    // inner classes; AgentforceClient (an inner class) references them directly.
    private static final String AGENT_ACTION_TYPE = 'generateAiAgentResponse';
    private static final String PARAM_AGENT = 'agentApiName';
    private static final String PARAM_MESSAGE = 'userMessage';
    private static final String OUTPUT_RESPONSE = 'agentResponse';

    /** Structured diagnosis request derived from an Error Signature. */
    public class DiagnosisRequest {
        public Id signatureId;
        public String source;
        public String className;
        public String methodName;
        public String exceptionType;
        public String messageTemplate;
        public String flowApiName;
        public String faultingElement;
    }

    /** Structured diagnosis result returned to the orchestrator. */
    public class DiagnosisResult {
        public Boolean success = false;
        public String rootCause;
        public String recommendation;
        public String errorMessage;
    }

    /** Pluggable agent client; the default talks to Agentforce, tests inject a mock. */
    public interface Client {
        DiagnosisResult diagnose(DiagnosisRequest request);
    }

    @TestVisible
    private static Client clientOverride;

    private NortAgentInvoker() {
        // Static entry point; never instantiated.
    }

    /**
     * Injects a Client implementation (used by tests for deterministic results).
     *
     * @param client The client to use for subsequent diagnose() calls.
     */
    @TestVisible
    public static void setClient(Client client) {
        clientOverride = client;
    }

    /**
     * Diagnoses a single signature via the resolved agent client.
     *
     * @param request The diagnosis request.
     * @return The diagnosis result (check success before using fields).
     */
    public static DiagnosisResult diagnose(DiagnosisRequest request) {
        if (request == null) {
            DiagnosisResult invalid = new DiagnosisResult();
            invalid.errorMessage = 'DiagnosisRequest must not be null.';
            return invalid;
        }
        return resolveClient().diagnose(request);
    }

    private static Client resolveClient() {
        return clientOverride != null ? clientOverride : new AgentforceClient();
    }

    /**
     * Default client that invokes the Agentforce agent headlessly.
     */
    public with sharing class AgentforceClient implements Client {
        public DiagnosisResult diagnose(DiagnosisRequest request) {
            DiagnosisResult result = new DiagnosisResult();
            String agentApiName = NortConfig.agentApiName();
            if (String.isBlank(agentApiName)) {
                result.errorMessage = 'No agent API name configured in nort_Config__mdt.';
                return result;
            }
            try {
                String rawResponse = invokeAgent(agentApiName, buildPrompt(request));
                return parseResponse(rawResponse);
            } catch (Exception e) {
                result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
                return result;
            }
        }

        /**
         * INTEGRATION SEAM. The single place that calls the Agentforce agent.
         * Action type and parameter keys are runtime strings; confirm them
         * against the target org's available actions before go-live.
         */
        private String invokeAgent(String agentApiName, String message) {
            Invocable.Action action = Invocable.Action.createCustomAction(AGENT_ACTION_TYPE, agentApiName);
            action.setInvocationParameter(PARAM_AGENT, agentApiName);
            action.setInvocationParameter(PARAM_MESSAGE, message);

            List<Invocable.Action.Result> results = action.invoke();
            if (results.isEmpty() || !results[0].isSuccess()) {
                throw new NortAgentException('Agent invocation returned no successful result.');
            }
            Object response = results[0].getOutputParameters().get(OUTPUT_RESPONSE);
            return response == null ? null : String.valueOf(response);
        }
    }

    /**
     * Builds the grounded diagnosis prompt instructing the agent to use its
     * actions (read scoped Apex source, read flow metadata, retrieve knowledge)
     * and return a strict JSON object.
     *
     * @param request The diagnosis request.
     * @return The prompt text.
     */
    @TestVisible
    private static String buildPrompt(DiagnosisRequest request) {
        String target = NortConstants.SOURCE_FLOW.equalsIgnoreCase(request.source)
            ? 'Flow "' + request.flowApiName + '" failing at element "' + request.faultingElement + '"'
            : 'Apex class "' + request.className + '" method "' + request.methodName + '"';

        return String.join(new List<String>{
            'You are diagnosing a recurring Salesforce runtime error.',
            'Target: ' + target + '.',
            'Exception type: ' + nullToEmpty(request.exceptionType) + '.',
            'Normalized message: ' + nullToEmpty(request.messageTemplate) + '.',
            'Use your actions to read the failing Apex source (scoped to the failing class and its direct dependencies),',
            'read available flow metadata, and retrieve any relevant knowledge articles.',
            'Respond with ONLY a JSON object: {"rootCause": "...", "recommendation": "..."}.'
        }, ' ');
    }

    /**
     * Parses the agent response, tolerating either strict JSON or plain text.
     *
     * @param rawResponse The agent's raw response string.
     * @return A populated DiagnosisResult.
     */
    @TestVisible
    private static DiagnosisResult parseResponse(String rawResponse) {
        DiagnosisResult result = new DiagnosisResult();
        if (String.isBlank(rawResponse)) {
            result.errorMessage = 'Agent returned an empty response.';
            return result;
        }
        try {
            Object parsed = JSON.deserializeUntyped(rawResponse);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> values = (Map<String, Object>) parsed;
                result.rootCause = stringOf(values.get('rootCause'));
                result.recommendation = stringOf(values.get('recommendation'));
                result.success = String.isNotBlank(result.rootCause) || String.isNotBlank(result.recommendation);
                if (!result.success) {
                    result.errorMessage = 'Agent JSON contained no rootCause or recommendation.';
                }
                return result;
            }
        } catch (Exception ignored) {
            // Not JSON; fall through to treat the response as a plain-text root cause.
        }
        result.rootCause = rawResponse;
        result.success = true;
        return result;
    }

    private static String stringOf(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static String nullToEmpty(String value) {
        return value == null ? '' : value;
    }

    /** Thrown on agent invocation failures. */
    public class NortAgentException extends Exception {}
}
