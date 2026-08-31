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

# Task 10 diagnostic validation bypass fixes

## Root cause

- CHECK validation accepted constraints by required-token presence and string-literal count, so an appended tautology or additional predicate could preserve every weak signal.
- Generated SQL password approval treated any concatenation containing a variable-like reference as safe, even when a quoted literal supplied part of the password value.

## Fix

- Build isolated expected CHECK constraints in four local temporary tables, read SQL Server's normalized definitions from `tempdb.sys.check_constraints`, normalize only whitespace and identifier brackets, and compare complete SHA2-256 hashes bidirectionally while retaining exact flags and dependency checks. Temporary objects are dropped on success and in `CATCH`.
- Restrict generated SQL password approval to direct references, an exact `REPLACE` escape over a reference, or the runner's exact quote-delimited escaped-reference shape. Any nonempty quoted value fragment in a concatenation is rejected.
- Replaced token/count-oriented SQL tests and added scanner regression cases for literal-plus-reference expressions; retained the safe runner construction test.

## Validation

- RED: scanner Pester reported 3 expected failures; SQL contracts reported 2 expected failures before implementation.
- Focused GREEN: repository scanner 62 passed; SQL runner 7 passed; SQL contracts 94 passed.
- Strict aggregate GREEN: Python 164 passed with 2 platform-dependent symlink skips; Pester 323 passed; PowerShell syntax, PSScriptAnalyzer, JSON, tracked-file secret scan, static site, and whitespace gates passed with zero failures or warnings.
- No live SQL, Azure, or plan edits were used.
