/**
 * Agentforce action: retrieves relevant knowledge articles to ground a
 * diagnosis. Uses dynamic SOQL so the class compiles even in orgs where
 * Salesforce Knowledge is not enabled (KnowledgeArticleVersion would otherwise
 * fail compilation), degrading to a clean no-op seam.
 *
 * Authored with @InvocableVariable I/O for later MCP republication.
 */
public with sharing class NortKnowledgeRetrievalAction {
    private static final Integer MAX_ARTICLES = 5;

    /** Input: free-text to search the knowledge base for. */
    public class Request {
        @InvocableVariable(label='Search Text' description='Text to search knowledge articles for.' required=true)
        public String searchText;
    }

    /** Output: matching article titles/snippets, or an empty list if unavailable. */
    public class Response {
        @InvocableVariable(label='Success')
        public Boolean isSuccess = false;
        @InvocableVariable(label='Error Message')
        public String errorMessage;
        @InvocableVariable(label='Error Type')
        public String errorType;
        @InvocableVariable(label='Article Titles')
        public List<String> articleTitles = new List<String>();
        @InvocableVariable(label='Knowledge Available')
        public Boolean knowledgeAvailable = false;
    }

    /**
     * Retrieves knowledge article titles matching each request's search text.
     *
     * @param requests The searches to run (bulk-safe).
     * @return One Response per Request, in order.
     */
    @InvocableMethod(
        label='Nort: Retrieve Knowledge'
        description='Returns relevant knowledge article titles to ground a diagnosis. No-op if Knowledge is not enabled.'
        category='Nort Error Remediation'
    )
    public static List<Response> retrieve(List<Request> requests) {
        List<Response> responses = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return responses;
        }
        for (Request request : requests) {
            responses.add(retrieveOne(request));
        }
        return responses;
    }

    private static Response retrieveOne(Request request) {
        Response response = new Response();
        if (request == null || String.isBlank(request.searchText)) {
            response.errorMessage = 'No search text provided.';
            response.errorType = 'IllegalArgument';
            return response;
        }
        try {
            String term = '%' + request.searchText.trim().left(80) + '%';
            String soql =
                'SELECT Title FROM KnowledgeArticleVersion ' +
                'WHERE PublishStatus = \'Online\' AND Language = \'en_US\' AND Title LIKE :term ' +
                'WITH SYSTEM_MODE LIMIT ' + MAX_ARTICLES;
            for (SObject article : Database.queryWithBinds(soql, new Map<String, Object>{ 'term' => term }, AccessLevel.SYSTEM_MODE)) {
                response.articleTitles.add((String) article.get('Title'));
            }
            response.knowledgeAvailable = true;
            response.isSuccess = true;
        } catch (Exception e) {
            // Knowledge not enabled or not queryable: degrade to a no-op seam.
            response.knowledgeAvailable = false;
            response.isSuccess = true;
            response.errorMessage = 'Knowledge unavailable: ' + e.getTypeName();
        }
        return response;
    }
}
