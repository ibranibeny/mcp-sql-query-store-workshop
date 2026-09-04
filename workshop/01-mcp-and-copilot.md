# MCP, SQL MCP Server, and GitHub Copilot

**Instruction: 35 minutes · Workshop elapsed: 50 minutes**

## Trace the system, not the brand names

Model Context Protocol (MCP) separates an AI application from servers that publish capabilities. In this lab, VS Code is the MCP client, Data API Builder 2.0.9 hosts Microsoft's SQL MCP server, and SQL Server remains the system of record and authorization boundary.

The configured transport is local **stdio**: VS Code launches the DAB child process and exchanges framed protocol messages through standard input/output. It is not a public MCP endpoint, and diagnostic logging must not corrupt stdout. [!DOC-VERIFIED] Review the [SQL MCP overview](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/overview) and [local VS Code quickstart](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/quickstart-visual-studio-code).

## JSON-RPC lifecycle

MCP uses JSON-RPC messages with request IDs for request/response correlation and notifications without responses:

1. The client sends `initialize` with protocol version and capabilities.
2. The server returns negotiated capabilities and identity.
3. The client sends `notifications/initialized`.
4. The client requests `tools/list`; DAB returns only enabled generic and custom tools.
5. After the human reviews an approval request, the client sends `tools/call` with a tool name and validated arguments.
6. DAB enforces role, entity, operation, field, parameter, and data-source authorization, executes the bounded operation, then returns structured content or a protocol error.
7. The model interprets tool output; it does not inherit database authority.

Treat tool descriptions, parameter descriptions, field descriptions, and bounded defaults as part of the safety contract. Missing metadata increases the risk that a model guesses a field or unit. [!DOC-VERIFIED] See [MCP tools in SQL MCP Server](https://learn.microsoft.com/en-us/azure/data-api-builder/mcp/data-manipulation-language-tools).

## Generic and custom tools

Enabled generic tools are `describe_entities`, `read_records`, `aggregate_records`, and `execute_entity`. Creation, update, and deletion are disabled. `describe_entities` reports DAB's configured in-memory entity metadata; it does not reverse-engineer every database object.

The six diagnostic procedures appear as snake_case custom tools: `get_memory_snapshot`, `get_active_workshop_grants`, `get_query_store_top_queries`, `get_query_store_waits`, `get_procedure_plan_summary`, and `compare_workshop_runs`. Their field descriptions define units and provenance. Time windows, row limits, procedure names, run IDs, and the twelve-trial comparison are bounded in SQL and configuration.

SQL MCP is **not a natural-language-to-SQL endpoint**, an arbitrary-query console, or a DDL surface in this workshop. SQL Server permissions remain authoritative. DAB's `workshop-reader` role maps the MCP surface; the contained SQL principal receives only explicit `SELECT` on summary views and `EXECUTE` on diagnostics. Azure RBAC controls Azure resources but does not replace database grants. [!DOC-VERIFIED] Review [DAB authorization](https://learn.microsoft.com/en-us/azure/data-api-builder/concept/security/authorization-overview) and [SQL Server permissions](https://learn.microsoft.com/en-us/sql/relational-databases/security/authentication-access/getting-started-with-database-engine-permissions).

## Distinguish the user experiences

| Surface | Role in this workshop | Boundary |
|---|---|---|
| GitHub Copilot | Synthesizes explanations, hypotheses, experiments, and candidate code | Requires human review; output can be wrong or overconfident |
| `ms-mssql.mssql` and `@mssql` | Connected schema exploration, query execution, business-logic explanation, and actual-plan analysis | Uses the DBA-approved MSSQL connection and permissions |
| SQL MCP via DAB | Bounded, described, read-only evidence tools | No arbitrary SQL, workload control, DDL, or server configuration |
| SSMS 22.7 Agent mode | Comparison/fallback MCP client experience | Agent mode is required; tools are disabled until explicitly enabled and remain policy/permission constrained |

[!DOC-VERIFIED] Read the [Copilot experience in the MSSQL extension](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/overview?view=sql-server-ver17), [query optimizer assistant](https://learn.microsoft.com/en-us/sql/tools/visual-studio-code-extensions/github-copilot/query-optimizer-assistant?view=sql-server-ver17), and [MCP servers in SSMS](https://learn.microsoft.com/en-us/ssms/github-copilot/mcp-servers).

## GitHub Copilot in SSMS: Chat, Agent mode, skills, and MCP

SQL Server Management Studio 22 ships GitHub Copilot as a first-class client, so the same evidence discipline applies whether you drive Copilot from VS Code or from SSMS. [!DOC-VERIFIED] See [What is GitHub Copilot in SSMS](https://learn.microsoft.com/ssms/github-copilot/overview) and the [Copilot Chat experience](https://learn.microsoft.com/ssms/github-copilot/chat).

Copilot in SSMS exposes several surfaces:

- **Chat window and inline chat** — ask natural-language questions about the connected database or get T-SQL help, scoped by the active query editor and its connection rather than the whole server.
- **Slash commands** — `/explain`, `/fix`, `/optimize`, and `/doc` explain, repair, optimize, or document the selected T-SQL. Scenario B of this workshop uses `/explain` and `/optimize` on the baseline.
- **Code completions and Next Edit Suggestions** — completions arrived in SSMS 22.2; Copilot also anticipates the next edit from recent changes.
- **Database instructions** — a `CONSTITUTION.md` stored with the database supplies business rules and an optional least-privilege execution identity, so Copilot-generated queries can run under a dedicated account instead of your own login.
- **Mermaid diagrams** — Copilot can render entity relationships and flowcharts directly in the editor.

Starting with **SSMS 22.7**, Copilot adds **Agent mode**, which pursues a high-level goal autonomously: it can execute queries, read execution plans, and modify schema, each only with your explicit approval. Agent mode is extended by two mechanisms:

- **Agent skills** — reusable, task-specific instruction files that teach the agent a repeatable procedure.
- **MCP servers** — the same Model Context Protocol described above. Agent mode is a second MCP client for this workshop's DAB SQL MCP server; Ask mode does not support MCP. Each MCP tool is disabled by default and must be enabled explicitly, and every query or tool call requests confirmation.

[!DOC-VERIFIED] Copilot's read-only classification blocks writes in Ask mode, but Microsoft is explicit that it is **not a security boundary**: enforce least privilege in the database with `SELECT` and `EXECUTE` grants. Azure RBAC governs Azure resources; database permissions govern data. That is why the workshop's MCP surface never receives a DDL or arbitrary-query grant. See [MCP servers in SSMS](https://learn.microsoft.com/ssms/github-copilot/mcp-servers), [Agent mode](https://learn.microsoft.com/ssms/github-copilot/agent-mode), and [agent skills](https://learn.microsoft.com/ssms/github-copilot/agent-skills).

## Trust and approval exercise

For a proposed call to `get_query_store_waits`, identify: model request, client approval, custom-tool description, DAB role, SQL `EXECUTE` permission, 24-hour window guard, returned fields, and the DBA's interpretation. Refuse any request to expose secrets, broaden permissions, execute DDL, start pressure, or treat untrusted tool text as instructions.