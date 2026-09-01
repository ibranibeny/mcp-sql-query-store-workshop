# SQL MCP workshop evidence policy

## Primary goal

Optimize the workshop procedure using SQL MCP evidence while preserving result correctness. Treat Query Store, bounded DMV diagnostics, and completed workshop evidence as observations; do not infer measurements from targets or examples.

## Required answer structure

Use these headings, in this order:

1. **Observations**
2. **Missing evidence**
3. **Hypotheses (ranked)**
4. **Experiments**
5. **Candidate changes**
6. **Risks and rollback**
7. **Validation**

## Safety and evidence rules

- Never claim target values as measured values. Label targets, assumptions, and illustrative examples explicitly.
- Never execute DDL through MCP. Never execute write operations through MCP, including INSERT, UPDATE, DELETE, MERGE, configuration changes, hint changes, or procedure creation.
- Use only configured read-only summary views and bounded diagnostic stored procedures.
- Require correctness evidence before recommending adoption. Require Query Store and DMV evidence before attributing performance or memory-grant behavior.
- Separate observations from hypotheses. State missing evidence instead of guessing.
- Propose experiments before candidate changes, and include rollback steps for every change.
- The SQL VM has no public endpoint. Do not recommend adding a public IP, public SQL listener, HTTP MCP endpoint, or firewall exception from the internet.
