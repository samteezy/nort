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
                                              │  NortAgentInvoker ─▶ Agentforce agent
                                              ▼
                                    NortCaseService  (create / comment / link)
                                              ▼
                                            Case
```

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

| Layer | Class |
|---|---|
| Fingerprint (pure) | `NortFingerprint` |
| Config + loop guard | `NortConfig`, `NortConstants` |
| Parse | `NortEmailParser` (Apex wired, Flow stubbed-but-tested) |
| Ingest (publisher) | `NortIngestionService`, `NortErrorEmailHandler` |
| Dedup gate | `NortDedupBatch` |
| Cadence | `NortHeartbeatScheduler` (self-rescheduling) |
| Diagnose | `NortDiagnosisQueueable` (self-chaining), `NortAgentInvoker` |
| Case | `NortCaseService` |
| Agent actions | `NortApexSourceAction`, `NortFlowMetadataAction`, `NortKnowledgeRetrievalAction` |

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

`nort_Exclusion__mdt` — the **self-exclusion loop guard** (prevents nort's own errors from feeding back). Ships with a `ClassPrefix = Nort` rule.

## Design decisions

- **Heartbeat:** self-rescheduling `Schedulable` (Salesforce has no native sub-hourly cron) — cadence read from CMDT each cycle.
- **Agent tools:** native `@InvocableMethod` actions (simplest for an in-org loop). Authored MCP-ready via `@InvocableVariable` I/O; MCP republication is a later seam.
- **Recurrence after close:** new case linked to the prior + cooldown suppression.
- **Storm guard:** dedup-only (dedup *is* the collapse); dormant `Volume_Cap__c` can be enabled later without code.

## Known phase-1 limitations (by design)

- Managed-package Apex bodies read as `(hidden)` — source reading covers unmanaged org code only.
- Triggering user is often absent from Apex exception emails — `null` is a normal outcome.
- Flow internal logic is not reachable via standard SOQL — flow internals (and Apex symbol tables, field definitions) are retrieved via the Tooling API (`NortToolingClient`, a same-org Named Credential callout) and assembled by `NortAnalysisGroundingProvider` for the analysis prompt template.
- Knowledge retrieval is a no-op seam if Knowledge isn't enabled.

## Setup

```bash
sf org create scratch -f config/project-scratch-def.json -a nort -d
sf project deploy start -o nort
sf org assign permset -n Nort_Error_Remediation -o nort
sf apex run test -o nort -l RunLocalTests -c -r human
# start the loop:
echo "NortHeartbeatScheduler.start();" | sf apex run -o nort
```

The deploy includes the Email Service (`EmailServicesFunction`), the `Nort_Error_Analysis` prompt template (with its Apex grounding binding), and the `Nort_Tooling` External + Named Credential. Wired by hand afterward: the org-specific inbound email address, the Agentforce agent, the External Client App + the per-org secrets/URLs its credentials hold, and the External-Credential principal-access grant — see [`docs/AGENT_SETUP.md`](docs/AGENT_SETUP.md).

## The credit-discipline proof

`NortDedupBatchTest.shouldCollapseStormToUniqueSignatures_BeforeAnySpend` inserts 300 events across 3 fingerprints and asserts exactly **3** signatures result, each scheduled for diagnosis at most once — and `NortDiagnosisQueueableTest` asserts exactly **one** agent invocation per signature. Together: total spend = unique signatures, never event volume.

## Agent invocation seam

`NortAgentInvoker.AgentforceClient.invokeAgent` is the single place that calls the Agentforce agent (via the Invocable Action API). Its action type and parameter keys are runtime strings — **verify them against your org's published agent action** before go-live. The client is injectable (`NortAgentInvoker.setClient`) for testing.
