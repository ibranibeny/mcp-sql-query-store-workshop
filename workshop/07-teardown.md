# Teardown and review

**Instruction: 20 minutes · Workshop elapsed: 360 minutes**

## 1. Stop active pressure

If a run is active, use `workload/Stop-MemoryGrantLab.ps1` with its exact `-RunId`, private `-Server`, `-Database`, `-Credential`, and `-HostNameInCertificate`. Confirm only doubly tagged sessions were terminated. Run SQL cleanup only through `sql/09-Cleanup.sql`; it fails closed when cross-database dependencies or unsafe prior state prevent restoration.

## 2. Collect and redact evidence

Retain run ID, UTC windows, outcome, frozen-condition hash, correctness batch, Query Store IDs, grant samples, secondary metrics, and teardown output. Review screenshots and generated evidence for subscription/tenant IDs, public IPs, user names, credentials, tokens, connection strings, local paths, certificate details, and unrelated resources. Do not relabel target examples as measured.

## 3. Deallocate for a short pause

Deallocation stops VM compute charges but does not remove disks, public IP, NAT Gateway, or other resource charges:

```powershell
./deploy/Stop-WorkshopEnvironment.ps1 -SubscriptionId $subscriptionId -TenantId $tenantId -Confirm:$false
```

Use stop only when the lab will resume. Record the returned checkpoint for both approved VMs.

## 4. Delete permanently

For final teardown, invoke the guarded resource-group removal:

```powershell
./deploy/Remove-WorkshopEnvironment.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -ConfirmationPhrase 'DELETE rg-mcp-sql-workshop' `
  -Confirm:$false
```

The exact case-sensitive phrase is `DELETE rg-mcp-sql-workshop`. The function waits for deletion and fails if the resource group or any tagged workshop resource remains. The tagged-resource check searches the whole subscription, not just the deleted group, so a workshop-tagged resource that was created elsewhere still fails teardown.

If this deployment used the local emergency-stop fallback instead of a DevTestLab schedule, removal also unregisters the `McpSqlWorkshop-EmergencyStop` scheduled task on this workstation and proves it is gone. The returned checkpoint list reports `Local emergency-stop task removed` or `Local emergency-stop task absent`; treat any other value as teardown incomplete.

## 5. Prove cost stop

Do not end at a successful delete request. Record positive evidence that the resource group is absent, no tagged workshop resources remain, and the local emergency-stop task is gone. If access prevents proof or a dependency blocks deletion, report teardown incomplete and ongoing billing risk; escalate to the subscription owner.

## 6. Close the workshop

Complete the attendee evidence table, attach only reviewed artifacts, and write a short report with outcome, correctness verdict, performance evidence, security boundary, limitations, rollback, and teardown proof. Use the organization's approved mail or ticket system to send the report; do not commit recipient addresses or sensitive evidence. Remove local ignored `.env` and transient credentials after evidence review.

Production adoption requires separate workload replay, security review, change control, maintenance-window planning, monitoring, and rollback. This disposable lab is not production approval.

![Azure Pages and teardown evidence](docs/images/azure-07-pages.png)