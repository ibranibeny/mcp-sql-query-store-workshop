# Deploy with native Az PowerShell

**Instruction: 60 minutes + 10-minute break · Workshop elapsed: 145 minutes**

This module uses only repository entry points. It never bypasses the preflight gate. Prepare the repository's Python and PowerShell validation dependencies before class with [the offline dependency routes](offline-dependencies.html). The deployed VMs still require the documented NAT outbound path to approved Microsoft, GitHub, NuGet, Winget, update, activation, and AdventureWorks endpoints during bootstrap; they do not use PyPI at runtime.

## 1. Collect immutable inputs

From a PowerShell 7 session at the repository root, define the subscription, optional tenant, facilitator IPv4 `/32`, expiration within seven days, repository HTTPS URL, and the exact 40-character commit SHA. Obtain administrator credentials securely:

```powershell
$credential = Get-Credential -Message 'Workshop VM administrator credential'
$databaseMasterKeyPassword = Read-Host 'Database master key password' -AsSecureString
$mcpReaderPassword = Read-Host 'MCP reader password' -AsSecureString
```

Do not put passwords in shell history, source files, screenshots, or evidence.

## 2. Run non-destructive preflight

Use the parameters implemented by `deploy/Test-WorkshopPrerequisites.ps1`:

```powershell
./deploy/Test-WorkshopPrerequisites.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -FacilitatorCidr $facilitatorCidr `
  -ExpiresOn $expiresOn `
  -WindowsClientLicenseAttested `
  -SqlEnterpriseCostAcknowledged `
  -BillableResourcesAcknowledged
```

The three attestations are independent: Windows client license eligibility, SQL Enterprise cost, and all billable resource categories. The preflight reads context, providers, regional SKUs, restrictions, family quota, exact image versions, source CIDR, names, and expiration. It prints checks and a plan card. **If preflight fails or the plan card is unavailable, do not deploy.** Never substitute a region, SKU, image, or broad CIDR silently.

![Azure preflight and plan card](docs/images/azure-01-preflight.png)

## 3. Review the plan card aloud

Confirm `indonesiacentral`, resource group `rg-mcp-sql-workshop`, admin `Standard_D4s_v5`, SQL `Standard_E8s_v5`, SQL Enterprise PAYG, disk categories, NAT Gateway, one admin public IP, admin RDP `/32`, SQL private TCP 1433, SQL public IP none, immutable image versions, tags, expiration, and auto-shutdown. This review is not deployment approval.

## 4. Invoke the gated deployment

Only after the plan card passes and the facilitator separately approves billing, run the deployment with the implemented parameters:

```powershell
./deploy/Deploy-WorkshopEnvironment.ps1 `
  -SubscriptionId $subscriptionId `
  -TenantId $tenantId `
  -FacilitatorCidr $facilitatorCidr `
  -ExpiresOn $expiresOn `
  -Credential $credential `
  -DatabaseMasterKeyPassword $databaseMasterKeyPassword `
  -McpReaderPassword $mcpReaderPassword `
  -RepositoryUrl $repositoryUrl `
  -RepositoryCommit $repositoryCommit `
  -WindowsClientLicenseAttested `
  -SqlEnterpriseCostAcknowledged `
  -BillableResourcesAcknowledged `
  -ApproveBillableDeployment `
  -ConfirmationPhrase 'DEPLOY rg-mcp-sql-workshop'
```

The exact phrase is case-sensitive: `DEPLOY rg-mcp-sql-workshop`. The script also uses PowerShell `ShouldProcess`; both gates must approve creation.

## 5. Read every phase back

The entry point verifies, in order: Azure context; preflight and immutable images; network creation; network boundary; admin VM; SQL VM; SQL IaaS PAYG registration; auto-shutdown; VM boundary; SQL bootstrap; admin bootstrap; and end-to-end readiness. A phase must return `Completed = true`, and each boundary/readiness object must pass, before the next result is accepted.

On partial failure, the script reports the last checkpoint and explicitly performs no automatic rollback. Preserve the sanitized failure, inspect what exists, then choose deliberate remediation or teardown. Do not rerun blindly.

Expected milestone evidence includes preflight/plan, network boundary, VM boundary, SQL readiness, admin readiness, workload, and Pages screenshots. Redact subscription, tenant, public IP, usernames, credentials, tokens, connection strings, machine-specific paths, and certificate details before publication.

![Azure SQL readiness](docs/images/azure-04-sql-readiness.png)
![Azure administration readiness](docs/images/azure-05-admin-readiness.png)

## 6. Enter the admin VM

RDP only to the admin public IP from the attested `/32`. From that VM, verify private DNS and validated TLS to `sql01.mcpworkshop.internal,1433`. `TrustServerCertificate=True` is not the success path. Do not expose or directly RDP to the SQL VM from the internet.

### Break — 10 minutes

Leave no workload running during the break. If deployment is incomplete, retain the exact failed checkpoint; do not use the break to bypass a failed preflight or readiness gate.