# Scenario Hardening and Live Run Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the approved VS Code and SSMS scenarios publishable and evidence-safe, harden the bootstrap paths needed to finish the existing deployment, and execute the controlled live scenario without exposing SQL.

**Architecture:** Keep the existing two-VM private topology and one-baseline/two-independent-reviews/one-candidate workflow. Fix defects at their owning layer: content and manifest for Pages, SQL/PowerShell/Python for evidence contracts, bounded worker cleanup for runtime safety, and deployment-ID-bound scheduled-task evidence for bootstrap safety. Live operations begin only after code review, full validation, merge, push, and proof that no conflicting SQL VM extension mutation is active.

**Tech Stack:** PowerShell 7.4, Windows PowerShell 5.1 guest bootstrap, Pester 5, Python 3.12, pytest, T-SQL, SQL Server 2022 Enterprise, Data API Builder 2.0.9, GitHub Actions, GitHub Pages, Az PowerShell.

---

## Task 1: Publish the dual-tool scenario safely

**Files:**
- Modify: `tests/content/test_content_contract.py`
- Modify: `tests/web/test_build_site.py`
- Modify: `web/site-manifest.json`
- Modify: `workshop/scenario-a-vscode-scenario-b-ssms.md`
- Modify: `workshop/05-investigate-with-vscode.md`
- Modify: `workshop/06-optimize-and-prove.md`
- Modify: `README.md`
- Modify: `docs/facilitator-guide.md`
- Modify: `docs/attendee-guide.md`
- Modify: `docs/evidence-and-sources.md`
- Modify: `docs/superpowers/specs/2026-09-02-dual-copilot-sql-optimization-scenarios-design.md`

- [ ] **Step 1: Write failing content and build tests**

Add tests that require:

```python
SCENARIO = "workshop/scenario-a-vscode-scenario-b-ssms.md"
SCENARIO_ROUTE = "scenario-a-vscode-scenario-b-ssms.html"


def test_dual_copilot_scenario_is_routed_and_preserves_shared_evidence_contract() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    pages = manifest["pages"]
    scenario = next(page for page in pages if page["source"] == SCENARIO)
    assert scenario["route"] == SCENARIO_ROUTE
    assert scenario["durationMinutes"] == 0
    content = read(SCENARIO)
    for token in (
        "one baseline", "two independent Copilot reviews",
        "Candidate A", "Candidate B", "Approve-WorkshopCandidate.ps1",
        "ABBA BAAB ABBA",
    ):
        assert token in content


def test_dual_copilot_scenario_builds_with_one_h1_and_no_missing_internal_targets(
    tmp_path: Path,
) -> None:
    build_site(ROOT, tmp_path)
    path = tmp_path / SCENARIO_ROUTE
    assert path.is_file()
    soup = BeautifulSoup(path.read_text(encoding="utf-8"), "html.parser")
    assert len(soup.select("main h1")) == 1
    for link in soup.select("main a[href]"):
        href = link["href"]
        parsed = urlsplit(href)
        if parsed.scheme or parsed.netloc or href.startswith(("#", "mailto:")):
            continue
        assert (path.parent / parsed.path).resolve().exists()
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```powershell
.\.venv\Scripts\python.exe -m pytest tests/content/test_content_contract.py tests/web/test_build_site.py -q
```

Expected: failures because the manifest has no scenario route and the current content has unresolved links/multiple top-level headings.

- [ ] **Step 3: Implement the minimal content integration**

Add the scenario to the manifest after Workshop 06 as an untimed `Workshop resource`. Demote all scenario-internal top-level headings to level 2, replace source-code links with stable GitHub links, link the memory-pressure module to its HTML route, remove trailing whitespace, and cross-link the approved scenario from the existing entry points. Add official Microsoft Learn references for VS Code `/optimize`, SSMS `/optimize`, and SSMS Agent approval behavior.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same focused command. Expected: all selected tests pass.

- [ ] **Step 5: Commit Task 1**

```powershell
git add tests/content tests/web web/site-manifest.json workshop README.md docs
git commit -m "docs: publish dual Copilot optimization scenario"
```

## Task 2: Align and validate the cross-layer evidence contract

**Files:**
- Modify: `tests/sql/test_sql_contract.py`
- Modify: `tests/evidence/test_evidence_schema.py`
- Modify: `tests/powershell/Workshop.Workload.Tests.ps1`
- Modify: `sql/05-CreateDiagnostics.sql`
- Modify: `evidence/validate_evidence.py`
- Modify: `workload/Workshop.Workload.psm1`
- Modify: `evidence/evidence-schema.json` only if required to preserve the existing six-decimal contract

- [ ] **Step 1: Write failing cross-layer tests**

Require:

```python
def test_sample_grant_utilization_uses_six_decimal_storage_contract() -> None:
    sql = read_sql("05-CreateDiagnostics.sql")
    assert "GrantUtilizationPercent decimal(9,6)" in sql


