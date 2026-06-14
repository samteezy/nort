# nort — Agent & Inbound Setup

The deployable metadata covers the entire **code** loop (objects, config, ingestion, dedup, diagnosis orchestration, case mapping, the agent's org-reading actions) **and the Email Service function itself** (`EmailServicesFunction`). Two pieces still need finishing in Setup / Agent Builder after deploy:

1. The inbound **Email Address** on the deployed Email Service, plus routing Apex exception emails to it (the address carries an org-specific context user and a server-generated domain, so it isn't deployable — see §1).
2. The **Agentforce agent** (topic + grounded prompt) that the loop invokes headlessly.

Plus, for the orchestrator/analysis design (see §5): the **`Nort_Error_Analysis` prompt template** (its body, Salesforce-default model, and Apex grounding-resource binding) and the **External Client App + Named/External Credential** that back the same-org Tooling API callouts.

This split is intentional: the Apex action surface and the service configuration (the genuinely reusable, testable, reproducible parts) are deployed; the org-specific inbound address, the agent, the prompt template, and the Tooling connection are composed per org.

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

Create an agent whose **API name matches** `nort_Config__mdt.Default.Agent_API_Name__c` (default `Nort_Error_Diagnosis_Agent`).

### Topic
**Name:** Error Diagnosis
**Scope:** Diagnose a single Salesforce runtime error using the org's own source and knowledge, then return a structured root cause and recommendation.

**Instructions (paste into the topic):**
> You diagnose one Salesforce runtime error at a time. You are given the failing Apex class/method (or flow API name and faulting element), the exception type, and a normalized error message. Use your actions to (1) read the failing Apex source scoped to the failing class and its direct dependencies, (2) read available flow metadata, and (3) retrieve relevant knowledge articles. Do not request org-wide source. Base your conclusion only on what the actions return. Respond with ONLY a JSON object: `{"rootCause": "...", "recommendation": "..."}`.

### Actions

The agent is an **orchestrator**: it decides which code/metadata is implicated and hands a token list to the analysis prompt template, which does the heavy retrieval + analysis. It still retrieves Knowledge directly.

| Action | Backed by | Purpose |
|---|---|---|
| Analyze Error | `Nort_Error_Analysis` prompt template (§5) | resolves the implicated code/metadata and returns the structured root-cause/recommendation |
| Retrieve Knowledge | `NortKnowledgeRetrievalAction` (Apex) | grounding articles (no-op if Knowledge off) |

Wire **Analyze Error** as a prompt-template action on the subagent with inputs `requestedItems` (newline-delimited `type:identifier` tokens — `apex:`/`flow:`/`field:`/`symboltable:`), `exceptionType`, and `messageTemplate`. The agent calls it **at most once**, calls Retrieve Knowledge separately, and composes the final JSON from both.

> `NortApexSourceAction` and `NortFlowMetadataAction` are **no longer direct agent actions** — their logic is now invoked internally by the prompt template's grounding (`NortAnalysisGroundingProvider`). The Apex stays deployed (and is still valid `@InvocableMethod` for later MCP republication); it is just not assigned to the agent. The `Retrieve Knowledge` action appears under the **Nort Error Remediation** category in Agent Builder (set via the `@InvocableMethod category`).

### Grounded prompt template (optional)
For tighter grounding, back the topic with a prompt template that merges the signature fields and the action outputs. The prompt above is sufficient for phase 1; a prompt template is a refinement, not a requirement.

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
2. **External Client App.** Setup → **External Client App Manager** → *New*. Enable OAuth; enable the **Client Credentials Flow**; set its **Run-As** user to the integration user; scopes `api` (+ `web`/`refresh_token` as needed). Note the consumer key/secret.
3. **External Credential.** The skeleton deploys as `externalCredentials/Nort_Tooling.externalCredential-meta.xml` (OAuth, Client Credentials, named principal `NortToolingPrincipal`). In Setup, finish the principal: supply the ECA's consumer key/secret as the authentication parameters. *(Verify the AuthProtocolVariant wiring against your org — the deployed file is the reproducible skeleton.)*
4. **Named Credential.** The skeleton deploys as `namedCredentials/Nort_Tooling.namedCredential-meta.xml` referencing the External Credential, with `generateAuthorizationHeader=true`. **Set its `Url` to this org's My Domain** (`https://<MyDomain>.my.salesforce.com`) — the source ships a placeholder. Its developer name must stay `Nort_Tooling` (or update `nort_Config__mdt.Default.Tooling_Named_Credential__c`).
5. **Principal access.** `Nort_Error_Remediation` already grants `externalCredentialPrincipalAccesses` for `Nort_Tooling - NortToolingPrincipal`; confirm the running/integration user holds the permission set.

**Verify:**
```bash
echo "System.debug(NortToolingClient.fetchFlowMetadata('Some_Flow_API_Name'));" | sf apex run -o <alias>
```
Expect a populated summary (or a clean `success=false` with a reason — the client degrades, never throws into the loop).

> **Spend discipline:** `NortAnalysisGroundingProvider` caps retrieval via `nort_Config__mdt` (`Max_Analysis_Items__c` — also the callout budget — `Max_Item_Chars__c`, `Max_Total_Chars__c`). Tune there, never in code.

## 6. Analysis prompt template

Create a **Flex prompt template** named `Nort_Error_Analysis` in Prompt Builder.

- **Inputs:** `requestedItems` (Text, required), `exceptionType` (Text), `messageTemplate` (Text).
- **Grounding:** add `NortAnalysisGroundingProvider` as an **Apex grounding resource** (it's deployed and registered via `@InvocableMethod(... callout=true)`). Map the template inputs to its `Request` variables of the same names; reference its `groundingContext` output as a merge field in the body. This is the single place that retrieves and bounds the code/metadata.
- **Body:** instruct the model to diagnose using ONLY the grounding context and respond with ONLY `{"rootCause": "...", "recommendation": "..."}`.
- **Model:** Salesforce default for now. (Per-template model selection is config — a stronger/BYO model, e.g. Claude via the Models API, can be swapped in later with no code change.)
- Publish it, then wire it as the **Analyze Error** agent action (§2).

**Must-verify-against-org for §§5–6:**
1. **Callouts in the prompt-template grounding context.** If grounding Apex cannot make outbound callouts in your org, use the **staged-record fallback**: add a normal `@InvocableMethod(callout=true)` agent action that runs the same `NortAnalysisGroundingProvider` retrieval *before* analysis, writes the bounded context to a Long Text field on `Error_Signature__c`, and have the template ground from that field (a DML-free SOQL read). The retrieval logic is unchanged — only the wiring moves.
2. The exact prompt-template-as-agent-action wiring and input mapping.
3. `genAiPromptTemplate` model-config deployability at API v66.0 (author in Prompt Builder if not deployable via SFDX).
4. The External Credential client-credentials parameter shape and the Named Credential `Url`.

## 7. Smoke test the orchestrator end to end

1. Stage a known `Error_Signature__c` (Apex or Flow) and mark it `Queued`.
2. Run `NortHeartbeatScheduler` / `NortDiagnosisQueueable` (or call `NortAgentInvoker.diagnose(...)`).
3. Confirm the agent requested a focused token list, the template returned `{rootCause, recommendation}`, and a Case routed via `NortCaseService`.

> **Spend ledger note:** the template adds a second (analysis) model call inside each orchestrator invocation. `Agent_Invocation_Count__c` still counts orchestrator invocations (one per unique signature — the dedup-before-spend invariant is intact) but no longer equals total credit/token spend.

## MCP republication (later phase)

The three actions are authored as standard `@InvocableMethod` with `@InvocableVariable` I/O, so they can be republished as Apex-backed hosted MCP tools (Summer '26) for reuse by external agents without rework. Not required for the in-org loop.
