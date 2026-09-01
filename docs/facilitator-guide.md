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

## Minute schedule and checkpoints

| Elapsed | Action | Pass evidence | Fail branch |
|---:|---|---|---|
| 00–15 | Orientation, licenses, cost, labels, stop conditions | Participants identify TARGET versus measured and prohibit production use | Restate contract; do not continue without agreement |
| 15–50 | MCP internals and product boundaries | Group traces initialize → tools/list → approved tools/call → DAB/SQL authorization | Re-run paper trace; never broaden a role to make a demo work |
| 50–75 | Architecture and verification exercise | SQL NIC has no public IP; RDP `/32`; private 1433; NAT on both subnets | Stop; remediate boundary before workload |
| 75–90 | Offline readiness and Azure context | Required local versions and authenticated intended subscription | Use approved offline route or correct context; no deployment |
| 90–110 | Non-destructive preflight | Every check passes and immutable images resolve | **No deployment if preflight failed** |
| 110–120 | Plan-card and attestation review | Windows eligibility, SQL Enterprise cost, billable categories acknowledged separately | End deployment portion without creating resources |
| 120–125 | Explicit deployment decision | Exact deploy phrase and `ShouldProcess` approval | No action; preserve plan card |
| 125–135 | Deployment checkpoints/fallback handoff | Network, VMs, bootstrap, TLS, readiness all pass, or use pre-staged environment | Preserve last checkpoint; do not claim readiness |
| 135–145 | Break | No workload active | Stop exact tagged run |
| 145–165 | SQL setup and Query Store | Bootstrap scripts 00–05 complete; marker valid; Enterprise 2022; Resource Governor and Query Store read back; no candidate exists | Repair setup; never weaken guards or create the candidate early |
| 165–190 | Baseline calibration | Three consecutive 75–85% samples or bounded truthful miss | Record `BaselineTargetNotReached`; do not increase limits |
| 190–210 | Evidence interpretation | Run ID, UTC window, units, grants, waits, plans captured | Mark missing evidence and defer conclusions |
| 210–235 | VS Code, MSSQL, and DAB | TLS validates; DAB validates; allowlisted tools only | Fix trust/config/role; no broad SQL fallback |
| 235–275 | Structured investigation | Observations are sourced; hypotheses ranked; experiments bounded | Score with rubric and revise |
| 275–285 | Break | Workload stopped; run context retained | Stop tagged run before leaving |
| 285–305 | Candidate review and explicit approval | Investigation complete; baseline preserved; candidate contract stated; `deploy/Approve-WorkshopCandidate.ps1` runs with `APPROVE AdventureWorks2022 candidate` | Reject destructive or unsupported proposal; do not run scripts 06/07 directly |
| 305–320 | Correctness matrix | Metadata, counts, hashes, and bidirectional differences pass | Reject candidate; skip acceptance run |
| 320–335 | Frozen comparison | Twelve interleaved trials; settings hash unchanged | Classify invalid/failed; do not combine runs |
| 335–340 | Decision | Actual outcome and risks recorded | Use `ImprovedOutsideTarget` or `NoMaterialImprovement` truthfully |
| 340–350 | Stop/export/redact | Evidence bundle passes review | Quarantine artifact until corrected |
| 350–358 | Delete and verify | Resource group absent; tagged-resource query empty | Report billing risk and escalate |
| 358–360 | Close | Report owner and follow-up named | Record incomplete action explicitly |

The live deployment cannot reliably finish in ten minutes; prepare a verified environment and use the deployment block to demonstrate gates/readbacks. Never hide a failed live checkpoint to protect the schedule.

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
- After investigation and before A/B: review the proposed index and procedure, then use `deploy/Approve-WorkshopCandidate.ps1` with the exact phrase `APPROVE AdventureWorks2022 candidate`. Bootstrap stops at script 05; only this entry point may run scripts 06 and 07 over certificate-validated encrypted private TDS.
- Before accepting a proposal: prove result equivalence and keep conditions unchanged.
- During measurement: record actual values; targets are not measured evidence.
- On any threshold breach: stop the bounded workload and preserve diagnostics.
- Before closing: remove the lab resource group and verify resource absence.

[!TARGET] The approximately 80% to 40% grant-utilization comparison is a target for the isolated workshop query-workspace pool, not a promised result or whole-server memory claim.

## Target miss protocol

- `BaselineTargetNotReached`: preserve samples and stop at four workers/ten minutes. Do not resize, extend, or alter memory boundaries during class.
- `ImprovedOutsideTarget`: report measured values and the qualifying reduction; do not round into the target band.
- `NoMaterialImprovement`: retain the evidence, reject the candidate, and discuss the next bounded hypothesis.
- `SafetyStop`, `ManualStop`, or `Failed`: do not resume until the cause is understood and the lab identity/safety checks pass.

## Screenshot checklist

Capture only at verified milestones: local home, local architecture, local TARGET panel, Azure preflight, network boundary, VM boundary, SQL readiness, admin readiness, workload outcome, and Pages/teardown. Follow `docs/images/screenshot-manifest.json`; a missing image remains `Screenshot pending verified milestone`. Never create illustrative UI and label it verified.
