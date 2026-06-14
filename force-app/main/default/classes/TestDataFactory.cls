/**
 * Test data factory for the nort error remediation loop. Centralizes sample
 * notification bodies and staged-record construction so test setup never builds
 * records inline.
 */
@isTest
public class TestDataFactory {
    public static final String DEFAULT_EXCEPTION = 'System.NullPointerException';

    /**
     * Builds a realistic Apex exception email body.
     *
     * @param userId The triggering user id to embed (so resolution can match).
     * @param className The failing class.
     * @param methodName The failing method.
     * @param exceptionType The exception type.
     * @param message The exception message (may contain volatile tokens).
     * @return A formatted Apex exception email body.
     */
    public static String apexExceptionEmail(
        Id userId, String className, String methodName, String exceptionType, String message
    ) {
        return 'Apex script unhandled exception by user/organization/' + userId + '/00D30000000abcdEAA\n\n'
            + className + ': execution of an operation\n\n'
            + 'caused by: ' + exceptionType + ': ' + message + '\n\n'
            + 'Class.' + className + '.' + methodName + ': line 42, column 1\n'
            + 'Class.SomeCaller.run: line 10, column 1\n';
    }

    /**
     * Builds a realistic Flow fault email body.
     *
     * @param flowApiName The faulting flow API name.
     * @param element The faulting element API name.
     * @return A formatted Flow fault email body.
     */
    public static String flowFaultEmail(String flowApiName, String element) {
        return 'Error Occurred During Flow "' + flowApiName + '".\n\n'
            + 'An error occurred at element ' + element + ' (FlowRecordUpdate).\n'
            + 'This error occurred: System.DmlException: Update failed.\n\n'
            + 'Flow Details\n'
            + 'Flow API Name: ' + flowApiName + '\n'
            + 'Type: Autolaunched Flow\n';
    }

    /**
     * Builds N parsed Error Events sharing one fingerprint (un-inserted).
     *
     * @param fingerprint The shared fingerprint hash.
     * @param className The failing class name.
     * @param count How many events to build.
     * @return The built events.
     */
    public static List<Error_Event__c> buildParsedEvents(String fingerprint, String className, Integer count) {
        List<Error_Event__c> events = new List<Error_Event__c>();
        for (Integer i = 0; i < count; i++) {
            events.add(new Error_Event__c(
                Status__c = NortConstants.EVENT_PARSED,
                Source__c = NortConstants.SOURCE_APEX,
                Apex_Class__c = className,
                Apex_Method__c = 'doWork',
                Parsed_Exception_Type__c = DEFAULT_EXCEPTION,
                Message_Snippet__c = 'attempt to de-reference a null object',
                Fingerprint_Hash__c = fingerprint,
                Received_At__c = System.now()
            ));
        }
        return events;
    }

    /**
     * Returns a config record with sensible test defaults and an unlimited cap.
     *
     * @return An in-memory nort_Config__mdt for injection via NortConfig.configOverride.
     */
    public static nort_Config__mdt config() {
        return new nort_Config__mdt(
            Window_Minutes__c = 5,
            Snippet_Length__c = 200,
            Diagnosis_Cooldown_Hours__c = 24,
            Batch_Size__c = 2000,
            Volume_Cap__c = null,
            Agent_API_Name__c = 'Nort_Error_Diagnosis_Agent',
            Case_Queue_DeveloperName__c = 'Nort_Error_Triage',
            Case_RecordType_DeveloperName__c = 'Nort_Automated_Error',
            Tooling_Named_Credential__c = 'Nort_Tooling',
            Max_Analysis_Items__c = 8,
            Max_Item_Chars__c = 6000,
            Max_Total_Chars__c = 24000
        );
    }

    /**
     * Returns a single ClassPrefix exclusion rule for the given prefix.
     *
     * @param prefix The class-name prefix to exclude.
     * @return A one-element exclusion list for injection via NortConfig.exclusionOverride.
     */
    public static List<nort_Exclusion__mdt> exclusionForPrefix(String prefix) {
        return new List<nort_Exclusion__mdt>{
            new nort_Exclusion__mdt(Match_Value__c = prefix, Match_Type__c = 'ClassPrefix', Active__c = true)
        };
    }

    /**
     * In-memory NortCaseService.CaseGateway for tests: captures Case/CaseComment
     * writes and serves seeded existing cases, so tests never perform real Case
     * DML (which would fire the target org's Case automation). Inject via
     * NortCaseService.setGateway(...) and assert against the public capture lists.
     */
    public class CaseGatewayStub implements NortCaseService.CaseGateway {
        public Map<Id, Case> store = new Map<Id, Case>();
        public List<Case> insertedCases = new List<Case>();
        public List<CaseComment> insertedComments = new List<CaseComment>();
        public List<Error_Signature__c> updatedSignatures = new List<Error_Signature__c>();
        private Integer counter = 1;

        /**
         * Seeds an existing case in the given open/closed state.
         *
         * @param isClosed Whether the seeded case is closed.
         * @return The synthetic Id of the seeded case.
         */
        public Id seedExisting(Boolean isClosed) {
            Id caseId = nextCaseId();
            // IsClosed is non-writable; set it via JSON to simulate state.
            Case existing = (Case) JSON.deserialize(
                '{"attributes":{"type":"Case"},"Id":"' + caseId + '","IsClosed":' + isClosed + '}',
                Case.class
            );
            store.put(caseId, existing);
            return caseId;
        }

        public Map<Id, Case> findCasesByIds(Set<Id> caseIds) {
            Map<Id, Case> found = new Map<Id, Case>();
            for (Id caseId : caseIds) {
                if (store.containsKey(caseId)) {
                    found.put(caseId, store.get(caseId));
                }
            }
            return found;
        }

        public void insertCases(List<Case> cases) {
            for (Case record : cases) {
                record.Id = nextCaseId();
                store.put(record.Id, record);
                insertedCases.add(record);
            }
        }

        public void insertComments(List<CaseComment> comments) {
            insertedComments.addAll(comments);
        }

        public void updateSignatures(List<Error_Signature__c> signatures) {
            updatedSignatures.addAll(signatures);
        }

        private Id nextCaseId() {
            String suffix = String.valueOf(counter++);
            String body = '0'.repeat(12 - suffix.length()) + suffix;
            return Id.valueOf(Case.SObjectType.getDescribe().getKeyPrefix() + body);
        }
    }
}
