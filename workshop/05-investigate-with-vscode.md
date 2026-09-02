# Investigate from VS Code on the admin VM

**Instruction: 65 minutes + 10-minute break · Workshop elapsed: 285 minutes**

For the complete side-by-side procedure, use the untimed [Scenario A: VS Code and Scenario B: SSMS runbook](scenario-a-vscode-scenario-b-ssms.html). It preserves one baseline, two independent Copilot reviews, and one guarded candidate approval.

## 1. Verify the workstation boundary

Install or confirm exactly `ms-mssql.mssql`, `GitHub.copilot`, and `GitHub.copilot-chat`. The PowerShell extension is useful but not part of the three required database/Copilot IDs. Connect MSSQL to `sql01.mcpworkshop.internal,1433`, database `AdventureWorks2022`, with encryption enabled, certificate validation enabled, and hostname `sql01.mcpworkshop.internal`. If TLS validation fails, repair DNS, certificate trust, or hostname; do not normalize `TrustServerCertificate=True`.

Use `@mssql` for connected schema, stored-procedure business logic, query execution, and actual execution-plan analysis. [!DOC-VERIFIED] Review the [MSSQL Copilot overview](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/overview?view=sql-server-ver17) and [business logic explainer](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/business-logic-explainer?view=sql-server-ver17).

## 2. Validate and start DAB

From the cloned repository, validate the checked-in configuration against DAB 2.0.9 and the live private database:

```powershell
dotnet tool run dab -- validate --config mcp/dab-config.json
```

The equivalent installed-command check is `dab validate --config mcp/dab-config.json`. The ignored environment file supplies `MSSQL_CONNECTION_STRING`; never paste it into chat. The configured MCP launch is local `stdio`, role `workshop-reader`, logging at error level.

Open the Command Palette and run **MCP: List Servers**. Start `mcp-sql-query-store-workshop`, review its status, then inspect discovered tools before approving any call.

## 3. Learn the configured surface

Call `describe_entities`. It describes only the two configured summary views and six configured procedures; it cannot infer every table, relationship, index, or permission in SQL Server. Compare descriptions against `mcp/dab-config.json` rather than guessing.

| Custom tool | Use | Required bounds |
|---|---|---|
| `get_memory_snapshot` | Current pool semaphore, host, process, and SQL memory context | Point-in-time; not benchmark proof |
| `get_active_workshop_grants` | Tagged active request grant details | `Top` 1–100; optional run ID |
| `get_query_store_top_queries` | Runtime metrics for the two procedures | UTC window ≤24 hours; `Top` 1–100 |
| `get_query_store_waits` | Query Store wait categories | UTC window ≤24 hours; `Top` 1–100 |
| `get_procedure_plan_summary` | Plan identity and forcing state | Exact baseline or optimized procedure; `Top` 1–100 |
| `compare_workshop_runs` | Final bounded comparison | Completed run, validation batch, exactly twelve correct trials |

Generic `read_records` and `aggregate_records` apply only to configured summary views; `execute_entity` applies to allowed stored procedures. Create, update, and delete tools are disabled. Workload control, DDL, arbitrary SQL, and session termination are outside MCP.

## 4. Conduct the investigation

1. Use `@mssql` to inspect schema, indexes, procedure definitions, and representative actual plans.
2. Record plan operators, estimates versus actuals, warnings, memory grant properties, spills, and parameter values as observations.
3. Use SQL MCP to collect the bounded memory snapshot, active grants, Query Store runtime, waits, and plan summaries for the exact run window.
4. Correlate Query ID, Plan ID, run ID, timestamps, procedure phase, and units.
5. Use prompts from the prompt book. Every response must contain: Observations; Missing evidence; Hypotheses ranked by confidence; Proposed experiments; Candidate changes; Risks and rollback; Validation criteria.
6. Reject claims that omit source, timestamp/window, units, procedure, parameters, or certainty.

Approval remains with the DBA. Copilot may propose a candidate, but it cannot approve DDL, expand MCP permissions, accept correctness, or classify a run without evidence.

### Break — 10 minutes

Stop active workload first. Preserve the run ID and evidence window. Do not leave pressure running while participants are away.