# Optimize and prove

**Instruction: 55 minutes · Workshop elapsed: 340 minutes**

## Use an evidence-first Copilot workflow

Require every analysis to separate **Observations**, **Missing evidence**, **Hypotheses ranked by confidence**, **Proposed experiments**, **Candidate changes**, **Risks and rollback**, and **Validation criteria**. Copilot assists the workflow; the DBA owns approvals and the final decision.

Start with the actual baseline source in `sql/04-CreateBaselineProcedure.sql`. Correlate its non-SARGable date conversion, wide intermediate payload, repeated fact access, late aggregation, hash/sort operators, estimates, actual rows, grants, spills, waits, and Query Store windows. Do not infer causality from one plan or execution.

## Create a side-by-side candidate

Review the reference candidate in `sql/06-CreateOptimizedProcedure.sql`: half-open SARGable dates, early filtering/projection, one fact access path, pre-aggregation at output grain, and ranking after the narrow aggregate. Keep the baseline intact. The candidate must preserve parameter names, types, defaults, validation behavior, result columns/types/null semantics, values, row identity, and contractual ordering.

## Correctness is the first gate

Only after the investigation is complete and the DBA has reviewed the proposed index and procedure, obtain a dedicated DBA credential and run the approval entry point. It opens one certificate-validated encrypted private TDS connection, executes only `sql/06-CreateOptimizedProcedure.sql` and `sql/07-ValidateEquivalence.sql`, and fails unless the candidate objects and the exact equivalence batch are positively verified. It does not accept or reuse the bootstrap database-master-key or MCP-reader secrets.

```powershell
$candidateDba = Get-Credential -Message 'DBA credential for approved candidate creation'
./deploy/Approve-WorkshopCandidate.ps1 `
	-Credential $candidateDba `
	-ServerInstance 'sql01.mcpworkshop.internal' `
	-ExpectedServerName 'sql01.mcpworkshop.internal' `
	-ExpectedDatabaseName 'AdventureWorks2022' `
	-ConfirmationPhrase 'APPROVE AdventureWorks2022 candidate'
```

The entry point runs the equivalence harness in `sql/07-ValidateEquivalence.sql`. It covers at least eight parameter cases and compares first-result metadata, row counts, deterministic hashes, baseline `EXCEPT` candidate, and candidate `EXCEPT` baseline. Any mismatch rejects the candidate and blocks performance acceptance. Do not run scripts 06 or 07 directly, and do not edit a correctness test merely to approve the candidate.

## Freeze and measure

Use the worker count, parameter schedule, dataset, indexes, statistics, Resource Governor pool/group, server memory, database-scoped settings, and Query Store state serialized during baseline calibration. The workload controller then performs exactly twelve interleaved trials in `ABBA BAAB ABBA` order.

Compare peak and median pool grant utilization, duration, CPU, logical reads, spills, wait time, and completed requests. Link each number to run ID, UTC window, Query ID/Plan ID, units, and evidence classification. The [!TARGET] baseline is 75–85% and optimized is 35–45%, but the report must preserve the actual outcome. Useful movement outside the bands is `ImprovedOutsideTarget`; inability to calibrate is `BaselineTargetNotReached`.

## Export reviewed evidence

Pass the completed workload object to the implemented export entry point:

```powershell
./workload/Export-WorkshopEvidence.ps1 -RunId $runId -Evidence $evidence
```

The export validates semantic consistency and writes under `evidence/runs/<run-id>/`. Generated runs remain ignored until a human reviews provenance and redaction.

## Optional Query Store hint: separate and reversible

Only after foundational query/index/statistics analysis, use `sql/08-OptionalQueryStoreHint.sql` as a separate mitigation experiment. Capture pre-state, apply only the bounded supported hint when evidence justifies it, inspect status/failure details, repeat measurement, clear the hint, and verify removal. Never combine hint evidence with the foundational candidate result or leave the hint silently active. [!DOC-VERIFIED] See [Query Store hints](https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-hints?view=sql-server-ver17).

## Decision record

Retain a candidate only when correctness passes, grant utilization materially improves, at least one secondary metric improves, and no primary metric materially regresses. Otherwise reject or continue experimentation. Record limitations, rollback, and unresolved parameter sensitivity.