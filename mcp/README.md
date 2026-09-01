# Local read-only SQL MCP server

This workshop uses Data API builder (DAB) 2.0 or later and MCP protocol 2025-06-18. VS Code launches DAB as a local `stdio` child process. In this mode there is no HTTP listener and no MCP network port.

## Secret setup

DAB reads `.env` from its current directory. VS Code starts the child process with the workspace root as the current directory, so the administration VM bootstrap creates a root `.env`, not an environment file under this directory. The root `.env` is ignored by Git and the bootstrap restricts its ACL to the current administrator account.

Do not copy this example unchanged and do not commit a real connection string. On the administration VM, replace `SET_LOCALLY_ON_ADMIN_VM` interactively in the ignored root `.env`. The example intentionally points to the SQL VM private DNS name and requires encrypted certificate validation.

The VS Code MCP configuration does not use the unsupported `envFile` property. The bootstrap may instead set `MSSQL_CONNECTION_STRING` in the process environment before VS Code starts.

## Validate configuration

From the workspace root, after DAB and the local secret are available:

    dab validate --config mcp/dab-config.json

This command performs DAB schema, permission, connectivity, and metadata validation. It requires private SQL connectivity and is intentionally deferred until the administration VM bootstrap/runtime validation stage.

## Use from VS Code

1. Open the Command Palette.
2. Run **MCP: List Servers**.
3. Start `mcp-sql-query-store-workshop`.
4. Confirm `describe_entities` lists exactly the two summary views and six diagnostics.

The positional `role:workshop-reader` argument immediately follows `--mcp-stdio`. The server exposes read and aggregate operations only for the configured summary views, plus bounded execution of the six configured diagnostic procedures. `describe_entities` reports configured metadata; it does not inspect or expose arbitrary database schema. Custom procedure tools appear with snake_case names.

REST and GraphQL are disabled globally. Create, update, and delete MCP tools are disabled. The SQL login is independently denied write and administrative permissions.

## Troubleshooting

- If DAB reports a missing environment variable, start VS Code from the prepared administration VM session or verify the ignored root `.env` exists and its ACL remains restricted.
- If validation cannot connect, verify private DNS resolution, TCP 1433 connectivity, and the trusted SQL certificate; do not weaken `Encrypt=True` or `TrustServerCertificate=False`.
- If tools are missing, verify DAB 2.0 or later and use **MCP: List Servers** to restart the local server.
