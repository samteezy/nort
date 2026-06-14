# Deploying an Agentforce agent via `sf` CLI — field-tested checklist

A portable, copy-paste checklist for building and deploying an Agentforce agent's
metadata with the `sf` CLI. Based on the Nort error-diagnosis agent. Assumes the
target org already has Agentforce / Agent Script enabled.

## 1. What the agent metadata actually is

An agent is an **AiAuthoringBundle**. Minimum two files, in this exact layout:

```
force-app/main/default/aiAuthoringBundles/<AgentApiName>/
├── <AgentApiName>.agent            # Agent Script source (system prompt, routing, subagents, actions)
└── <AgentApiName>.bundle-meta.xml  # bundle descriptor
```

`<AgentApiName>.bundle-meta.xml`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<AiAuthoringBundle xmlns="http://soap.sforce.com/2006/04/metadata">
  <bundleType>AGENT</bundleType>
</AiAuthoringBundle>
```

`<AgentApiName>.agent` (skeleton — Agent Script, not XML):

```
system:
    instructions: "<system prompt>"
    messages:
        welcome: "..."
        error: "..."

config:
    developer_name: "<AgentApiName>"        # MUST match the folder + file name
    agent_label: "<Human Label>"
    description: "..."
    agent_type: "AgentforceEmployeeAgent"   # headless/employee agent

language:
    default_locale: "en_US"
    additional_locales: ""
    all_additional_locales: False

start_agent agent_router:
    ...
    actions:
        go_to_diagnosis: @utils.transition to @subagent.<name>

subagent <name>:
    ...
    actions:
        my_action:
            description: "..."
            target: "apex://<MyInvocableApexClass>"   # actions point at Apex invocable actions
            inputs:
                someParam: string
                    description: "..."
                    is_required: True
```

**Key points:**

- `developer_name` in the `.agent` file, the **folder name**, and the **file name**
  must all be identical.
- Actions don't need separate `genAiFunction`/`genAiPlugin` files if you define them
  **inline** and target Apex invocable actions with `apex://<ClassName>`. Those Apex
  classes must already be deployed in the org.
- The agent's runtime API name (what Apex/Flow invokes) is the `developer_name`.

## 2. Deploy the metadata

Deploy the Apex actions + the bundle together (the bundle's `apex://` targets must
resolve):

```bash
# Validate first (no changes committed to the org)
sf project deploy start -o <alias> --dry-run

# Deploy for real
sf project deploy start -o <alias>

# Or deploy just the agent + its actions
sf project deploy start -o <alias> \
  -d force-app/main/default/aiAuthoringBundles \
  -d force-app/main/default/classes
```

If you hit a server-side `UNKNOWN_EXCEPTION` with **0 component errors**, deploy in
subsets to isolate the offending component (deploy classes first, then the bundle).

## 3. Assign the permission set

The agent runs as a user that needs access to whatever its Apex actions read:

```bash
sf org assign permset -n <YourPermSetName> -o <alias>
```

## 4. CRITICAL: deploying ≠ active. You must PUBLISH + ACTIVATE.

A clean `N/N components` deploy does **NOT** make the agent callable. Until it's
**published and activated**, any runtime invocation fails with:

```
INVALID_INPUT: AgentIAType not found for actionName: <AgentApiName>
... make sure ... agent is existent and active
```

Publish/activate one of two ways:

```bash
# CLI (preferred — but see the DNS caveat below)
sf agent publish -o <alias> --api-name <AgentApiName>
```

**DNS caveat (this bit us):** for some orgs, `sf agent validate/preview/publish`
route to `test.api.salesforce.com`, which split/internal DNS or VPN setups can't
resolve (even when `dig` resolves it, `node`/`curl`/`sf` may not). If `sf agent ...`
hangs or fails with a DNS/host error:

> **Fall back to the Agent Builder UI:** open the agent in Setup → Agent Builder →
> **Publish** and **Activate** it there. Metadata deploy is unaffected by this DNS
> issue — only the `sf agent` commands route to the unresolvable host.

## 5. Verify it's actually live

```bash
# Confirm the bundle is in the org (may show as <Name>_1 — a version-instance label)
sf org list metadata -m AiAuthoringBundle -o <alias>
```

Then run your real invocation path (Apex/Flow) end-to-end. If you still get
`AgentIAType not found` → it deployed but is **not activated** (go back to step 4).

---

## Common runtime bugs once it IS active (from experience)

These are *Apex-side* bugs that only surface after the agent works, not deploy
problems:

1. **Response is a wrapper envelope.** The invocable action's response param often
   comes back as `{"type":"Text","value":"<inner JSON as a string>"}` — the real
   payload is the **stringified `value`**. Unwrap `{type,value}` and re-parse `value`
   before reading your keys.

2. **No DML before the callout.** If your Apex does any DML *before* calling the
   agent action in the same transaction, the live callout fails with
   `MISSING_RECORD: ... pending uncommitted work`. **Reorder to callout-first**, then
   do DML. (A queueable that marks state then calls out will fail in a live org even
   though it passes in tests.)

3. **Invocable action param names matter.** Verify the action name and param keys
   against the published agent action — these are runtime strings that compile
   regardless of whether they're correct.
