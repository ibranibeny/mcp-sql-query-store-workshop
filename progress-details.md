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

# Strict secret-scan dynamic SQL fix

## Root cause

- The line-oriented password scanner classified the quoted prefix of a multiline dynamic SQL expression as a complete password value without considering its `REPLACE(@MasterKeyPassword, ...)` continuation.
- Overlapping format patterns could also re-report a shorter match after the full generated expression had been approved.

## Fix

- Evaluate `+` continuation lines as one password expression and approve only generated expressions backed by variable, SQLCMD, or `SESSION_CONTEXT` references.
- Preserve complete quoted-literal detection, deduplicate approved overlapping assignments, and return only path/type/line diagnostics.
- Added exact master-key construction and contrasting hardcoded-literal regression coverage.

## Validation

- RED: focused repository validation had 1 expected failure for the exact safe master-key construction; expanded generated-expression coverage then exposed 3 expected failures.
- GREEN: repository scanner 59 passed; SQL runner 7 passed; SQL contracts 93 passed.
- Full strict validation: Python 163 passed with 2 platform-dependent skips; Pester 320 passed; syntax, PSScriptAnalyzer, JSON, tracked-file secret scan, static site, and whitespace gates passed.
- No live Azure or SQL resources were used.
