# Evidence labels and official sources

**Verification date: 2026-09-01.** Product behavior, image availability, quotas, policy, and documentation can change; revalidate before delivery.

## Classification rules

| Label | Meaning | Publication rule |
|---|---|---|
| `DOC-VERIFIED` | Claim supported by the adjacent official source | Include URL and verification date |
| `SUBSCRIPTION-VALIDATED` | Read-only observation in a named subscription context | Include date/context; repeat preflight before deployment |
| `LAB-MEASURED` | Value captured from a real, valid run | Include run ID, UTC window, units, conditions, and artifact hash |
| `TARGET` | Desired band or outcome | Never rewrite as observation |
| `ASSUMPTION` | Unverified operational premise | Name owner and validation checkpoint |

## DOC-VERIFIED claim map

| Claim | Official source |
|---|---|
| SQL MCP exposes configured database capabilities through DAB | [SQL MCP overview](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview) |
| Local VS Code can launch SQL MCP over stdio | [SQL MCP VS Code quickstart](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/quickstart-visual-studio-code) |
| Generic DML tool availability is configured and permission constrained | [SQL MCP DML tools](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/data-manipulation-language-tools) |
| DAB roles and permissions authorize entity actions | [DAB authorization](https://learn.microsoft.com/en-us/azure/data-api-builder/concept/security/authorization-overview) |
| SQL Server permissions remain authoritative | [Database Engine permissions](https://learn.microsoft.com/en-us/sql/relational-databases/security/authentication-access/getting-started-with-database-engine-permissions) |
| MSSQL Copilot provides connected database assistance | [GitHub Copilot for MSSQL](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/overview?view=sql-server-ver17) |
| VS Code `@mssql` supports context-aware query optimization and execution-plan analysis | [Query optimizer assistant](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/query-optimizer-assistant?view=sql-server-ver17) |
| MSSQL can explain database business logic | [Business logic explainer](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/business-logic-explainer?view=sql-server-ver17) |
| SSMS `/explain` and `/optimize` provide selected-query code assistance | [SSMS chat context and slash commands](https://learn.microsoft.com/en-us/ssms/github-copilot/chat-context) |
| SSMS Agent mode pauses for approval before executing a query or command, with approval scope selected by the user | [SSMS Agent mode and tool approvals](https://learn.microsoft.com/en-us/ssms/github-copilot/agent-mode) |
| SSMS MCP use requires Agent mode and explicit tool control | [MCP servers with Copilot in SSMS](https://learn.microsoft.com/en-us/ssms/github-copilot/mcp-servers) |
| Query Store persists plan/runtime/wait evidence | [Monitor with Query Store](https://learn.microsoft.com/en-us/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store?view=sql-server-ver17) |
| Query Store hints are inspectable and reversible | [Query Store hints](https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-hints?view=sql-server-ver17) |
| Memory grant evidence requires request/semaphore context | [Troubleshoot memory grants](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-memory-grant-issues) |
| Server memory settings do not describe only query grants | [Server memory configuration](https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/server-memory-server-configuration-options?view=sql-server-ver17) |
| Resource Governor classifies and constrains workloads | [Resource Governor](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor?view=sql-server-ver17) |
| Resource-pool percentages govern bounded pool resources | [Resource Governor pool](https://learn.microsoft.com/en-us/sql/relational-databases/resource-governor/resource-governor-resource-pool?view=sql-server-ver17) |
| Windows client images require qualifying eligibility | [Windows client in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/client-images) |
| Default outbound access should be replaced with explicit egress | [Default outbound access](https://learn.microsoft.com/en-us/azure/virtual-network/ip-services/default-outbound-access) |
| NAT Gateway provides explicit outbound connectivity | [NAT Gateway design](https://learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-design) |
| ASGs group NICs for network policy | [Application security groups](https://learn.microsoft.com/en-us/azure/virtual-network/application-security-groups) |
| AdventureWorks2022 is an official SQL sample | [AdventureWorks sample databases](https://learn.microsoft.com/en-us/sql/samples/adventureworks-install-configure?view=sql-server-ver17) |

## Context-specific claims

- `SUBSCRIPTION-VALIDATED`: SKU, image, quota, policy, provider, and name availability belong in the current preflight output, not this static guide.
- `LAB-MEASURED`: no target document in this repository contains that label. Apply it only after schema and semantic validation of a real run.
- `TARGET`: baseline 75–85% and optimized 35–45% of the regular workshop-pool query-workspace semaphore.
- `ASSUMPTION`: facilitator source IPv4 stability, licensing eligibility, access, capacity, and schedule remain owned by the facilitator until validated.