def test_semantic_validator_rejects_secret_text_anywhere(valid_measured_document) -> None:
    document = copy.deepcopy(valid_measured_document)
    document["environment"]["warnings"] = ["Password=canary"]
    assert any("secret-shaped" in issue for issue in validate(document))


def test_semantic_validator_rejects_sample_outside_run_interval(valid_measured_document) -> None:
    document = copy.deepcopy(valid_measured_document)
    document["samples"][0]["sampledAtUtc"] = "2000-01-01T00:00:00Z"
    assert any("run interval" in issue for issue in validate(document))
```

Add static SQL tests requiring contiguous `TrialSequence` 1–12 and exact phase order `Baseline, Optimized, Optimized, Baseline, Optimized, Baseline, Baseline, Optimized, Baseline, Optimized, Optimized, Baseline`. Add a PowerShell test that rejects a request sample whose `(runId, phase, sampleSequence)` has no matching base sample and rejects `workerRampSeconds = 19`.

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/evidence/test_evidence_schema.py tests/sql/test_sql_contract.py -q
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
```

Expected: newly added tests fail for current two-decimal SQL metadata, nonrecursive Python secret checking, chronology/linkage gaps, absent persisted ABBA validation, and ramp minimum 10.

- [ ] **Step 3: Implement one evidence contract**

Use `decimal(9,6)` for persisted and returned grant-utilization percentages. Preserve rerun-safe metadata checks and migrations. Recursively inspect every evidence string for secret assignments. Require run and phase intervals to contain samples and request samples, require contiguous sequence identity, link every request sample to one base sample with the same run/phase/sequence, enforce exact persisted trial order in SQL, and set the internal worker-ramp minimum to 20.

For active-grant attribution, require the canonical program name:

```text
MCP-SQL-Workshop-<canonical run GUID>-<Baseline|Optimized>-<worker 1..4>
```

and require its run/phase values to agree with session context. Do not replace cleanup's exact ownership checks with a broad prefix.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run both focused commands again. Expected: all selected tests pass.

- [ ] **Step 5: Commit Task 2**

```powershell
git add tests/sql tests/evidence tests/powershell sql/05-CreateDiagnostics.sql evidence workload/Workshop.Workload.psm1
git commit -m "fix: enforce cross-layer evidence integrity"
```

## Task 3: Preserve the global runtime bound during worker cleanup

**Files:**
- Modify: `tests/powershell/Workshop.Workload.Tests.ps1`
- Modify: `workload/Workshop.Workload.psm1`
- Modify: `workload/Start-MemoryGrantLab.ps1`
- Modify: `workshop/04-create-memory-pressure.md`

- [ ] **Step 1: Write failing runtime-contract tests**

Add static/behavioral tests that reject any synchronous `.Stop()` in worker setup cleanup or `Dispose`, require `BeginStop`, bounded `WaitOne`, and conditional `EndStop`, and require a default comparison command timeout of 30 seconds while retaining `[ValidateRange(1, 60)]` and the 600-second global deadline.

- [ ] **Step 2: Run the focused test and verify RED**

```powershell
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
```

Expected: failures because setup cleanup and `Dispose` call synchronous `.Stop()` and the public default timeout is one second.

- [ ] **Step 3: Implement bounded cancellation and realistic trial timeout**

Replace synchronous worker stop calls with `BeginStop` plus a one-second wait. Call `EndStop` only after completion and never call unbounded `EndInvoke` for an unfinished cancellation. Keep the worker count at four, maximum duration at 600 seconds, and calculate each of the twelve trial budgets from remaining time. Change only the public default command timeout to 30 seconds; callers may still explicitly select 1–60 seconds.

Document that Query Store/DMV deltas can be contaminated by overlapping manual or external executions. Require no manual editor execution during the measured controller window and report this as a controlled-lab assumption rather than claiming read-only access solves attribution.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: all workload tests pass.

- [ ] **Step 5: Commit Task 3**

```powershell
git add tests/powershell/Workshop.Workload.Tests.ps1 workload workshop/04-create-memory-pressure.md
git commit -m "fix: bound worker cleanup and trial commands"
```

## Task 4: Bind SQL bootstrap completion and cleanup to the current deployment

**Files:**
- Modify: `tests/powershell/Bootstrap.Tests.ps1`
- Modify: `tests/powershell/Workshop.Azure.Tests.ps1`
- Modify: `deploy/Initialize-SqlVm.ps1`
- Modify: `deploy/Workshop.Azure.psm1`
- Modify: `deploy/Workshop.Azure.psd1` only if version metadata must be aligned

