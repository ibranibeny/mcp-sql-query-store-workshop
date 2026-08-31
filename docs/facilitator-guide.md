# Facilitator guide

## Delivery contract

This L400 workshop demonstrates how GitHub Copilot, grounded by Microsoft SQL MCP and verified SQL Server evidence, helps a DBA optimize a stored procedure. Preserve the distinction between observation, hypothesis, proposal, and evidence-backed decision throughout the day.

**Do not run the workshop workload scripts against production.** Repository build, test, and static-site generation are local operations and must not create Azure resources.

## Six-hour agenda

| Time | Module | Outcome |
|---:|---|---|
| 15 min | Orientation and safety contract | Establish licensing, cost, stop conditions, and evidence labels. |
| 35 min | MCP, SQL MCP Server, and GitHub Copilot | Distinguish model, client, server, transport, tools, MSSQL context, and approvals. |
| 25 min | Scenario and two-tier architecture | Trace the trust boundary from Windows 11 tooling to private SQL Server. |
| 60 min | Native Az PowerShell deployment | Run preflight, review the plan card, obtain separate approval, and deploy. |
| 10 min | Break | No lab action. |
| 65 min | Build and reproduce the problem | Restore AdventureWorks, scale data, enable Query Store, baseline, and create bounded pressure. |
| 65 min | Investigate through Visual Studio Code | Explore schema, explain logic, inspect plans, and retrieve allowlisted evidence. |
| 10 min | Break | No lab action. |
| 55 min | Optimize and prove | Create a candidate, validate equivalence, execute A/B tests, and evaluate metrics. |
| 20 min | Teardown and review | Remove Azure resources, verify absence, and discuss production controls. |
| **360 min** | **Total** | **Six hours.** |

Lunch is outside the six-hour agenda.

## Deployment approval boundary

Deployment preflight and deployment approval are separate checkpoints:

1. Run the non-destructive preflight. It may perform read-only validation of authentication, quota, regional VM/image availability, licensing attestation, source IPv4, naming, and configuration.
2. Present the completed plan card, including billable VM, SQL Server Enterprise, disk, public IP, NAT Gateway, and network implications.
3. Ask for **explicit billable-deployment approval** only after the facilitator reviews that plan card.
4. Without that approval, stop. Do not invoke the deployment path and do not create or modify Azure resources.

[!ASSUMPTION] Marketplace availability and capacity can change. Preflight must revalidate them immediately before any separately approved deployment.

## Public ingress boundary

- Only the Windows 11 administration VM has a public endpoint.
- Public RDP is restricted to TCP 3389 from the facilitator's confirmed IPv4 `/32`.
- The SQL Server VM has no public IP.
- SQL Server traffic uses encrypted private TDS on TCP 1433 from the administration tier.
- Do not broaden RDP or SQL ingress as a troubleshooting shortcut.
- Confirm the public IP and all workshop resources are absent after teardown.

## Facilitation checkpoints

- Before pressure: confirm the database, Resource Governor pool, workload tags, timeout, and stop path.
- Before accepting a proposal: prove result equivalence and keep conditions unchanged.
- During measurement: record actual values; targets are not measured evidence.
- On any threshold breach: stop the bounded workload and preserve diagnostics.
- Before closing: remove the lab resource group and verify resource absence.

[!TARGET] The approximately 80% to 40% grant-utilization comparison is a target for the isolated workshop query-workspace pool, not a promised result or whole-server memory claim.
