/**
 * Agentforce action: reads Apex source for the failing class plus its direct
 * dependencies, scoped deliberately so org-wide source is never dumped into the
 * agent's context (token/credit/context-limit discipline).
 *
 * Dependencies are inferred by matching PascalCase identifiers in the target's
 * body against the names of classes that actually exist in the org, capped to a
 * small set. Managed-package bodies read as "(hidden)" and are surfaced as-is.
 *
 * Authored with @InvocableVariable I/O so it can be republished as an
 * Apex-backed MCP tool in a later phase without rework.
 */
public with sharing class NortApexSourceAction {
    private static final Integer DEPENDENCY_CAP = 5;
    private static final Integer MAX_BODY_CHARS = 20000;

    /** Input: the class whose source (and direct dependencies) to retrieve. */
    public class Request {
        @InvocableVariable(label='Apex Class Name' description='The failing Apex class to read.' required=true)
        public String className;
    }

    /** Output: the scoped source for the target and its direct dependencies. */
    public class Response {
        @InvocableVariable(label='Success')
        public Boolean isSuccess = false;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Error Type')
        public String errorType;
        @InvocableVariable(label='Class Name')
        public String className;
        @InvocableVariable(label='Source')
        public String source;
        @InvocableVariable(label='Dependency Class Names')
        public List<String> dependencyNames = new List<String>();
    }

    /**
     * Reads scoped Apex source for each requested class.
     *
     * @param requests The classes to read (bulk-safe).
     * @return One Response per Request, in order.
     */
    @InvocableMethod(
        label='Nort: Read Apex Source'
        description='Returns the source of a failing Apex class and its direct dependencies, scoped to avoid dumping org-wide code.'
        category='Nort Error Remediation'
    )
    public static List<Response> readSource(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }

        Set<String> targetNames = new Set<String>();
        for (Request request : requests) {
            if (request != null && String.isNotBlank(request.className)) {
                targetNames.add(request.className.trim());
            }
        }

        Map<String, String> bodyByName = queryBodies(targetNames);
        Set<String> allClassNames = allUnmanagedClassNames();

        // First pass: resolve dependency names per target from the target body.
        Map<String, List<String>> depsByTarget = new Map<String, List<String>>();
        Set<String> dependencyNames = new Set<String>();
        for (String name : targetNames) {
            List<String> deps = inferDependencies(bodyByName.get(name), name, allClassNames);
            depsByTarget.put(name, deps);
            dependencyNames.addAll(deps);
        }
        Map<String, String> dependencyBodies = queryBodies(dependencyNames);

        for (Request request : requests) {
            responses.add(buildResponse(request, bodyByName, depsByTarget, dependencyBodies));
        }
        return responses;
    }

    private static Response buildResponse(
        Request request,
        Map<String, String> bodyByName,
        Map<String, List<String>> depsByTarget,
        Map<String, String> dependencyBodies
    ) {
        Response response = new Response();
        if (request == null || String.isBlank(request.className)) {
            response.errorMessage = 'No class name provided.';
            response.errorType = 'IllegalArgument';
            return response;
        }
        String name = request.className.trim();
        response.className = name;

        if (!bodyByName.containsKey(name)) {
            response.errorMessage = 'Apex class "' + name + '" not found or not readable (managed/inaccessible).';
            response.errorType = 'NotFound';
            return response;
        }

        List<String> parts = new List<String>();
        parts.add('// ===== ' + name + ' =====');
        parts.add(bodyByName.get(name));
        for (String dependency : depsByTarget.get(name)) {
            if (dependencyBodies.containsKey(dependency)) {
                response.dependencyNames.add(dependency);
                parts.add('\n// ===== ' + dependency + ' (dependency) =====');
                parts.add(dependencyBodies.get(dependency));
            }
        }
        String combined = String.join(parts, '\n');
        response.source = combined.length() > MAX_BODY_CHARS ? combined.substring(0, MAX_BODY_CHARS) : combined;
        response.isSuccess = true;
        return response;
    }

    private static Map<String, String> queryBodies(Set<String> names) {
        Map<String, String> bodyByName = new Map<String, String>();
        if (names == null || names.isEmpty()) {
            return bodyByName;
        }
        for (ApexClass cls : [
            SELECT Name, Body FROM ApexClass WHERE Name IN :names WITH SYSTEM_MODE
        ]) {
            bodyByName.put(cls.Name, cls.Body);
        }
        return bodyByName;
    }

    private static Set<String> allUnmanagedClassNames() {
        Set<String> names = new Set<String>();
        for (ApexClass cls : [
            SELECT Name FROM ApexClass WHERE NamespacePrefix = null WITH SYSTEM_MODE
        ]) {
            names.add(cls.Name);
        }
        return names;
    }

    /**
     * Infers direct dependencies: PascalCase identifiers in the body that match
     * the name of an existing class, excluding self, capped to a small set.
     */
    private static List<String> inferDependencies(String body, String selfName, Set<String> existingClassNames) {
        List<String> dependencies = new List<String>();
        if (String.isBlank(body)) {
            return dependencies;
        }
        Set<String> seen = new Set<String>();
        Matcher matcher = Pattern.compile('\\b([A-Z][A-Za-z0-9_]{2,})\\b').matcher(body);
        while (matcher.find() && dependencies.size() < DEPENDENCY_CAP) {
            String candidate = matcher.group(1);
            if (candidate == selfName || seen.contains(candidate)) {
                continue;
            }
            seen.add(candidate);
            if (existingClassNames.contains(candidate)) {
                dependencies.add(candidate);
            }
        }
        return dependencies;
    }
}
