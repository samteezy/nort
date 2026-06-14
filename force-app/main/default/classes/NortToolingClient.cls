/**
 * Generic, same-org Tooling API client — nort's single org-introspection seam.
 *
 * Standard SOQL cannot reach flow internal logic or Apex symbol tables; this
 * client closes that gap by calling the org's own Tooling API through a Named
 * Credential (callout:&lt;name&gt;/services/data/vXX.0/tooling/...). It exposes two
 * generic primitives — query() and getRecord() — plus typed convenience wrappers
 * (fetchFlowMetadata) that callers actually consume. Built generic on purpose:
 * later consumers (symbol tables, field definitions, dependency graphs) are
 * drop-in without reworking the auth/HTTP plumbing.
 *
 * The live HTTP call is isolated behind the ToolingClient interface so tests
 * inject a mock via setClient(...) — exactly like NortAgentInvoker. Tests of the
 * default HttpToolingClient use Test.setMock(HttpCalloutMock). No test ever hits
 * a live endpoint.
 *
 * The primitives THROW NortToolingException on transport/HTTP failure; callers
 * (e.g. NortAnalysisGroundingProvider) catch per-item to degrade gracefully so a
 * single unreachable item never fails the whole diagnosis.
 */
public with sharing class NortToolingClient {
    private static final String API_VERSION = 'v66.0';
    private static final Integer CALLOUT_TIMEOUT_MS = 120000;
    // Defensive ceiling so a pathological record can never pull megabytes into the
    // transaction; per-item/total token discipline is enforced by the caller.
    @TestVisible
    private static final Integer MAX_SUMMARY_CHARS = 8000;

    /** Summarized flow internals (the element graph SOQL can't reach). */
    public class FlowMetadata {
        public Boolean success = false;
        public String apiName;
        public String summary;
        public String errorMessage;
    }

    /** Pluggable Tooling transport; the default talks HTTP, tests inject a mock. */
    public interface ToolingClient {
        /** Runs a Tooling SOQL query, returning the parsed `records` list. */
        List<Object> query(String soql);
        /** GETs one Tooling record by id, returning the parsed object (incl. compound fields like Metadata). */
        Map<String, Object> getRecord(String sObjectType, Id recordId);
    }

    @TestVisible
    private static ToolingClient clientOverride;

    private NortToolingClient() {
        // Static entry point; never instantiated.
    }

    /**
     * Injects a ToolingClient implementation (tests use this for deterministic results).
     *
     * @param client The client to use for subsequent calls.
     */
    @TestVisible
    public static void setClient(ToolingClient client) {
        clientOverride = client;
    }

    private static ToolingClient resolveClient() {
        return clientOverride != null ? clientOverride : new HttpToolingClient();
    }

    /**
     * Runs a Tooling SOQL query.
     *
     * @param soql The Tooling query (caller must escape literals; see escapeLiteral).
     * @return The parsed `records` list (possibly empty).
     */
    public static List<Object> query(String soql) {
        return resolveClient().query(soql);
    }

    /**
     * GETs a single Tooling record by id.
     *
     * @param sObjectType The Tooling sObject type (e.g. 'Flow').
     * @param recordId The record id.
     * @return The parsed record object.
     */
    public static Map<String, Object> getRecord(String sObjectType, Id recordId) {
        return resolveClient().getRecord(sObjectType, recordId);
    }

    /**
     * Retrieves and summarizes a flow's internal element graph (decisions,
     * assignments, action calls, DML, loops, subflows, screens, fault paths) —
     * the logic standard SOQL on FlowDefinitionView cannot expose.
     *
     * Resolves the active (else latest) Flow version id, then GETs that version
     * (Flow.Metadata is single-record-only) and condenses it. Never throws:
     * returns a FlowMetadata with success=false so the caller can degrade.
     *
     * @param flowApiName The flow's developer/API name.
     * @return Summarized flow internals, or a failure result with errorMessage.
     */
    public static FlowMetadata fetchFlowMetadata(String flowApiName) {
        FlowMetadata result = new FlowMetadata();
        result.apiName = flowApiName;
        if (String.isBlank(flowApiName)) {
            result.errorMessage = 'No flow API name provided.';
            return result;
        }
        try {
            String defSoql =
                'SELECT Id, ActiveVersionId, LatestVersionId FROM FlowDefinition ' +
                'WHERE DeveloperName = \'' + escapeLiteral(flowApiName.trim()) + '\'';
            List<Object> defs = query(defSoql);
            if (defs.isEmpty()) {
                result.errorMessage = 'Flow "' + flowApiName + '" not found via the Tooling API.';
                return result;
            }
            Map<String, Object> def = (Map<String, Object>) defs[0];
            Object versionId = def.get('ActiveVersionId') != null ? def.get('ActiveVersionId') : def.get('LatestVersionId');
            if (versionId == null) {
                result.errorMessage = 'Flow "' + flowApiName + '" has no active or latest version.';
                return result;
            }
            Map<String, Object> flow = getRecord('Flow', (Id) String.valueOf(versionId));
            Object metadata = flow == null ? null : flow.get('Metadata');
            if (!(metadata instanceof Map<String, Object>)) {
                result.errorMessage = 'Flow "' + flowApiName + '" returned no Metadata.';
                return result;
            }
            result.summary = summarizeFlowMetadata((Map<String, Object>) metadata);
            result.success = true;
        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    /**
     * Condenses a Flow Metadata map into a compact, bounded element inventory so
     * the analysis model sees the flow's structure without the full verbose JSON.
     */
    @TestVisible
    private static String summarizeFlowMetadata(Map<String, Object> metadata) {
        List<String> lines = new List<String>();
        if (metadata.get('processType') != null) {
            lines.add('processType: ' + String.valueOf(metadata.get('processType')));
        }
        if (metadata.get('start') != null) {
            lines.add('has start element');
        }
        // Element collections worth surfacing for diagnosis, in evaluation-ish order.
        for (String key : new List<String>{
            'decisions', 'assignments', 'actionCalls', 'recordLookups', 'recordCreates',
            'recordUpdates', 'recordDeletes', 'loops', 'subflows', 'screens', 'waits'
        }) {
            Object value = metadata.get(key);
            if (value instanceof List<Object>) {
                List<Object> elements = (List<Object>) value;
                if (elements.isEmpty()) {
                    continue;
                }
                List<String> names = new List<String>();
                for (Object element : elements) {
                    if (element instanceof Map<String, Object>) {
                        Map<String, Object> el = (Map<String, Object>) element;
                        String name = String.valueOf(el.get('name'));
                        Boolean hasFault = el.get('faultConnector') != null;
                        names.add(hasFault ? name + ' (has fault path)' : name);
                    }
                }
                lines.add(key + ' [' + names.size() + ']: ' + String.join(names, ', '));
            }
        }
        String summary = lines.isEmpty() ? 'No diagnosable elements found in flow metadata.' : String.join(lines, '\n');
        return summary.length() > MAX_SUMMARY_CHARS ? summary.substring(0, MAX_SUMMARY_CHARS) + '\n…[truncated]' : summary;
    }

    /**
     * Escapes single quotes in a value destined for an inlined Tooling SOQL
     * literal (REST callout queries can't use Apex bind variables).
     *
     * @param value The raw value.
     * @return The value with single quotes escaped.
     */
    @TestVisible
    private static String escapeLiteral(String value) {
        return value == null ? '' : value.replace('\'', '\\\'');
    }

    /**
     * Default client: talks to the org's own Tooling API through the configured
     * Named Credential. The single live integration seam in this class.
     */
    public with sharing class HttpToolingClient implements ToolingClient {
        public List<Object> query(String soql) {
            String path = '/query/?q=' + EncodingUtil.urlEncode(soql, 'UTF-8');
            Map<String, Object> parsed = send('GET', path);
            Object records = parsed.get('records');
            return records instanceof List<Object> ? (List<Object>) records : new List<Object>();
        }

        public Map<String, Object> getRecord(String sObjectType, Id recordId) {
            return send('GET', '/sobjects/' + sObjectType + '/' + recordId);
        }

        private Map<String, Object> send(String method, String toolingPath) {
            HttpRequest request = new HttpRequest();
            request.setEndpoint(
                'callout:' + NortConfig.toolingNamedCredential() +
                '/services/data/' + API_VERSION + '/tooling' + toolingPath
            );
            request.setMethod(method);
            request.setHeader('Accept', 'application/json');
            request.setTimeout(CALLOUT_TIMEOUT_MS);

            HttpResponse response = new Http().send(request);
            Integer status = response.getStatusCode();
            if (status < 200 || status >= 300) {
                throw new NortToolingException(
                    'Tooling API ' + method + ' ' + toolingPath + ' failed (' + status + '): ' + response.getBody()
                );
            }
            Object parsed = JSON.deserializeUntyped(response.getBody());
            if (!(parsed instanceof Map<String, Object>)) {
                throw new NortToolingException('Unexpected Tooling API response shape.');
            }
            return (Map<String, Object>) parsed;
        }
    }

    /** Thrown on Tooling API transport/HTTP failures. */
    public class NortToolingException extends Exception {}
}