- [ ] **Step 1: Write failing bootstrap tests**

Require `Invoke-WorkshopAdministratorBootstrap` to remove any pre-existing completion file before task registration, accept readiness only when JSON contains the expected deployment ID and `Completed = true`, and fail if scheduled-task deletion cannot be positively verified. Require preflight to reject PowerShell below 7.4.

Require staging and extension update operations to hold a deterministic local deployment lock keyed by subscription/resource-group/VM and to stage deployment-specific payload filenames. The lock must be released in `finally` and must not be acquired while another SQL VM extension is `Updating`.

- [ ] **Step 2: Run focused tests and verify RED**

```powershell
Invoke-Pester tests/powershell/Bootstrap.Tests.ps1,tests/powershell/Workshop.Azure.Tests.ps1 -Output Detailed
```

Expected: newly added tests fail against existence-only completion checks, warning-only task cleanup, PowerShell 7.0 preflight, and fixed staging names.

- [ ] **Step 3: Implement deployment-bound bootstrap guards**

Add an expected deployment-ID parameter to the administrator bootstrap call, remove stale readiness before task launch, parse and validate newly created readiness, and fail closed if the temporary password-logon task remains. Use unique staged filenames and a bounded local lock before staging/extension mutation. Preserve CMS protection and never log credentials.

Align the PowerShell requirement to 7.4. Record unsupported DevTestLab scheduling as a preflight capability result and retain the verified local emergency-stop fallback for the current Indonesia Central deployment; do not pretend cross-region scheduling works.

- [ ] **Step 4: Run focused tests and verify GREEN**

Expected: selected Pester suites pass.

- [ ] **Step 5: Commit Task 4**

```powershell
git add tests/powershell deploy
git commit -m "fix: bind bootstrap evidence to deployment"
```

## Task 5: Review, merge, publish, and verify Pages

**Files:** all changed files from Tasks 1–4

- [ ] **Step 1: Run full repository validation**

```powershell
.\build\Test-Repository.ps1
```

Expected: Python, Pester, parser, PSScriptAnalyzer, JSON, evidence, secret scan, static site, and Git whitespace checks all pass.

- [ ] **Step 2: Request independent specification and quality review**

Review the complete branch against the approved design and audit findings. Resolve every Critical and Important issue and rerun focused/full validation after fixes.

- [ ] **Step 3: Merge into main and push**

Fast-forward main only after reviews and validation. Push `main` and verify local and remote SHAs match.

- [ ] **Step 4: Verify Pages**

Wait for the Pages workflow to complete, verify its conclusion is success, and verify both the root and `scenario-a-vscode-scenario-b-ssms.html` return HTTP 200 with the expected Scenario A/B navigation.

## Task 6: Finish live deployment readiness and execute the scenario

**Files/artifacts:**
- Existing Azure resources in `rg-mcp-sql-workshop`
- Ignored evidence under `evidence/runs/<run-id>/`
- Final `report.md` only after real measurements exist

- [ ] **Step 1: Recheck live resource and extension state**

Require both VM agents ready, no conflicting extension operation, SQL still has no public IP, admin RDP still exact `/32`, and SQL IaaS remains PAYG. Do not start a second guest mutation while the SQL bootstrap extension is active.

- [ ] **Step 2: Complete SQL and admin bootstrap from the reviewed commit**

If the current extension is terminally stale, capture its final status/log evidence first, then use the reviewed deployment-bound recovery path once. Validate SQL readiness, then bootstrap the admin VM and validate private DNS/TCP/TLS/DAB/MCP.

- [ ] **Step 3: Establish the RDP session**

Verify Azure IP flow, listener TLS/NLA, and interactive session. If GitHub Copilot sign-in is requested, pause only for the user to complete that interactive authentication.

- [ ] **Step 4: Run one shared baseline and two independent reviews**

Capture the controller baseline and exact evidence window. Run Scenario A in VS Code and save Candidate A. Keep it hidden while running Scenario B in SSMS and save Candidate B. Do not apply either directly from chat.

- [ ] **Step 5: Apply one candidate and prove it**

Use `Approve-WorkshopCandidate.ps1`, require equivalence success, execute exactly twelve `ABBA BAAB ABBA` trials, export reviewed evidence, and classify the actual outcome truthfully.

- [ ] **Step 6: Publish verified evidence and report**

Promote only verified/redacted screenshots, create `report.md` from actual evidence, rebuild/publish Pages, verify HTTP 200, and preserve teardown instructions. Email and teardown remain separate irreversible final actions requiring the previously agreed completion conditions.
