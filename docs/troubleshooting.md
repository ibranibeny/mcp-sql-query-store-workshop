# Troubleshooting

Preserve the failed checkpoint and exact safe error text. Do not invent an error code, weaken a security boundary, or call a target value measured.

| Symptom | Diagnose | Safe resolution |
|---|---|---|
| Required Python/Pester/PSScriptAnalyzer version unavailable | Run local dependency validators; compare bounded versions | Use preprovisioned tools, approved wheelhouse, or configured internal repositories from the offline guide; do not use public PyPI on the corporate route |
| Az module missing or below required version | Review preflight module check | Install through the approved PowerShell repository; rerun preflight |
| Provider, quota, SKU, restriction, or image check fails | Record region, family usage/limit, image coordinates, and policy result | Request quota/registration or choose a separately reviewed schedule; do not silently change region/SKU/image |
| Windows client attestation fails | Confirm qualifying organizational entitlement | Stop; Marketplace visibility is not license proof |
| NAT outbound fails | Verify NAT public IP, gateway, and both subnet associations; default outbound is disabled | Repair explicit NAT; do not add inbound paths |
| Private DNS/TCP succeeds but TLS fails | Check DNS name, certificate SAN/trust, SQL binding, and client hostname | Repair trust/binding; do not make `TrustServerCertificate=True` the successful path |
| SQL marker, Enterprise 2022, Resource Governor, or Query Store check fails | Run guarded preflight and inspect effective catalog/DMV state | Restore the approved lab state; do not run pressure until all readbacks pass |
| DAB schema validation fails | Confirm DAB 2.0.9, schema URL, JSON fields, entity parameters, role, and descriptions | Run `dotnet tool run dab -- validate --config mcp/dab-config.json`; fix config rather than deleting constraints |
| MCP server starts but tools are missing | Use MCP: List Servers; inspect server output, role, `.env`, and `tools/list` | Expect four enabled generic operations and six snake_case custom tools; `describe_entities` sees configured entities only |
| MCP call is denied | Compare DAB `workshop-reader` permission and SQL principal grants | Keep least privilege; do not grant owner/datareader or expose arbitrary SQL |
| Workload does not reach 75–85% | Check marker, tags, worker ramp, parameter schedule, grants, waits, and global deadline | Report `BaselineTargetNotReached`; never exceed four workers or ten minutes |
| Workload stops early | Check stop file, host >87.5%, available memory <8 GiB, low-memory flags, health failures, timeout | Preserve samples, resolve cause, then start a new run ID |
| Workload hangs or locks | Inspect only tagged sessions and active grants | Use `Stop-MemoryGrantLab.ps1` for exact run ID; never broad-kill or clear global cache |
| Candidate misses 35–45% | Verify correctness and frozen-condition hash; compare secondary metrics | Report `ImprovedOutsideTarget` or `NoMaterialImprovement` from actual evidence |
| Cleanup refuses cross-database dependencies | Inspect dependency evidence from `sql/09-Cleanup.sql` | Remove dependencies deliberately or leave cleanup blocked; never force-drop unknown objects |
| GitHub Pages route/style/image fails | Build locally, inspect manifest route uniqueness, relative links, copied assets, and pending screenshot cards | Rebuild all routes and root assets; absent screenshots must render a pending card, not a broken image |

If the resource-group deletion cannot be positively verified, report ongoing billing risk to the subscription owner.