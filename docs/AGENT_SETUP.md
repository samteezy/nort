# nort — Agent & Inbound Setup

The deployable metadata covers the entire **code** loop (objects, config, ingestion, dedup, diagnosis orchestration, case mapping, and the agent's org-reading actions). Two pieces are environment configuration completed in Setup / Agent Builder after deploy:

1. The **Email Service** that routes Apex exception emails to the handler.
2. The **Agentforce agent** (topic + grounded prompt) that the loop invokes headlessly.

This split is intentional: the Apex action surface (the genuinely reusable, testable code) is deployed and tested; the agent itself is composed in Agent Builder / Agent Script and tuned per org.

---

## 1. Email Service

1. **Setup → Email Services → New Email Service.**
   - Apex class: `NortErrorEmailHandler`
   - Accept attachments: None needed; accept from any sender (or restrict to your org's outbound exception-email sender).
2. Add an **inbound email address** (e.g. `nort-errors@<random>.apex.salesforce.com`).
3. Route Apex exception emails to it:
   - **Setup → Apex Exception Email** can notify users; forward those to the inbound address, **or**
   - Set the inbound address directly as a recipient where your org collects exception emails.

The handler is a thin publisher — it stages a `Error_Event__c` and returns success. It never invokes the agent.

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
