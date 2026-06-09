# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`nort` is a single-org Salesforce (SFDX, API v66.0 / Summer '26) loop that ingests runtime error notifications, deduplicates them to unique fingerprints, has an Agentforce agent diagnose only the unique ones, and auto-creates/maps support cases — while keeping Agentforce credit spend bounded. Read `README.md` and `docs/AGENT_SETUP.md` before deep work.

## The one invariant that governs the whole design

**Dedup must fully resolve before any agent spend.** A storm of thousands of identical errors must cost exactly one agent invocation. Concretely:

- `NortDedupBatch` never invokes the agent. It only groups events, upserts signatures, and marks eligible ones `Queued`.
- Agent invocation happens **only** in `NortDiagnosisQueueable`, one signature per transaction (self-chaining), so spend == number of unique signatures, never event volume.
- `Error_Signature__c.Fingerprint_Hash__c` is a **unique, case-sensitive External Id**. Dedup is a literal `Database.upsert(sigs, Error_Signature__c.Fingerprint_Hash__c, ...)` — "diagnose at most once per fingerprint" is a DB guarantee, not bookkeeping.
- The `Agent_Invocation_Count__c` field is the spend ledger; `NortDedupBatchTest.shouldCollapseStormToUniqueSignatures_BeforeAnySpend` is the regression that protects this invariant. Don't break it.

If you ever find yourself calling `NortAgentInvoker` from the batch or from a per-event loop, stop — that defeats the entire point of the project.

## Control flow (requires reading several classes to see)

```
Email → NortErrorEmailHandler (thin; never parses business logic)
      → NortIngestionService.publish()  [parse · fingerprint · self-exclude · bulk user resolve · insert]
      → Error_Event__c (Status=Parsed)
NortHeartbeatScheduler (self-reschedules each fire at now+Window_Minutes__c)
      → NortDedupBatch  [group by fingerprint · upsert Error_Signature__c · mark Queued]
      → finish() dispatches ONCE → NortDiagnosisQueueable
      → drains Queued signatures 1/txn → NortAgentInvoker.diagnose() → NortCaseService.route()
      → Case (+ representative Error_Events advanced to Cased)
```

The Event lifecycle (`Status__c`) and Signature diagnosis lifecycle (`Diagnosis_Status__c`) are the state machine; their picklist API values live **only** in `NortConstants` — never hardcode these strings elsewhere.

## Key seams and conventions

- **Agent invocation seam:** `NortAgentInvoker.AgentforceClient.invokeAgent` is the single place that calls the live agent via the Invocable Action API. Its action-type/parameter-key constants are *runtime strings* (compile regardless) that must be verified against the org's published agent action. The `Client` interface is injectable via `NortAgentInvoker.setClient(...)` — all tests use a mock; never let a test hit the real agent.
- **Config:** all tunables come through `NortConfig` (reads `nort_Config__mdt` via `getInstance`/`getAll`, never SOQL; every getter has a hardcoded fallback). Tests inject `NortConfig.configOverride` / `NortConfig.exclusionOverride` (`@TestVisible`) rather than depending on deployed CMDT.
- **Self-exclusion loop guard:** there is no managed namespace, so nort's own classes are identified by the `Nort` class-name prefix via a `nort_Exclusion__mdt` rule (`ClassPrefix=Nort`). `NortConfig.isExcludedClass()` enforces it at ingestion so nort's own errors never re-enter the pipeline. **All nort Apex classes must keep the `Nort` prefix** or the loop guard silently stops protecting them.
- **Fingerprint normalization:** `NortFingerprint.normalizeMessage` strips volatile tokens in a deliberate order (IDs → URLs → emails → timestamps → quoted → numbers). Reordering changes hashes and fragments fingerprints — only change with intent. Line/column numbers are deliberately excluded from the key (they shift every deploy).
- **Layering:** handler = thin I/O only; `NortIngestionService` = the source-agnostic publish path (accepts a list, bulkified, so future feeds reuse it); diagnosis orchestration and case logic are separate services. Keep SOQL/DML bulkified and out of loops.

## Commands

No default org is configured; pass `-o <alias>` explicitly (e.g. `SDO`, the testing org, or a scratch alias).

```bash
# Deploy
sf project deploy start -o <alias>
sf project deploy start -o <alias> --dry-run            # validate only

# Permission set (grants AuthorApex so the agent can read ApexClass.Body)
sf org assign permset -n Nort_Error_Remediation -o <alias>

# Tests
sf apex run test -o <alias> -l RunLocalTests -c -r human          # all local + coverage
sf apex run test -o <alias> --class-names NortDedupBatchTest -r human
sf apex run test -o <alias> --tests NortDedupBatchTest.shouldCollapseStormToUniqueSignatures_BeforeAnySpend -r human

# Static analysis (no org needed; remediate high-severity before deploy)
sf code-analyzer run --workspace "force-app/main/default/classes" --view detail

# Start / stop the loop (anonymous Apex)
echo "NortHeartbeatScheduler.start();" | sf apex run -o <alias>
echo "NortHeartbeatScheduler.stop();"  | sf apex run -o <alias>

# Scratch org (Dev Hub: CoastalProd)
sf org create scratch -v CoastalProd -f config/project-scratch-def.json -a nort -d
```

## Analyzer expectations

The remaining ~88 Moderate / 167 Low code-analyzer findings are intentional and should not be "fixed": `MethodNamingConventions` flags the `should_When` test names (the prescribed convention), `EmptyStatementBlock` flags empty private constructors on utility classes, and `AvoidGlobalModifier` flags `NortErrorEmailHandler` (`global` is required to implement `Messaging.InboundEmailHandler`). Only High-severity findings must be zero.

## Phase-1 limitations to design around (not bugs)

- Managed-package Apex bodies read as `(hidden)`; source reading covers unmanaged code only.
- Triggering user is frequently absent from Apex exception emails — `null` is normal.
- Flow internal logic is unreachable via standard SOQL (`FlowDefinitionView` is metadata-only); `NortFlowMetadataAction` degrades to metadata + a note. Tooling API is a deferred phase.
- The Agentforce agent itself (topic + grounded prompt) and the Email Service are configured in Setup/Agent Builder, not deployed — see `docs/AGENT_SETUP.md`. Deployable metadata covers all the code, including the agent's org-reading actions.

## Open issues

- The org deploy currently fails with a server-side `UNKNOWN_EXCEPTION` (0 component errors) — see GitHub issue #1 for suspects and the subset-deploy isolation plan. Validation against a live org is still pending; the suite is analyzer-clean but unrun in an org.
