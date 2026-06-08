/**
 * Agentforce action: reads available flow metadata for a faulting flow.
 *
 * Phase-1 limitation by design: standard SOQL exposes only flow metadata
 * (FlowDefinitionView) — API name, label, type, status — never internal
 * elements or logic. This action returns what is reachable and always includes
 * a degradation note so the agent grounds honestly. Deeper flow logic awaits a
 * Tooling API phase.
 *
 * Authored with @InvocableVariable I/O for later MCP republication.
 */
public with sharing class NortFlowMetadataAction {
    private static final String DEGRADE_NOTE =
        'Flow internal logic is not available via standard SOQL in phase 1; only flow-level metadata is returned.';

    /** Input: the API name of the faulting flow. */
    public class Request {
        @InvocableVariable(label='Flow API Name' description='The API name of the faulting flow.' required=true)
        public String flowApiName;
    }

    /** Output: reachable flow metadata plus a degradation note. */
    public class Response {
        @InvocableVariable(label='Success')
        public Boolean isSuccess = false;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Error Type')
        public String errorType;
        @InvocableVariable(label='Flow API Name')
        public String flowApiName;
        @InvocableVariable(label='Label')
        public String label;
        @InvocableVariable(label='Process Type')
        public String processType;
        @InvocableVariable(label='Trigger Type')
        public String triggerType;
        @InvocableVariable(label='Is Active')
        public Boolean isActive;
        @InvocableVariable(label='Note')
        public String note = DEGRADE_NOTE;
    }

    /**
     * Reads flow metadata for each requested flow API name.
     *
     * @param requests The flow API names to look up (bulk-safe).
     * @return One Response per Request, in order.
     */
    @InvocableMethod(
        label='Nort: Read Flow Metadata'
        description='Returns reachable flow-level metadata (name, label, type, status). Internal flow logic is not available via standard SOQL.'
        category='Nort Error Remediation'
    )
    public static List<Response> readFlowMetadata(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<String> apiNames = new Set<String>();
        for (Request request : requests) {
            if (request != null && String.isNotBlank(request.flowApiName)) {
                apiNames.add(request.flowApiName.trim());
            }
        }

        Map<String, FlowDefinitionView> viewByApiName = new Map<String, FlowDefinitionView>();
        for (FlowDefinitionView view : [
            SELECT ApiName, Label, ProcessType, TriggerType, IsActive
            FROM FlowDefinitionView
            WHERE ApiName IN :apiNames
            WITH SYSTEM_MODE
        ]) {
            viewByApiName.put(view.ApiName, view);
        }

        for (Request request : requests) {
            responses.add(buildResponse(request, viewByApiName));
        }
        return responses;
    }

    private static Response buildResponse(Request request, Map<String, FlowDefinitionView> viewByApiName) {
        Response response = new Response();
        if (request == null || String.isBlank(request.flowApiName)) {
            response.errorMessage = 'No flow API name provided.';
            response.errorType = 'IllegalArgument';
            return response;
        }
        String apiName = request.flowApiName.trim();
        response.flowApiName = apiName;

        FlowDefinitionView view = viewByApiName.get(apiName);
        if (view == null) {
            response.errorMessage = 'Flow "' + apiName + '" not found or not visible via standard SOQL.';
            response.errorType = 'NotFound';
            return response;
        }
        response.label = view.Label;
        response.processType = view.ProcessType;
        response.triggerType = view.TriggerType;
        response.isActive = view.IsActive;
        response.isSuccess = true;
        return response;
    }
}
