# nort — Agent & Inbound Setup

The deployable metadata covers the entire **code** loop (objects, config, ingestion, dedup, diagnosis orchestration, case mapping, the agent's org-reading actions) **and the Email Service function itself** (`EmailServicesFunction`). Two pieces still need finishing in Setup / Agent Builder after deploy:

1. The inbound **Email Address** on the deployed Email Service, plus routing Apex exception emails to it (the address carries an org-specific context user and a server-generated domain, so it isn't deployable — see §1).
2. The **Agentforce agent** (topic + grounded prompt) that the loop invokes headlessly.

This split is intentional: the Apex action surface and the service configuration (the genuinely reusable, testable, reproducible parts) are deployed; the org-specific inbound address and the agent are composed per org.

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

### Actions (assign these deployed Apex invocable actions)
| Action | Apex | Purpose |
|---|---|---|
| Read Apex Source | `NortApexSourceAction` | scoped class body + direct dependencies |
| Read Flow Metadata | `NortFlowMetadataAction` | reachable flow metadata (degrades gracefully) |
| Retrieve Knowledge | `NortKnowledgeRetrievalAction` | grounding articles (no-op if Knowledge off) |

These appear under the **Nort Error Remediation** category in Agent Builder (set via the `@InvocableMethod category`).

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

## MCP republication (later phase)

The three actions are authored as standard `@InvocableMethod` with `@InvocableVariable` I/O, so they can be republished as Apex-backed hosted MCP tools (Summer '26) for reuse by external agents without rework. Not required for the in-org loop.
