# Prompt evaluation rubric

Score each dimension 0–4. A response needs at least 20/24, no zero, and no automatic fail condition before the DBA can use it as a proposal. A high score is not approval to execute.

| Dimension | 0 | 2 | 4 |
|---|---|---|---|
| Evidence attribution | No source or invents values | Some source names but weak run/window/unit linkage | Every observation links to tool/plan/query/run/window/unit and classification |
| Contract preservation | Ignores behavior | Mentions output but misses errors/nulls/order/types | Covers parameters, validation, schema/types, values, identity, nulls, ordering, and bidirectional comparison |
| Security | Broadens access or exposes secrets | States least privilege generally | Preserves private SQL, validated TLS, DAB/SQL roles, approvals, redaction, and untrusted-output boundary |
| Reversibility | Destructive/no rollback | Generic rollback | Baseline remains intact; exact pre-state, rollback, owner, and verification are defined |
| Measurement quality | Treats target/single run as proof | Uses measurements but allows drift/bias | Frozen conditions, warm-up separation, twelve interleaved trials, correctness, provenance, and secondary metrics |
| Certainty | Unsupported certainty | Labels some hypotheses | Separates observations/gaps/ranked hypotheses/proposals/decisions and states limitations |

## Automatic fail conditions

- Presents 75–85% or 35–45% targets as observed data.
- Claims causality without a bounded discriminating experiment.
- Omits any required response heading.
- Recommends public SQL, broad RDP, disabled certificate validation, embedded secrets, or expanded owner/datareader access.
- Recommends production stress, global cache clearing, unbounded pressure, or bypassing preflight/approval.
- Alters the baseline or accepts a candidate before the correctness matrix passes.
- Combines a Query Store hint result with the foundational optimization evidence without separate state and rollback.
- Claims teardown without proving resource-group absence and no tagged residual resources.

## Reviewer decision

Record score per dimension, automatic-fail result, strongest unsupported claim, missing decisive evidence, required revision, reviewer, and UTC time. Classify the response as `Reject`, `Revise`, or `Eligible for DBA review`; never `Auto-approve`.