# Attendee guide

## Prerequisites

Bring L400 familiarity with SQL Server plans, joins, aggregates, statistics, Query Store, grants/spills, PowerShell, Azure networking, and GitHub Copilot approvals. The facilitator owns Azure deployment and credentials. Complete repository setup through the offline-first dependency guide; Python is not required on the deployed lab VMs.

**Do not run the workshop workload scripts against production.** Use only the marked `AdventureWorks2022` lab on the private SQL VM.

## Exercise sequence

1. Explain the evidence labels and exact query-grant denominator.
2. Trace MCP initialization, discovery, approval, SQL authorization, and result interpretation.
3. Verify no public SQL path exists.
4. Observe preflight and deployment readbacks; never bypass a failed gate.
5. Calibrate the bounded baseline and record the actual outcome.
6. Use MSSQL plus six read-only SQL MCP custom tools to investigate.
7. Review a side-by-side candidate and prove result equivalence.
8. Run the frozen twelve-trial comparison and make a measured decision.
9. Stop, export, redact, delete, and prove absence.

## Investigation worksheet

| Item | Entry |
|---|---|
| Run ID and UTC window | |
| Environment fingerprint and frozen-settings hash | |
| Procedure, parameters, Query ID, Plan ID | |
| Plan observations: estimates/actuals/operators/warnings | |
| Baseline peak/median grant utilization | |
| Optimized peak/median grant utilization | |
| Duration, CPU, reads, spills, waits | |
| Missing evidence | |
| Ranked hypotheses and confidence | |
| Approved experiment and rollback | |
| Correctness batch/result | |
| Outcome classification | |
| Teardown proof | |

## Evidence table

| Claim | Classification | Source/tool | Timestamp/window | Units | Independent check | Decision impact |
|---|---|---|---|---|---|---|
| Example: target band | TARGET | Workshop contract | Not applicable | Percent of regular pool semaphore | Configuration | Defines goal only |
| | | | | | | |
| | | | | | | |
| | | | | | | |

## Submission

Submit the completed worksheet, sanitized evidence bundle, correctness verdict, candidate decision, remaining risks, rollback, and verified teardown. Never submit credentials, connection strings, public IPs, tenant/subscription IDs, or unreviewed screenshots.