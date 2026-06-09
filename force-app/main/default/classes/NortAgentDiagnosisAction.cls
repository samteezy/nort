/**
 * Flow-callable entry point to the Nort Error Diagnosis agent. A thin
 * @InvocableMethod pass-through to NortAgentInvoker.diagnose so a Flow (or any
 * declarative caller) can invoke the agent headlessly for a SINGLE,
 * already-deduplicated error signature and read back the root cause and
 * recommendation.
 *
 * This action does NOT deduplicate, persist, or maintain the spend ledger /
 * status lifecycle — that bookkeeping stays in NortDiagnosisQueueable for the
 * production path. Callers must trigger this per unique Error_Signature__c only,
 * never per Error_Event__c, or they break the dedup-before-spend invariant.
 *
 * Authored with @InvocableVariable I/O to mirror the other Nort actions; keeps
 * the Nort prefix so the self-exclusion loop guard still covers it.
 */
public with sharing class NortAgentDiagnosisAction {

    /** Input: the diagnostic fields of one error signature (mirrors NortAgentInvoker.DiagnosisRequest). */
    public class Request {
        @InvocableVariable(label='Signature Id' description='Id of the Error_Signature__c being diagnosed (optional; for traceability).')
        public Id signatureId;
        @InvocableVariable(label='Source' description='Error source, e.g. Apex or Flow.')
        public String source;
        @InvocableVariable(label='Apex Class Name' description='The failing Apex class.')
        public String className;
        @InvocableVariable(label='Apex Method Name' description='The failing Apex method.')
        public String methodName;
        @InvocableVariable(label='Exception Type' description='The exception type, e.g. System.NullPointerException.')
        public String exceptionType;
        @InvocableVariable(label='Message Template' description='The normalized error message.')
        public String messageTemplate;
        @InvocableVariable(label='Flow API Name' description='The faulting flow API name, when the source is a Flow.')
        public String flowApiName;
        @InvocableVariable(label='Faulting Element' description='The faulting flow element, when the source is a Flow.')
        public String faultingElement;
    }

    /** Output: the agent's diagnosis (mirrors NortAgentInvoker.DiagnosisResult). */
    public class Response {
        @InvocableVariable(label='Success')
        public Boolean isSuccess = false;
        @InvocableVariable(label='Root Cause')
        public String rootCause;
        @InvocableVariable(label='Recommendation')
        public String recommendation;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    /**
     * Diagnoses each requested error signature via the agent.
     *
     * @param requests One signature's diagnostic fields per row (bulk-safe).
     * @return One Response per Request, in order.
     */
    @InvocableMethod(
        label='Nort: Diagnose Error'
        description='Invokes the Nort Error Diagnosis agent for ONE already-deduplicated error signature and returns root cause and recommendation. Trigger per unique Error_Signature__c only — never per Error_Event__c (that breaks dedup-before-spend). For Flow/declarative orchestration; not an agent tool.'
        category='Nort Error Remediation'
    )
    public static List<Response> diagnose(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        for (Request request : requests) {
            responses.add(toResponse(NortAgentInvoker.diagnose(toInvokerRequest(request))));
        }
        return responses;
    }

    private static NortAgentInvoker.DiagnosisRequest toInvokerRequest(Request request) {
        NortAgentInvoker.DiagnosisRequest invokerRequest = new NortAgentInvoker.DiagnosisRequest();
        if (request == null) {
            return invokerRequest;
        }
        invokerRequest.signatureId = request.signatureId;
        invokerRequest.source = request.source;
        invokerRequest.className = request.className;
        invokerRequest.methodName = request.methodName;
        invokerRequest.exceptionType = request.exceptionType;
        invokerRequest.messageTemplate = request.messageTemplate;
        invokerRequest.flowApiName = request.flowApiName;
        invokerRequest.faultingElement = request.faultingElement;
        return invokerRequest;
    }

    private static Response toResponse(NortAgentInvoker.DiagnosisResult result) {
        Response response = new Response();
        if (result == null) {
            response.errorMessage = 'Diagnosis returned no result.';
            return response;
        }
        response.isSuccess = result.success;
        response.rootCause = result.rootCause;
        response.recommendation = result.recommendation;
        response.errorMessage = result.errorMessage;
        return response;
    }
}
