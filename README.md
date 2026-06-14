# nort — Agentic Apex/Flow Error Remediation Loop

A self-contained Salesforce loop that ingests runtime error notifications, **deduplicates them to unique fingerprints**, lets an Agentforce agent diagnose only the unique ones (grounded against the org's own Apex source and knowledge), and auto-creates/maps support cases with a root cause and recommended fix — while keeping Agentforce credit consumption tightly bounded.

> Built for Salesforce **Summer '26** (API v66.0, Atlas Reasoning Engine 3.0, first-class MCP actions). SFDX source format. Single org. Packaging deferred.

## Why this exists

An uncontrolled error storm of thousands of exception emails must **never** translate into thousands of agent invocations (each standard Agentforce action costs real Flex Credits). The design's spine is a dedup gate that collapses volume to **one unique fingerprint** before any agent spend. A storm of 10,000 identical `NullPointerException`s becomes **one** diagnosis, one case.

## Pipeline

```
Apex exception email ─▶ Email Service ─▶ NortErrorEmailHandler (thin publisher)
                                              │  parse · fingerprint · self-exclude
                                              ▼
                                       Error_Event__c  (one row per occurrence)
                                              │
              NortHeartbeatScheduler ─▶ NortDedupBatch  (config-driven cadence)
                                              │  group by fingerprint · upsert signature
                                              ▼
                                    Error_Signature__c  (one row per unique fingerprint)
                                              │  finish() dispatches once
                                              ▼
                              NortDiagnosisQueueable  (self-chaining, 1 signature/txn)
                                              │  NortAgentInvoker ─▶ Agentforce agent  (orchestrator)
                                              │        ╰─ iterates: analyze_error ⇄ Nort_Error_Research template
                                              │           (NortAnalysisGroundingProvider + Tooling API) until
                                              │           confident or budget spent, + Salesforce-doc / record lookups
                                              ▼
                                    NortCaseService  (create / comment / link)
                                              ▼
                                            Case
```

An admin can also force a re-diagnosis on demand: checking `Force_Reprocess__c` on an
`Error_Signature__c` requeues it and kicks the drain chain (`NortSignatureTrigger` →
`NortSignatureReprocessHandler`), bypassing the cooldown — without ever invoking the agent
from the trigger.

## Data model

| Object | Grain | Role |
|---|---|---|
| `Error_Event__c` | one per inbound notification | source-agnostic staging / occurrence |
| `Error_Signature__c` | one per unique fingerprint | dedup spine, agent-spend ledger, case mapping, diagnosis output |

`Error_Signature__c.Fingerprint_Hash__c` is a **unique, case-sensitive External Id** — the dedup gate is a literal `upsert ... on Fingerprint_Hash__c`, so "diagnose at most once per unique fingerprint" is a database guarantee, not bookkeeping.

### Event lifecycle
`Received → Parsed → (Excluded | Duplicate | Representative) → Diagnosing → Diagnosed → Cased`
Off-ramps: `ParseError` (raw retained), `Failed`, `Deferred` (volume-cap overflow).

## Fingerprint normalization

Volatile tokens are stripped **before** hashing so near-identical errors don't fragment: Salesforce 15/18-char IDs → `{id}`, numbers (incl. line numbers, which shift every deploy) → `{n}`, quoted values → `'{s}'`, timestamps → `{ts}`, emails/URLs → `{email}`/`{url}`; whitespace collapsed; truncated to a configurable snippet length.

- **Apex key:** `apex | class | method | exceptionType | normalizedSnippet` (class/method from the innermost stack frame; **line/column discarded**)
- **Flow key:** `flow | flowApiName | faultingElement | normalizedText`
- **Hash:** SHA-256 → 64-char hex → Signature External Id

## Component map

| Layer | Class / metadata |
|---|---|
| Fingerprint (pure) | `NortFingerprint` |
| Config + loop guard | `NortConfig`, `NortConstants` |
| Parse | `NortEmailParser` (Apex wired, Flow stubbed-but-tested) |
| Ingest (publisher) | `NortIngestionService`, `NortErrorEmailHandler` |
| Dedup gate | `NortDedupBatch` |
| Cadence | `NortHeartbeatScheduler` (self-rescheduling) |
| Diagnose | `NortDiagnosisQueueable` (self-chaining), `NortAgentInvoker` |
| On-demand re-diagnose | `NortSignatureTrigger`, `NortSignatureReprocessHandler` (the `Force_Reprocess__c` action checkbox) |
| Flow-callable diagnose | `NortAgentDiagnosisAction` (`@InvocableMethod`; one already-deduped signature) |
| Case | `NortCaseService` |
| Agent (deployed bundle) | `Nort_Error_Diagnosis_Agent` (`aiAuthoringBundles/`, Agent Script orchestrator) |
| Research template | `Nort_Error_Research` (`genAiPromptTemplates/`) + `nortEvidence` output schema (`lightningTypes/`) |
| Analysis grounding | `NortAnalysisGroundingProvider` (template's Apex grounding), `NortToolingClient` (same-org Tooling callout) |
| Org-reading actions (template-internal) | `NortApexSourceAction`, `NortFlowMetadataAction` — invoked *by* the grounding provider, not assigned to the agent. `NortKnowledgeRetrievalAction` is a deployed MCP-ready seam, currently unwired (the agent uses the standard Salesforce-documentation action). |

## How the agent diagnoses (orchestrator + iterative research)

The agent is an **orchestrator that never reads source itself**. It decides *which* code/metadata is implicated, then loops:

1. **Hypothesize** — turn the failing class/method (or flow), exception type, and normalized message into a focused list of `type:identifier` tokens (`apex:` / `flow:` / `field:` / `symboltable:`) — never org-wide.
2. **Gather evidence** — call the `Nort_Error_Research` prompt template (`analyze_error`). Its Apex grounding (`NortAnalysisGroundingProvider`) resolves the tokens — Apex source via SOQL, flow internals / field definitions / Apex symbol tables via the Tooling API (`NortToolingClient`) — into ONE bounded context, and a dedicated model (Claude 4.6 Sonnet) returns structured `findings` / `likelyCause` / `suggestedNextItems` (the `nortEvidence` schema). The research template is a *research step, not a verdict*.
3. **Verify / consult** — optional standard actions: `QueryRecords` to confirm a record/object/field exists, `AnswerQuestionsWithSalesforceDocumentation` for platform questions.
4. **Reassess & loop** — if the evidence is incomplete and budget remains, refine the token set (using `suggestedNextItems`, named dependencies, a symbol table) and gather again with a *new* set.
5. **Compose** — from all rounds, emit `{"rootCause", "recommendation"}`, quoting the implicated code/metadata **verbatim** and attributed to its class/method (or flow element / field).

The agent caps its own spend with Agent Script variable guards (`Analysis_Count < 10`, `Knowledge_Count < 5`); the grounding provider caps retrieval/callouts via `nort_Config__mdt` (`Max_Analysis_Items__c`, `Max_Item_Chars__c`, `Max_Total_Chars__c`). Knowledge stays a *direct* agent action, deliberately outside the code-analysis grounding.

## Configuration (no code changes)

`nort_Config__mdt` (Default record) — all tunable in Setup:

| Field | Default | Purpose |
|---|---|---|
| `Window_Minutes__c` | 5 | heartbeat cadence |
| `Snippet_Length__c` | 200 | fingerprint message length |
| `Diagnosis_Cooldown_Hours__c` | 24 | suppress re-diagnosis of recurrences |
| `Volume_Cap__c` | *(blank = unlimited)* | dormant per-window spend cap (dedup-only by default) |
| `Batch_Size__c` | 200 | dedup batch scope |
| `Agent_API_Name__c` | `Nort_Error_Diagnosis_Agent` | which agent to invoke |
| `Case_Queue_DeveloperName__c` | `Nort_Error_Triage` | owner of auto-created cases |
| `Case_RecordType_DeveloperName__c` | `Nort_Automated_Error` | case record type |
| `Tooling_Named_Credential__c` | `Nort_Tooling` | Named Credential the Tooling callouts use |
| `Max_Analysis_Items__c` | 8 | items resolved per grounding call (also the Tooling callout budget — primary guardrail) |
| `Max_Item_Chars__c` | 20000 | chars retained per resolved item |
| `Max_Total_Chars__c` | 60000 | chars for the assembled grounding context |

`nort_Exclusion__mdt` — the **self-exclusion loop guard** (prevents nort's own errors from feeding back). Ships with a `ClassPrefix = Nort` rule.

## Design decisions

- **Heartbeat:** self-rescheduling `Schedulable` (Salesforce has no native sub-hourly cron) — cadence read from CMDT each cycle.
- **Agent shape:** an Agent Script orchestrator that delegates code reading to a grounded prompt template and reasons over the result in rounds, plus standard Salesforce doc/record actions. The nort Apex actions are authored MCP-ready via `@InvocableVariable` I/O; MCP republication is a later seam.
- **Recurrence after close:** new case linked to the prior + cooldown suppression. An admin can override the cooldown on demand via the `Force_Reprocess__c` checkbox.
- **Storm guard:** dedup-only (dedup *is* the collapse); dormant `Volume_Cap__c` can be enabled later without code.

## Known phase-1 limitations (by design)

- Managed-package Apex bodies read as `(hidden)` — source reading covers unmanaged org code only.
- Triggering user is often absent from Apex exception emails — `null` is a normal outcome.
- Flow internal logic is not reachable via standard SOQL — flow internals (and Apex symbol tables, field definitions) are retrieved via the Tooling API (`NortToolingClient`, a same-org Named Credential callout) and assembled by `NortAnalysisGroundingProvider` for the research prompt template.
- The deployed agent retrieves platform answers via the standard `AnswerQuestionsWithSalesforceDocumentation` action. `NortKnowledgeRetrievalAction` (org Knowledge articles) ships as a deployed, MCP-ready `@InvocableMethod` seam but is not currently wired into the agent; it degrades to a clean no-op if Knowledge isn't enabled.

## Setup

```bash
sf org create scratch -f config/project-scratch-def.json -a nort -d
sf project deploy start -o nort
sf org assign permset -n Nort_Error_Remediation -o nort
sf apex run test -o nort -l RunLocalTests -c -r human
# start the loop:
echo "NortHeartbeatScheduler.start();" | sf apex run -o nort
```

The deploy includes the Email Service (`EmailServicesFunction`), the `Nort_Error_Research` prompt template (with its Apex grounding binding) and its `nortEvidence` output schema, the `Nort_Tooling` External + Named Credential, and the `Nort_Error_Diagnosis_Agent` Agent Script bundle (`aiAuthoringBundles/`). Finished by hand afterward: **publishing/activating** the deployed agent, the org-specific inbound email address, the External Client App + the per-org secrets/URLs its credentials hold, and the External-Credential principal-access grant — see [`docs/AGENT_SETUP.md`](docs/AGENT_SETUP.md).

## The credit-discipline proof

`NortDedupBatchTest.shouldCollapseStormToUniqueSignatures_BeforeAnySpend` inserts 300 events across 3 fingerprints and asserts exactly **3** signatures result, each scheduled for diagnosis at most once — and `NortDiagnosisQueueableTest` asserts exactly **one** agent invocation per signature. Together: **agent invocations = unique signatures, never event volume.**

> Spend nuance: `Agent_Invocation_Count__c` counts *orchestrator* invocations (one per unique signature — the invariant). Because the agent now iterates internally (multiple `analyze_error` / doc / query calls per invocation), one invocation is no longer one model call. The agent's own `Analysis_Count < 10` / `Knowledge_Count < 5` guards and the grounding provider's `Max_*` caps bound that per-invocation work.

## Agent invocation seam

`NortAgentInvoker.AgentforceClient.invokeAgent` is the single place that calls the Agentforce agent (via the Invocable Action API). Its action type and parameter keys are runtime strings — **verify them against your org's published agent action** before go-live. The client is injectable (`NortAgentInvoker.setClient`) for testing, and the same `NortAgentInvoker.diagnose` path is reused by `NortAgentDiagnosisAction` so a Flow can headlessly diagnose one already-deduplicated signature.
