# Dual Copilot SQL Optimization Scenarios — Design Specification

**Date:** 2026-09-02  
**Status:** Approved  
**Audience:** Senior SQL Server administrators and performance engineers (L400)

## Purpose

Add two directly comparable, evidence-driven optimization scenarios to the workshop:

1. **Scenario A — Visual Studio Code:** connect from the Windows 11 administration VM to the private SQL Server with MSSQL, use GitHub Copilot through `@mssql`, and ground analysis with the allowlisted SQL MCP diagnostics.
2. **Scenario B — SQL Server Management Studio:** connect from the same VM to the same private database, select the same baseline source, and use GitHub Copilot `/explain` and `/optimize` with the same execution-plan and measurement context.

Copilot proposes and explains. The DBA controls DDL, correctness approval, performance acceptance, and rollback.

## Selected approach

Use **one baseline capture, two independent Copilot reviews, and one approved candidate**.

Both reviews happen before candidate DDL is applied. This prevents the second tool from seeing an already-created optimized procedure or index and limits workload drift. The DBA then reconciles Candidate A and Candidate B with the checked-in reference candidate and applies exactly one candidate through the guarded approval entry point.

Rejected alternatives:

- Two independent full benchmarks increase time, cost, and configuration-drift risk.
- Running SSMS only after applying the VS Code proposal biases the SSMS review.

## Shared workload contract

Both scenarios use `lab.usp_MonthEndSalesBaseline` from [sql/04-CreateBaselineProcedure.sql](../../../sql/04-CreateBaselineProcedure.sql) and the same representative invocation parameters.

Shared evidence includes:

- exact procedure source and parameter values;
- actual execution plan;
- baseline run ID and UTC window;
- Query ID and Plan ID;
- duration, CPU, logical reads, spills, and waits;
- requested, granted, ideal, used, and maximum-used query memory;
- Resource Governor regular-pool utilization;
- host and SQL process memory context.

The 75–85% baseline band and 35–45% optimized band remain targets, not observations.

## Scenario A design

1. RDP from the approved facilitator `/32` to the Windows 11 administration VM.
2. Open the repository in Visual Studio Code.
3. Verify MSSQL and GitHub Copilot extensions and complete interactive sign-in.
4. Connect to `sql01.mcpworkshop.internal,1433` and `AdventureWorks2022` with encryption and certificate validation.
5. Validate DAB and start the local `stdio` SQL MCP server.
6. Run one bounded diagnostic invocation and capture the actual plan.
7. Use `@mssql /explain` for business behavior and plan interpretation.
8. Use the read-only SQL MCP tools for bounded memory, grant, Query Store, wait, and plan evidence.
9. Use `@mssql /optimize` to produce Candidate A.
10. Save Candidate A without executing DDL.

SQL MCP remains unavailable for arbitrary SQL, DDL, workload control, and session termination.

## Scenario B design

1. From the same RDP session, open SSMS 22.7 or later with AI Assistance.
2. Complete interactive GitHub Copilot sign-in.
3. Connect an active editor to the same private server and database with validated encryption.
4. Open the same baseline source and representative invocation.
5. Include the same actual plan and baseline evidence window.
6. Before revealing Candidate A, select the baseline and run `/explain`.
7. Run `/optimize`, requiring index rationale, semantic risks, rollback, and validation.
8. Save Candidate B without executing DDL.

Ask mode is preferred for the controlled review. If Agent mode is shown, each query or command requires explicit approval and the SQL login permissions remain authoritative.

## Candidate approval and proof

The DBA compares Candidate A, Candidate B, and [sql/06-CreateOptimizedProcedure.sql](../../../sql/06-CreateOptimizedProcedure.sql). Agreement between assistants is not correctness evidence.

Only [deploy/Approve-WorkshopCandidate.ps1](../../../deploy/Approve-WorkshopCandidate.ps1) may apply the accepted candidate. The first gate is [sql/07-ValidateEquivalence.sql](../../../sql/07-ValidateEquivalence.sql), covering result metadata, parameter cases, hashes, bidirectional `EXCEPT`, error behavior, null semantics, and ordering.

After correctness passes, the workload controller reuses frozen settings and runs exactly twelve interleaved `ABBA BAAB ABBA` trials. Reporting preserves the actual outcome classification.

## Required response format

Each Copilot analysis uses these headings in order:

1. **Observations**
2. **Missing evidence**
3. **Hypotheses (ranked)**
4. **Experiments**
5. **Candidate changes**
6. **Risks and rollback**
7. **Validation**

Every measured claim identifies source, run ID, UTC window, procedure, parameters, Query ID/Plan ID when applicable, and unit.

## Operational safeguards

- Never expose SQL publicly to work around an RDP or tooling failure.
- Never paste credentials or connection strings into Copilot.
- Never represent targets as measured results.
- Never apply generated DDL before DBA review.
- Keep the baseline unchanged.
- Reject a candidate when equivalence fails.
- Treat a manual execution as diagnostic evidence, not benchmark evidence.

## Documentation implementation

- Add a standalone Scenario A/B tutorial under `workshop/`.
- Cross-link it from the existing VS Code investigation and optimization chapters.
- Add copy-ready prompts and official product references.
- Update facilitator, attendee, navigation, generated site, and tests where required.

## Acceptance criteria

1. Both scenarios use the same baseline source, parameters, plan context, run identity, and evidence window.
2. Candidate A and Candidate B are independently produced and remain unapplied during review.
3. SQL MCP exposes only configured read-only bounded diagnostics.
4. Exactly one candidate is applied through the approval entry point.
5. Equivalence passes before performance acceptance.
6. Performance reporting uses actual completed evidence.
7. SQL remains private.
8. Repository and static-site validation pass.

## Authoritative product references

- [GitHub Copilot for MSSQL](https://learn.microsoft.com/sql/tools/visual-studio-code-extensions/github-copilot/overview?view=sql-server-ver17)
- [MSSQL query optimizer assistant](https://learn.microsoft.com/sql/tools/visual-studio-code-extensions/github-copilot/query-optimizer-assistant?view=sql-server-ver17)
- [MSSQL slash commands](https://learn.microsoft.com/sql/tools/visual-studio-code-extensions/github-copilot/slash-commands?view=sql-server-ver17)
- [GitHub Copilot in SSMS](https://learn.microsoft.com/ssms/github-copilot/overview)
- [SSMS context and slash commands](https://learn.microsoft.com/ssms/github-copilot/chat-context)
- [SSMS Agent mode](https://learn.microsoft.com/ssms/github-copilot/agent-mode)
- [SQL MCP Server overview](https://learn.microsoft.com/azure/data-api-builder/mcp/overview)
