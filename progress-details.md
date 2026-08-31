# Task 10 runtime quality fix

## Root cause

- CHECK validation compared normalized raw definitions exactly even though SQL Server can rewrite equivalent `IN` and `BETWEEN` expressions.
- Active grant correlation depended on historical request samples and current-session-only `SESSION_CONTEXT`, so new live grants could be omitted.
- No secure bootstrap executed all SQL batches on one encrypted connection or safely handled `GO`, DMK, and reader secrets.

## Fix

- Validate exact CHECK names, parents, enabled/trusted/NFR flags, referenced columns, required semantic tokens, and allowed string-literal cardinality without raw definition equality.
- Publish each workload run GUID through `CONTEXT_INFO` and correlate every current tagged memory grant directly from live DMVs; optional filtering retains nullable unparseable run IDs.
- Added a Microsoft.Data.SqlClient runner with TLS/certificate requirements, parameterized session context, transient SecureString conversion, DMK preparation, safe GO parsing, deterministic same-connection ordering, and guaranteed disposal.
- Added SQL contract fixtures and Pester parser/security/order tests.

## Validation

- RED: 3 SQL contract failures and 7 runner test failures before implementation.
- GREEN: focused SQL tests 93 passed; focused Pester tests 7 passed.
- Aggregate: Python 163 passed, 2 platform-dependent symlink tests skipped; Pester 261 passed; PSScriptAnalyzer 0 errors/warnings; `git diff --check` clean.
- No live Azure or SQL resources were used.
