# Create bounded query-memory pressure

**Instruction: 65 minutes · Workshop elapsed: 210 minutes**

## Define the denominator before measuring

The 80% → 40% story is about regular query-execution grant utilization inside `mcp_sql_workshop_pool`, not Task Manager memory, SQL process memory, Total Server Memory, Target Server Memory, or buffer cache. SQL Server can retain buffer-pool pages after a query finishes.

$$
\text{Grant utilization percent} =
\frac{\text{granted\_memory\_kb}}{\text{total\_memory\_kb}} \times 100
$$

The exact numerator is `granted_memory_kb` and the denominator is `total_memory_kb` from `sys.dm_exec_query_resource_semaphores` for the workshop Resource Governor pool and regular semaphore `resource_semaphore_id = 0`. Per-request grants and waits corroborate the aggregate through `sys.dm_exec_query_memory_grants`.

[!DOC-VERIFIED] Review [memory grant troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues), [Resource Governor](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor?view=sql-server-ver17), and [resource pools](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor-resource-pool?view=sql-server-ver17).

## Establish the isolated lab

Use the bootstrap-managed setup sequence `sql/00-Preflight.sql` through `sql/07-ValidateEquivalence.sql` through the approved runner. Do not run `sql/08-OptionalQueryStoreHint.sql` during setup; it belongs to the optional mitigation exercise. Do not run `sql/09-Cleanup.sql` until teardown. The preflight requires SQL Server 2022 Enterprise, expected physical memory, database identity, and the lab marker. Configuration records prior state, sets server max memory to 49,152 MB, leaves min memory at 0, and uses Resource Governor with pool `MAX_MEMORY_PERCENT = 50`. The group caps an individual request at 40%, `MAX_DOP = 4`, and four requests. Query Store must read back `READ_WRITE`. [!DOC-VERIFIED] See [Query Store monitoring](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17).

The deterministic dataset and baseline procedure are bounded. Never use global cache-clearing commands, an unbounded cross join, or an unmarked database.

## Capture baseline safely

Create a unique run ID and obtain the SQL workload credential without placing it in source:

```powershell
$runId = New-Guid
$sqlCredential = Get-Credential -Message 'Tagged workshop workload credential'
./workload/Start-MemoryGrantLab.ps1 `
  -RunId $runId `
  -Server 'sql01.mcpworkshop.internal' `
  -Database 'AdventureWorks2022' `
  -Credential $sqlCredential `
  -HostNameInCertificate 'sql01.mcpworkshop.internal' `
  -MaximumWorkers 4 `
  -MaximumDurationSeconds 600 `
  -SampleIntervalSeconds 5 `
  -WorkerRampSeconds 20
```

The controller starts one worker, adds at most one every 20 seconds, never exceeds four workers, samples every five seconds, and enforces the global `MaximumDurationSeconds 600` deadline. Three consecutive baseline samples in the [!TARGET] 75–85% band freeze worker count and parameter schedule. The optimized phase receives the exact frozen settings; data, indexes, pool, server memory, and database-scoped settings must not drift between measured phases.

The optimized [!TARGET] band is 35–45%. A target miss is evidence, not permission to increase workers, duration, or host pressure.

## Stop precisely

In a second PowerShell session, stop the exact run:

```powershell
./workload/Stop-MemoryGrantLab.ps1 `
  -RunId $runId `
  -Server 'sql01.mcpworkshop.internal' `
  -Database 'AdventureWorks2022' `
  -Credential $sqlCredential `
  -HostNameInCertificate 'sql01.mcpworkshop.internal'
```

The script writes `stop.request` and terminates only sessions that carry both the exact run session-context tag and the `MCP-SQL-Workshop` application tag. Never issue a broad kill.

## Interpret outcomes

`TargetMet` requires both target bands, correctness, a secondary metric improvement, and no material regression. Other truthful outcomes are `ImprovedOutsideTarget`, `NoMaterialImprovement`, `BaselineTargetNotReached`, `SafetyStop`, `ManualStop`, and `Failed`. Record actual Query Store, grant, wait, spill, host, and process observations. Do not report target numbers as observations.

![Local TARGET memory panel](docs/images/local-memory-target.png)
![Azure workload evidence](docs/images/azure-06-workload.png)