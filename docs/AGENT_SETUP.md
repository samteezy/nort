# nort — Agent & Inbound Setup

The deployable metadata covers the entire **code** loop (objects, config, ingestion, dedup, diagnosis orchestration, case mapping, the org-reading actions), **the Email Service function itself** (`EmailServicesFunction`), the **`Nort_Error_Research` prompt template** + its `nortEvidence` output schema, the **`Nort_Tooling` External + Named Credential** skeletons, **and the `Nort_Error_Diagnosis_Agent` Agent Script bundle** (`aiAuthoringBundles/`). What still needs finishing in Setup / Agent Builder after deploy:

1. The inbound **Email Address** on the deployed Email Service, plus routing Apex exception emails to it (the address carries an org-specific context user and a server-generated domain, so it isn't deployable — see §1).
2. **Publishing/activating** the deployed agent (its topic, subagent, and action wiring all ship in source — see §2).
3. The per-org **secrets/URLs** the credential skeletons hold: the **External Client App** + its consumer key/secret, the Named Credential's My Domain `Url`, the External Credential's token-endpoint `AuthProviderUrl`, and the one **principal-access grant** on the permission set (the principal only exists once its secret is configured — see §5).

This split is intentional: the Apex action surface, the prompt template + schema, the agent bundle, the credential structure, and the service configuration (the genuinely reusable, testable, reproducible parts) are deployed; the org-specific inbound address, the agent's publish/activate step, and the per-org secrets are composed per org.

---

## 1. Email Service

The Email Service **function** deploys as metadata
(`force-app/main/default/emailservices/Nort_Error_Ingestion.xml-meta.xml` →
`EmailServicesFunction`): it binds the `NortErrorEmailHandler` Apex class, sets
`Accept Attachments: None`, and sets every failure response (Authentication /
Authorization / Over Email Rate Limit / Inactive) to **Discard** — the handler always
returns success, so bounce/retry storms must never feed back into the org. After
`sf project deploy start` the service exists and is Active; confirm with:

```bash
sf data query -o <alias> -q "SELECT FunctionName, IsActive, ApexClassId FROM EmailServicesFunction WHERE FunctionName='Nort_Error_Ingestion'"
```

Only the inbound **address** is manual — its `runAsUser` (context user) is org-specific
and its full domain is server-generated, so it can't live in source:

1. **Add an inbound address.** Setup → quick-find **Email Services** → open **Nort Error Ingestion** → *Email Addresses* related list → *New Email Address*.
   - Local part: `nort-errors`; Active: ✓
   - **Context User:** an active, licensed user whose permissions run the handler — an admin, or a user with the `Nort_Error_Remediation` permission set. (Ingestion stages `Error_Event__c` in `AccessLevel.SYSTEM_MODE`, but the context user must still be active.)
   - Accept Email From: blank to accept any sender (or restrict to your org's outbound exception-email sender).
   - Save and **copy the generated address** (`nort-errors@<random>.<region>.apex.salesforce.com`).
2. **Route Apex exception emails to it.** Setup → quick-find **Apex Exception Email** → add the generated address as a recipient (it fires on *unhandled* Apex exceptions, which is what the parser expects), **or** set the inbound address directly as a recipient wherever your org collects exception emails.

The handler is a thin publisher — it stages a `Error_Event__c` and returns success. It never invokes the agent.

**Verify end to end:** send a test message to the address (trigger a real unhandled exception, or just send a plain email — the parser stages an event even when it can't fully parse), then confirm it landed:

```bash
sf data query -o <alias> -q "SELECT Id, Status__c, Subject__c, CreatedDate FROM Error_Event__c ORDER BY CreatedDate DESC LIMIT 5"
```

Expect a new row with `Status__c = Parsed`. An exception thrown by a `Nort`-prefixed class should **not** create an event (self-exclusion loop guard via `nort_Exclusion__mdt`).

---

## 2. Agentforce agent

The agent **deploys as source** — an Agent Script `AiAuthoringBundle` at
`force-app/main/default/aiAuthoringBundles/Nort_Error_Diagnosis_Agent/` (its
`developer_name` matches `nort_Config__mdt.Default.Agent_API_Name__c`, default
`Nort_Error_Diagnosis_Agent`). The system prompt, the `error_diagnosis` subagent,
all action wiring, and the self-imposed spend guards are all in the `.agent` file —
**no manual Agent Builder authoring.** After deploy, just **publish + activate** it
(in Agent Builder — see the [memory note](../README.md) on not using `sf agent` CLI
commands from this environment).

### Shape: iterative orchestrator

The agent **never reads source itself**. It decides which code/metadata is implicated, hands a focused token list to the research prompt template, reasons over what comes back, and **loops** with refined tokens until it is confident or its budget is spent — then composes the final answer. The `error_diagnosis` subagent's instructions encode the rounds: hypothesize tokens → (optionally verify a record/field exists) → gather evidence → consult docs → reassess → compose, quoting the implicated code/metadata **verbatim**.

| Action | Backed by | Purpose | Budget guard |
|---|---|---|---|
| `analyze_error` | `Nort_Error_Research` prompt template (§6) | resolves the implicated code/metadata into one bounded context and returns a focused **research** result (`findings` / `likelyCause` / `suggestedNextItems`) — a step, not a verdict | `Analysis_Count < 10` |
| `AnswerQuestionsWithSalesforceDocumentation` | standard action | platform feature/limit/config questions | `Knowledge_Count < 5` |
| `QueryRecords` / `QueryRecordsWithAggregate` | standard actions | confirm a record/object/field exists or inspect data values before spending an analysis call | — |

`analyze_error` targets `prompt://Nort_Error_Research` with inputs `"Input:requestedItems"` (newline-delimited `type:identifier` tokens — `apex:`/`flow:`/`field:`/`symboltable:`), `"Input:exceptionType"`, `"Input:messageTemplate"`, and the `promptResponse` output. The agent calls it **repeatedly across rounds** (each round a *new* focused set, not a repeat), composing the final `{"rootCause", "recommendation"}` from all the evidence.

> `NortApexSourceAction` and `NortFlowMetadataAction` are **not** agent actions — their logic is invoked internally by the prompt template's grounding (`NortAnalysisGroundingProvider`). They stay deployed (valid `@InvocableMethod` for later MCP republication), just unassigned to the agent. `NortKnowledgeRetrievalAction` (org Knowledge articles) is likewise deployed but **not currently wired** — the agent uses the standard `AnswerQuestionsWithSalesforceDocumentation` action for platform questions; the Apex seam remains available (and is a clean no-op if Knowledge is off) for a later wiring or MCP republication.

---

## 3. Verify the invocation seam

`NortAgentInvoker.AgentforceClient.invokeAgent` calls the agent via the **Invocable Action API**. Its action type string (`generateAiAgentResponse`) and parameter keys (`agentApiName`, `userMessage`, `agentResponse`) are runtime values — confirm them against the action your org exposes for headless agent invocation in Summer '26, and adjust the four constants at the top of `AgentforceClient` if they differ. This is the only code that needs org-specific verification.

To smoke-test end to end without an agent, inject a stub:
```apex
NortAgentInvoker.setClient(new YourStubClient()); // implements NortAgentInvoker.Client
```

---

## 4. Start the loop

```apex
NortHeartbeatScheduler.start();   // schedules the first heartbeat one window from now
```
Stop it with `NortHeartbeatScheduler.stop();`. Retune cadence by editing `nort_Config__mdt.Default.Window_Minutes__c` — the next cycle adopts it.

---

## 5. Tooling API connection (same-org callout)

`NortToolingClient` reads org internals SOQL can't — flow logic (decisions/assignments/fault paths), Apex symbol tables, field definitions — by calling the org's **own** Tooling API through a Named Credential: `callout:Nort_Tooling/services/data/v66.0/tooling/...`. The code is deployed; the connection is composed per org because it carries org-specific secrets and the My Domain URL.

**2026 best practice:** authenticate with an **External Client App** (Connected Apps are restricted as of Sept 2025) using the **OAuth 2.0 Client Credentials** flow, run as a dedicated integration user.

1. **Integration user.** Pick/create an active user and assign `Nort_Error_Remediation` (it grants `ApiEnabled` + `AuthorApex`/`ViewSetup`, so callouts have the same metadata-read rights the loop uses).
2. **External Client App.** Setup → **External Client App Manager** → *New*. Enable OAuth; scopes `api` (+ `web` as needed — client credentials never issues a refresh token). **Callback URL:** the form requires one even though the Client Credentials flow never redirects — enter any valid HTTPS URL, e.g. `https://<MyDomain>.my.salesforce.com/services/oauth2/callback` (or `https://login.salesforce.com/services/oauth2/callback`); it is never invoked. Then enable the **Client Credentials Flow** and set its **Run-As** user to the integration user (step 1). Note the consumer key/secret.
3. **External Credential.** Deploys as valid metadata: `externalCredentials/Nort_Tooling.externalCredential-meta.xml` — OAuth, `AuthProtocolVariant=ClientCredentialsClientSecret`, named principal `NortToolingPrincipal`. Two values in it are placeholders to finish in Setup: the **`AuthProviderUrl`** (set it to `https://<MyDomain>.my.salesforce.com/services/oauth2/token`) and the **principal's consumer key/secret** (supply the ECA's, as the named principal's authentication parameters). The principal record only comes into existence once that secret is saved.
4. **Named Credential.** Deploys as `namedCredentials/Nort_Tooling.namedCredential-meta.xml` referencing the External Credential via `parameterType=Authentication`, with `generateAuthorizationHeader=true`. **Set its `Url` to this org's My Domain** (`https://<MyDomain>.my.salesforce.com`) — the source ships a placeholder. Its developer name must stay `Nort_Tooling` (or update `nort_Config__mdt.Default.Tooling_Named_Credential__c`).
5. **Principal access (manual).** Once the principal's secret is saved (step 3), grant the running/integration user access to it: Setup → the `Nort_Error_Remediation` permission set → **External Credential Principal Access** → enable `Nort_Tooling - NortToolingPrincipal`. (This grant is *not* in the deployed permission set — the principal doesn't exist until its secret is configured, so it can't deploy; the permission set carries the exact XML block to re-deploy instead, if you prefer.)

**Verify:**
```bash
echo "System.debug(NortToolingClient.fetchFlowMetadata('Some_Flow_API_Name'));" | sf apex run -o <alias>
```
Expect a populated summary (or a clean `success=false` with a reason — the client degrades, never throws into the loop).

> **Spend discipline:** `NortAnalysisGroundingProvider` caps retrieval via `nort_Config__mdt` (`Max_Analysis_Items__c` — also the callout budget — `Max_Item_Chars__c`, `Max_Total_Chars__c`). Tune there, never in code.

## 6. Research prompt template

The Flex prompt template **deploys as metadata**: `genAiPromptTemplates/Nort_Error_Research.genAiPromptTemplate-meta.xml`, with its structured-output schema at `lightningTypes/nortEvidence/schema.json`. No Prompt Builder authoring needed — it ships complete:

- **Inputs:** `requestedItems` (required), `exceptionType`, `messageTemplate` — `primitive://String`, named to match `NortAnalysisGroundingProvider.Request`.
- **Grounding:** a `templateDataProviders` block binds `apex://NortAnalysisGroundingProvider` (deployed, `@InvocableMethod(... callout=true)`), mapping each input to the provider's `Request` variable; the body references its output via `{!$Apex:NortAnalysisGroundingProvider.groundingContext}`. This is the single place that retrieves and bounds the code/metadata.
- **Body:** instructs the model to reason over ONLY the grounding context and return a focused **research** result, quoting offending code/metadata verbatim and attributing each quote. It is a research step the agent calls iteratively, **not** a final verdict.
- **Output:** structured JSON via the `nortEvidence` schema (`outputSchema`, `responseFormat=JSON`) — `findings`, `likelyCause`, and `suggestedNextItems` (further `type:identifier` tokens the context referenced but did not include).
- **Model:** `primaryModel` is `sfdc_ai__DefaultBedrockAnthropicClaude46Sonnet` (a Salesforce-managed default). Swap for a stronger/BYO model by editing `primaryModel` — no code change.

After deploy it appears in Prompt Builder as `Nort Error Research`. The agent's `analyze_error` action targets it directly in the deployed `.agent` bundle (§2) — no manual wiring; just publish + activate the agent.

**Must-verify-against-org for §§5–6:**
1. **Callouts in the prompt-template grounding context.** If grounding Apex cannot make outbound callouts in your org, use the **staged-record fallback**: add a normal `@InvocableMethod(callout=true)` agent action that runs the same `NortAnalysisGroundingProvider` retrieval *before* analysis, writes the bounded context to a Long Text field on `Error_Signature__c`, and have the template ground from that field (a DML-free SOQL read). The retrieval logic is unchanged — only the wiring moves.
2. The prompt-template-as-agent-action wiring (template, grounding, and the `.agent` bundle all deploy; confirm the binding survived **publish + activate** in your org).
3. The per-org secrets the deployed credential skeletons leave blank: the External Credential's `AuthProviderUrl` + consumer key/secret, the Named Credential's `Url`, and the principal-access grant (§5).

## 7. Smoke test the orchestrator end to end

1. Stage a known `Error_Signature__c` (Apex or Flow) and mark it `Queued`. (Or, on an already-diagnosed signature, check `Force_Reprocess__c` and save to re-run past the cooldown — `NortSignatureTrigger` requeues it and dispatches the drain chain.)
2. Run `NortHeartbeatScheduler` / `NortDiagnosisQueueable` (or call `NortAgentInvoker.diagnose(...)`, or invoke `NortAgentDiagnosisAction` from a Flow for one already-deduplicated signature).
3. Confirm the agent ran one or more focused `analyze_error` rounds, composed `{rootCause, recommendation}` (with verbatim code quotes), and a Case routed via `NortCaseService`.

> **Spend ledger note:** the agent now **iterates** — multiple `analyze_error` / doc / query calls per orchestrator invocation (capped by `Analysis_Count < 10` and `Knowledge_Count < 5`). `Agent_Invocation_Count__c` still counts orchestrator invocations (one per unique signature — the dedup-before-spend invariant is intact) but no longer equals total credit/token spend.

## MCP republication (later phase)

The nort org-reading actions are authored as standard `@InvocableMethod` with `@InvocableVariable` I/O, so they can be republished as Apex-backed hosted MCP tools (Summer '26) for reuse by external agents without rework. Not required for the in-org loop.
