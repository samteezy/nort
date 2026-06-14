/**
 * Apex grounding resource for the Nort_Error_Analysis prompt template.
 *
 * In the orchestrator design the agent decides WHICH code/metadata is implicated
 * and passes a bounded list of "type:identifier" descriptors; this provider is
 * the single retrieval seam that resolves them — Apex source, flow internals,
 * field definitions, Apex symbol tables — assembles ONE bounded context string,
 * and hands it back as the template's grounding merge field. The analysis model
 * then reasons over that context. Knowledge is deliberately NOT handled here: it
 * stays a direct agent action, outside code analysis.
 *
 * Spend discipline lives here, not in the agent: a global item cap (the primary
 * guardrail, which also bounds Tooling callouts), a per-item char cap, and a
 * total-context cap — all from NortConfig. Retrieval reuses the existing, tested
 * action logic (NortApexSourceAction / NortFlowMetadataAction) plus the generic
 * NortToolingClient; it never reimplements them.
 *
 * Read-only by contract: NO DML before the Tooling callouts (the prompt-template
 * grounding/callout ordering rule). The class performs no DML at all.
 */
public with sharing class NortAnalysisGroundingProvider {

    /** Input bound to the prompt template's variables. */
    public class Request {
        @InvocableVariable(label='Requested Items' description='Newline/comma-delimited type:identifier tokens (apex:, flow:, field:, symboltable:).' required=true)
        public String requestedItems;
        @InvocableVariable(label='Exception Type' description='The exception type, echoed into the context header.')
        public String exceptionType;
        @InvocableVariable(label='Normalized Message' description='The normalized error message, echoed into the context header.')
        public String messageTemplate;
    }

    /** Output: the single assembled grounding merge field. */
    public class Response {
        @InvocableVariable(label='Grounding Context')
        public String groundingContext;
    }

    /** A parsed descriptor token. */
    private class Item {
        String type;
        String identifier;
        String raw;
    }

    /**
     * Resolves the requested code/metadata items into one bounded grounding context.
     *
     * @param requests Bulk-safe list (the template invokes with a single request).
     * @return One Response per Request, in order.
     */
    @InvocableMethod(
        label='Nort: Build Analysis Grounding'
        description='Resolves requested code/metadata items (apex/flow/field/symboltable) into one bounded context for the analysis prompt template.'
        category='Nort Error Remediation'
        callout=true
    )
    public static List<Response> build(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            Response response = new Response();
            response.groundingContext = buildContext(request);
            responses.add(response);
        }
        return responses;
    }

    @TestVisible
    private static String buildContext(Request request) {
        Integer maxItems = NortConfig.maxAnalysisItems();
        Integer maxTotal = NortConfig.maxTotalChars();

        List<String> sections = new List<String>();
        List<String> notes = new List<String>();

        // Header so the model knows the error it is analyzing.
        if (request != null && (String.isNotBlank(request.exceptionType) || String.isNotBlank(request.messageTemplate))) {
            sections.add(
                '// ===== error context =====\n' +
                'exceptionType: ' + nullToEmpty(request?.exceptionType) + '\n' +
                'message: ' + nullToEmpty(request?.messageTemplate)
            );
        }

        List<Item> items = parse(request == null ? null : request.requestedItems, maxItems, notes);

        // Group by type so each retrieval helper runs once (bulkified, callout-frugal).
        Map<String, List<Item>> byType = new Map<String, List<Item>>();
        for (Item item : items) {
            if (!byType.containsKey(item.type)) {
                byType.put(item.type, new List<Item>());
            }
            byType.get(item.type).add(item);
        }

        sections.addAll(resolveApex(byType.get(NortConstants.ITEM_TYPE_APEX)));
        sections.addAll(resolveFlows(byType.get(NortConstants.ITEM_TYPE_FLOW)));
        sections.addAll(resolveFields(byType.get(NortConstants.ITEM_TYPE_FIELD)));
        sections.addAll(resolveSymbolTables(byType.get(NortConstants.ITEM_TYPE_SYMBOLTABLE)));

        if (!notes.isEmpty()) {
            sections.add('// ===== notes =====\n' + String.join(notes, '\n'));
        }
        if (sections.isEmpty()) {
            return 'No retrievable code/metadata items were requested.';
        }

        String assembled = String.join(sections, '\n\n');
        if (assembled.length() > maxTotal) {
            assembled = assembled.substring(0, maxTotal) + '\n…[context truncated]';
        }
        return assembled;
    }

    /**
     * Parses "type:identifier" tokens: splits on newline/comma, validates the type
     * against the allowlist (unknown types dropped with a note), dedups, and caps
     * to maxItems (extras dropped with a note).
     */
    @TestVisible
    private static List<Item> parse(String requestedItems, Integer maxItems, List<String> notes) {
        List<Item> items = new List<Item>();
        if (String.isBlank(requestedItems)) {
            return items;
        }
        Set<String> allowed = new Set<String>{
            NortConstants.ITEM_TYPE_APEX, NortConstants.ITEM_TYPE_FLOW,
            NortConstants.ITEM_TYPE_FIELD, NortConstants.ITEM_TYPE_SYMBOLTABLE
        };
        Set<String> seen = new Set<String>();
        for (String token : requestedItems.split('[\\r\\n,]+')) {
            String trimmed = token == null ? '' : token.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            Integer sep = trimmed.indexOf(NortConstants.ITEM_TYPE_SEPARATOR);
            if (sep <= 0 || sep == trimmed.length() - 1) {
                notes.add('skipped (malformed): ' + trimmed);
                continue;
            }
            String type = trimmed.substring(0, sep).trim().toLowerCase();
            String identifier = trimmed.substring(sep + 1).trim();
            if (!allowed.contains(type)) {
                notes.add('skipped (unknown type): ' + trimmed);
                continue;
            }
            String dedupKey = type + NortConstants.ITEM_TYPE_SEPARATOR + identifier;
            if (seen.contains(dedupKey)) {
                continue;
            }
            seen.add(dedupKey);
            if (items.size() >= maxItems) {
                notes.add('skipped (over max ' + maxItems + ' items): ' + trimmed);
                continue;
            }
            Item item = new Item();
            item.type = type;
            item.identifier = identifier;
            item.raw = trimmed;
            items.add(item);
        }
        return items;
    }

    /** Reuses NortApexSourceAction (SOQL, no callout) for scoped class source + deps. */
    private static List<String> resolveApex(List<Item> items) {
        List<String> sections = new List<String>();
        if (items == null || items.isEmpty()) {
            return sections;
        }
        List<NortApexSourceAction.Request> reqs = new List<NortApexSourceAction.Request>();
        for (Item item : items) {
            NortApexSourceAction.Request req = new NortApexSourceAction.Request();
            req.className = item.identifier;
            reqs.add(req);
        }
        List<NortApexSourceAction.Response> resps = NortApexSourceAction.readSource(reqs);
        for (Integer i = 0; i < items.size(); i++) {
            NortApexSourceAction.Response resp = resps[i];
            String body = resp.isSuccess ? resp.source : ('(' + nullToEmpty(resp.errorMessage) + ')');
            sections.add(header(items[i].raw) + cap(body));
        }
        return sections;
    }

    /** Combines SOQL flow metadata (NortFlowMetadataAction) with Tooling-retrieved internals. */
    private static List<String> resolveFlows(List<Item> items) {
        List<String> sections = new List<String>();
        if (items == null || items.isEmpty()) {
            return sections;
        }
        List<NortFlowMetadataAction.Request> reqs = new List<NortFlowMetadataAction.Request>();
        for (Item item : items) {
            NortFlowMetadataAction.Request req = new NortFlowMetadataAction.Request();
            req.flowApiName = item.identifier;
            reqs.add(req);
        }
        List<NortFlowMetadataAction.Response> metas = NortFlowMetadataAction.readFlowMetadata(reqs);
        for (Integer i = 0; i < items.size(); i++) {
            NortFlowMetadataAction.Response meta = metas[i];
            List<String> parts = new List<String>();
            if (meta.isSuccess) {
                parts.add('label: ' + nullToEmpty(meta.label) + ' | processType: ' + nullToEmpty(meta.processType) +
                    ' | triggerType: ' + nullToEmpty(meta.triggerType) + ' | active: ' + meta.isActive);
            } else {
                parts.add('metadata: (' + nullToEmpty(meta.errorMessage) + ')');
            }
            // Tooling internals — degrade per-item rather than failing the whole grounding.
            try {
                NortToolingClient.FlowMetadata internals = NortToolingClient.fetchFlowMetadata(items[i].identifier);
                parts.add(internals.success ? 'internal logic:\n' + internals.summary
                                            : 'internal logic unavailable: ' + nullToEmpty(internals.errorMessage));
            } catch (Exception e) {
                parts.add('internal logic unavailable: ' + e.getTypeName());
            }
            sections.add(header(items[i].raw) + cap(String.join(parts, '\n')));
        }
        return sections;
    }

    /** Resolves Object.Field descriptors via a Tooling FieldDefinition query. */
    private static List<String> resolveFields(List<Item> items) {
        List<String> sections = new List<String>();
        if (items == null || items.isEmpty()) {
            return sections;
        }
        for (Item item : items) {
            String body;
            try {
                List<String> parts = item.identifier.split('\\.');
                if (parts.size() != 2) {
                    body = '(expected Object.Field, got "' + item.identifier + '")';
                } else {
                    String soql =
                        'SELECT QualifiedApiName, DataType, Label, IsNillable FROM FieldDefinition ' +
                        'WHERE EntityDefinition.QualifiedApiName = \'' + escapeLiteral(parts[0].trim()) + '\' ' +
                        'AND QualifiedApiName = \'' + escapeLiteral(parts[1].trim()) + '\'';
                    List<Object> records = NortToolingClient.query(soql);
                    if (records.isEmpty()) {
                        body = '(field not found)';
                    } else {
                        Map<String, Object> rec = (Map<String, Object>) records[0];
                        body = 'dataType: ' + String.valueOf(rec.get('DataType')) +
                            ' | label: ' + String.valueOf(rec.get('Label')) +
                            ' | nillable: ' + String.valueOf(rec.get('IsNillable'));
                    }
                }
            } catch (Exception e) {
                body = 'unavailable: ' + e.getTypeName();
            }
            sections.add(header(item.raw) + cap(body));
        }
        return sections;
    }

    /** Retrieves Apex symbol tables (methods/inner classes) via a Tooling ApexClass query. */
    private static List<String> resolveSymbolTables(List<Item> items) {
        List<String> sections = new List<String>();
        if (items == null || items.isEmpty()) {
            return sections;
        }
        // SymbolTable supports bulk retrieval (unlike Flow.Metadata): one query for all names.
        Set<String> names = new Set<String>();
        for (Item item : items) {
            names.add(item.identifier);
        }
        Map<String, String> summaryByName = new Map<String, String>();
        try {
            List<String> quoted = new List<String>();
            for (String name : names) {
                quoted.add('\'' + escapeLiteral(name) + '\'');
            }
            String soql =
                'SELECT Name, SymbolTable FROM ApexClass ' +
                'WHERE NamespacePrefix = null AND Name IN (' + String.join(quoted, ',') + ')';
            for (Object record : NortToolingClient.query(soql)) {
                Map<String, Object> rec = (Map<String, Object>) record;
                summaryByName.put(String.valueOf(rec.get('Name')), summarizeSymbolTable(rec.get('SymbolTable')));
            }
        } catch (Exception e) {
            for (String name : names) {
                summaryByName.put(name, 'unavailable: ' + e.getTypeName());
            }
        }
        for (Item item : items) {
            String body = summaryByName.containsKey(item.identifier) ? summaryByName.get(item.identifier) : '(not found)';
            sections.add(header(item.raw) + cap(body));
        }
        return sections;
    }

    /** Condenses a SymbolTable into method and inner-class names. */
    @TestVisible
    private static String summarizeSymbolTable(Object symbolTable) {
        if (!(symbolTable instanceof Map<String, Object>)) {
            return '(no symbol table)';
        }
        Map<String, Object> table = (Map<String, Object>) symbolTable;
        List<String> lines = new List<String>();
        lines.add(namesFrom(table.get('methods'), 'methods'));
        lines.add(namesFrom(table.get('properties'), 'properties'));
        lines.add(namesFrom(table.get('innerClasses'), 'innerClasses'));
        lines.add(namesFrom(table.get('variables'), 'variables'));
        return String.join(lines, '\n');
    }

    private static String namesFrom(Object collection, String label) {
        if (!(collection instanceof List<Object>)) {
            return label + ': (none)';
        }
        List<String> names = new List<String>();
        for (Object element : (List<Object>) collection) {
            if (element instanceof Map<String, Object>) {
                Object name = ((Map<String, Object>) element).get('name');
                if (name != null) {
                    names.add(String.valueOf(name));
                }
            }
        }
        return label + ' [' + names.size() + ']: ' + String.join(names, ', ');
    }

    private static String header(String raw) {
        return '// ===== ' + raw + ' =====\n';
    }

    private static String cap(String body) {
        Integer max = NortConfig.maxItemChars();
        if (body == null) {
            return '';
        }
        return body.length() > max ? body.substring(0, max) + '\n…[item truncated]' : body;
    }

    private static String escapeLiteral(String value) {
        return value == null ? '' : value.replace('\'', '\\\'');
    }

    private static String nullToEmpty(String value) {
        return value == null ? '' : value;
    }
}
