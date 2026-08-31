# MCP SQL Query Store Workshop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publicly publish a six-hour L400 workshop that demonstrates how GitHub Copilot, grounded by Microsoft's SQL MCP Server and verified SQL Server evidence, helps a DBA optimize a complex stored procedure from an approximately 80% query-grant baseline toward approximately 40% under unchanged conditions.

**Architecture:** A source-controlled static workshop site accompanies native Az PowerShell automation for a two-VM Azure lab in Indonesia Central. Only the Windows 11 administration VM has public ingress; the private 64-GiB SQL Server 2022 Enterprise VM is reachable only over the VNet. SQL Server Enterprise Resource Governor isolates the workload, Query Store and diagnostic procedures capture evidence, Data API Builder exposes a read-only SQL MCP surface, and a bounded PowerShell controller runs the baseline and optimized A/B experiment.

**Tech Stack:** PowerShell 7, Az PowerShell modules, Pester 5, PSScriptAnalyzer, T-SQL, SQL Server 2022 Enterprise, Resource Governor, Query Store, Data API Builder 2.x, VS Code MSSQL extension, GitHub Copilot, Python 3.12, Markdown, Jinja2, Python-Markdown, PyMdown Extensions, pytest, plain CSS/JavaScript, Mermaid, GitHub Actions, GitHub Pages, GitHub CLI.

---

## Delivery boundaries

- Repository implementation, tests, local site build, GitHub repository creation, and GitHub Pages publication are in scope.
- Creating Azure resources is not in scope until a separate explicit billable-deployment approval is given after the finished preflight script prints the plan card.
- No test may require an Azure subscription unless it is explicitly marked `Integration` and skipped by default.
- No real credential, connection string, public IP, certificate private key, or generated evidence file may be committed.
- Every benchmark result shown before a real lab run must be marked `TARGET` or `ILLUSTRATIVE`; only captured runs may use `LAB-MEASURED`.

## Planned file map

### Repository and validation

- `.gitignore` — excludes secrets, generated evidence, build output, local tool state, and certificate material.
- `LICENSE` — MIT license for workshop-authored code and content.
- `SECURITY.md` — responsible reporting and explicit warning not to use the stress workload in production.
- `requirements-dev.txt` — Python build and test dependencies with bounded major versions.
- `pyproject.toml` — pytest configuration.
- `PSScriptAnalyzerSettings.psd1` — PowerShell quality rules.
- `build/Install-DevDependencies.ps1` — installs Pester and PSScriptAnalyzer for the current user and prepares Python dependencies.
- `build/Test-Repository.ps1` — runs JSON, Python, PowerShell, secret, SQL-safety, link, and site checks.
- `tests/repository/test_repository_policy.py` — repository policy and secret-exclusion tests.

### Static workshop site

- `web/build_site.py` — validates the content manifest, converts Markdown, transforms Mermaid fences, and renders the site.
- `web/site-manifest.json` — ordered navigation and metadata.
- `web/templates/base.html` — accessible site shell.
- `web/templates/page.html` — module page template.
- `web/assets/styles.css` — query-plan workbench visual system.
- `web/assets/app.js` — navigation, copy controls, progress, evidence labels, and memory comparison widget.
- `tests/web/test_build_site.py` — generator and content-contract tests.
- `tests/web/test_site_dom.py` — generated DOM, navigation, accessibility, and asset tests.
- `index.html` and `assets/` — generated GitHub Pages entry point and assets.

### Azure automation

- `deploy/Workshop.Azure.psd1` — module manifest.
- `deploy/Workshop.Azure.psm1` — pure configuration builders plus Az-backed preflight, deployment, verification, stop, and removal functions.
- `deploy/WorkshopConfig.psd1` — approved defaults for region, network, VM sizes, images, disks, tags, and shutdown.
- `deploy/Test-WorkshopPrerequisites.ps1` — non-destructive preflight and plan card.
- `deploy/Deploy-WorkshopEnvironment.ps1` — confirmed creation path.
- `deploy/Initialize-SqlVm.ps1` — SQL VM bootstrap payload.
- `deploy/Initialize-AdminVm.ps1` — Windows 11 administration VM bootstrap payload.
- `deploy/Stop-WorkshopEnvironment.ps1` — deallocates both VMs.
- `deploy/Remove-WorkshopEnvironment.ps1` — typed-confirmation resource-group deletion and absence verification.
- `tests/powershell/Workshop.Azure.Tests.ps1` — Pester unit tests with Az commands mocked.
- `tests/powershell/EntryScripts.Tests.ps1` — syntax, confirmation, and parameter tests.

### SQL lab

- `sql/00-Preflight.sql` — identity, edition, version, memory, disk, and lab-marker checks.
- `sql/01-ConfigureInstance.sql` — captures prior settings; configures max memory, Resource Governor, classifier, and workload group.
- `sql/02-RestoreAndConfigureDatabase.sql` — restore verification and database configuration.
- `sql/03-CreateScaledLabData.sql` — bounded deterministic synthetic data generation.
- `sql/04-CreateBaselineProcedure.sql` — intentionally inefficient but bounded stored procedure.
- `sql/05-CreateDiagnostics.sql` — evidence schema, views, procedures, permissions, and MCP login contract.
- `sql/06-CreateOptimizedProcedure.sql` — contract-equivalent optimized procedure.
- `sql/07-ValidateEquivalence.sql` — deterministic correctness matrix and bidirectional difference checks.
- `sql/08-OptionalQueryStoreHint.sql` — set, inspect, test, clear, and verify a reversible hint.
- `sql/09-Cleanup.sql` — restores settings, disables/removes lab Resource Governor objects, and drops only marked lab objects.
- `tests/sql/test_sql_contract.py` — static SQL safety, ordering, idempotency, boundedness, and contract tests.

### Workload and evidence

- `workload/Workshop.Workload.psd1` — module manifest.
- `workload/Workshop.Workload.psm1` — pure state machine, sample evaluation, worker orchestration, and evidence serialization.
- `workload/Start-MemoryGrantLab.ps1` — runs baseline calibration, freezes conditions, runs optimized measurement, and performs interleaved A/B trials.
- `workload/Stop-MemoryGrantLab.ps1` — sets stop flag and terminates only doubly tagged sessions.
- `workload/Export-WorkshopEvidence.ps1` — exports JSON and CSV evidence without credentials.
- `evidence/evidence-schema.json` — schema for measured evidence.
- `evidence/example-targets.json` — target-only, non-measured example.
- `tests/powershell/Workshop.Workload.Tests.ps1` — state-machine and safety tests.
- `tests/evidence/test_evidence_schema.py` — schema and target-label tests.

### SQL MCP and VS Code

- `mcp/dab-config.json` — read-only DAB 2.x entities and custom tools.
- `mcp/.env.example` — secret-free connection string shape.
- `.vscode/mcp.json` — local stdio SQL MCP server definition.
- `.vscode/extensions.json` — recommended MSSQL and GitHub Copilot extensions.
- `.github/copilot-instructions.md` — evidence-first SQL tuning instructions.
- `tests/mcp/test_mcp_config.py` — deny-write, metadata, entity allowlist, and secret tests.

### Workshop content

- `README.md` — purpose, architecture, quick navigation, cost and safety warnings.
- `docs/facilitator-guide.md` — timing, setup, checkpoints, fallback paths, and cleanup.
- `docs/attendee-guide.md` — prerequisites, lab contract, evidence worksheet, and exercises.
- `docs/troubleshooting.md` — Azure, Windows licensing, SQL connectivity, DAB, MCP, Query Store, and workload failures.
- `docs/evidence-and-sources.md` — claim labels and official source inventory.
- `workshop/00-orientation.md` through `workshop/07-teardown.md` — six-hour sequential modules.
- `prompts/investigation-prompts.md` — structured GitHub Copilot prompts.
- `prompts/prompt-evaluation-rubric.md` — observation/hypothesis/proposal/decision scoring.

### GitHub automation

- `.github/workflows/validate.yml` — pull-request and push validation.
- `.github/workflows/pages.yml` — validated GitHub Pages deployment.

---

## Task 1: Establish repository policy and local validation entry point

**Files:**
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `requirements-dev.txt`
- Create: `pyproject.toml`
- Create: `PSScriptAnalyzerSettings.psd1`
- Create: `build/Install-DevDependencies.ps1`
- Create: `build/Test-Repository.ps1`
- Create: `tests/repository/test_repository_policy.py`

- [ ] **Step 1: Write failing repository-policy tests**

Create `tests/repository/test_repository_policy.py` with tests that require ignored secret/evidence patterns, MIT license text, the production-use warning, and bounded Python dependencies:

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_sensitive_and_generated_files_are_ignored() -> None:
    rules = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    required = {
        ".env",
        "*.pfx",
        "*.key",
        "evidence/runs/",
        "site/",
        ".venv/",
        "__pycache__/",
        ".pytest_cache/",
    }
    assert required.issubset(set(rules))


def test_license_is_mit() -> None:
    license_text = (ROOT / "LICENSE").read_text(encoding="utf-8")
    assert "MIT License" in license_text
    assert "2026" in license_text


def test_security_warning_blocks_production_stress_use() -> None:
    security = (ROOT / "SECURITY.md").read_text(encoding="utf-8").lower()
    assert "do not run the workload scripts against production" in security
    assert "security" in security and "report" in security


def test_dependencies_use_bounded_major_versions() -> None:
    requirements = (ROOT / "requirements-dev.txt").read_text(encoding="utf-8")
    assert "markdown>=3.7,<4" in requirements.lower()
    assert "jinja2>=3.1,<4" in requirements.lower()
    assert "pytest>=8,<10" in requirements.lower()
    assert "jsonschema>=4.23,<5" in requirements.lower()
```

- [ ] **Step 2: Run the tests and confirm the expected failure**

Run:

```powershell
python -m pytest tests/repository/test_repository_policy.py -q
```

Expected: failure because `.gitignore`, `LICENSE`, `SECURITY.md`, and dependency files do not yet exist.

- [ ] **Step 3: Add the repository foundation**

Create `.gitignore` with exactly these baseline rules:

```gitignore
.env
*.pfx
*.pfx.password
*.cer.private
*.key
*.bak
*.trc
*.xel
*.blg
*.sqlplan
evidence/runs/
site/
.venv/
__pycache__/
.pytest_cache/
.coverage
htmlcov/
TestResults/
.vscode/settings.json
*.user
.DS_Store
Thumbs.db
```

Create `requirements-dev.txt`:

```text
Markdown>=3.7,<4
Jinja2>=3.1,<4
pymdown-extensions>=10.12,<11
pytest>=8,<10
jsonschema>=4.23,<5
beautifulsoup4>=4.12,<5
```

Create `pyproject.toml`:

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra"
markers = [
  "integration: requires deployed Azure and SQL resources",
]
```

Create `PSScriptAnalyzerSettings.psd1`:

```powershell
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSAvoidUsingWriteHost')
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable = $true
            TargetVersions = @('7.4')
        }
    }
}
```

Create `LICENSE` using the standard MIT license text with copyright `2026 ibranibeny`. Create `SECURITY.md` with: supported scope, private vulnerability-reporting guidance through GitHub Security Advisories, a statement that no credential belongs in an issue, and the exact sentence `Do not run the workload scripts against production.`

Create `build/Install-DevDependencies.ps1` as an idempotent current-user installer:

```powershell
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($module in @(
    @{ Name = 'Pester'; MinimumVersion = [version]'5.6.1' },
    @{ Name = 'PSScriptAnalyzer'; MinimumVersion = [version]'1.23.0' }
)) {
    $installed = Get-Module -ListAvailable -Name $module.Name |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $installed -or $installed.Version -lt $module.MinimumVersion) {
        Install-Module -Name $module.Name -Scope CurrentUser -Force -AllowClobber -MinimumVersion $module.MinimumVersion
    }
}

if (-not (Test-Path '.venv')) {
    python -m venv .venv
}
& .\.venv\Scripts\python.exe -m pip install --upgrade pip
& .\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
```

Create `build/Test-Repository.ps1` to run Python tests, parse every PowerShell file with `Parser.ParseFile`, invoke PSScriptAnalyzer, parse every JSON file, scan tracked files for private-key markers and connection-string passwords, build the site, and fail if `git diff --check` fails. Keep each validation in a named function and aggregate failures so the report names the failing gate.

- [ ] **Step 4: Install dependencies and run the repository-policy test**

Run:

```powershell
.\build\Install-DevDependencies.ps1
.\.venv\Scripts\python.exe -m pytest tests/repository/test_repository_policy.py -q
```

Expected: `4 passed`.

- [ ] **Step 5: Commit the repository foundation**

```powershell
git add .gitignore LICENSE SECURITY.md requirements-dev.txt pyproject.toml PSScriptAnalyzerSettings.psd1 build tests/repository
git commit -m "chore: add workshop validation foundation"
```

## Task 2: Build the content manifest and static-site renderer

**Files:**
- Create: `web/site-manifest.json`
- Create: `web/build_site.py`
- Create: `web/templates/base.html`
- Create: `web/templates/page.html`
- Create: `tests/web/test_build_site.py`
- Create: `workshop/00-orientation.md`
- Create: `docs/facilitator-guide.md`

- [ ] **Step 1: Write failing site-generator tests**

Create `tests/web/test_build_site.py`:

```python
import json
from pathlib import Path

import pytest

from web.build_site import build_site, load_manifest

ROOT = Path(__file__).resolve().parents[2]


def test_manifest_has_unique_ordered_routes() -> None:
    manifest = load_manifest(ROOT / "web/site-manifest.json")
    routes = [page["route"] for page in manifest["pages"]]
    assert routes[0] == "index.html"
    assert len(routes) == len(set(routes))
    assert all(route.endswith(".html") for route in routes)


def test_build_emits_page_and_mermaid_markup(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    html = (tmp_path / "index.html").read_text(encoding="utf-8")
    assert "MCP SQL Query Store Workshop" in html
    assert '<pre class="mermaid">' in html
    assert 'data-evidence-label="TARGET"' in html


def test_missing_source_is_rejected(tmp_path: Path) -> None:
    manifest_path = ROOT / "web/site-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["pages"][0]["source"] = "workshop/missing.md"
    bad_manifest = tmp_path / "manifest.json"
    bad_manifest.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(FileNotFoundError):
        load_manifest(bad_manifest, root=ROOT)
```

- [ ] **Step 2: Run tests and confirm import/file failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/web/test_build_site.py -q
```

Expected: collection or test failure because the site builder and manifest are absent.

- [ ] **Step 3: Implement the deterministic site builder**

Create `web/site-manifest.json` with site metadata and an ordered page entry for each workshop module, facilitator guide, attendee guide, troubleshooting guide, source guide, and prompt guide. Each page object must contain `source`, `route`, `title`, `phase`, and `durationMinutes`.

Implement `web/build_site.py` with these public functions:

```python
from __future__ import annotations

import argparse
import html
import json
import re
import shutil
from pathlib import Path
from typing import Any

import markdown
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape

MERMAID_RE = re.compile(r'<pre><code class="language-mermaid">(.*?)</code></pre>', re.DOTALL)
EVIDENCE_RE = re.compile(r'\[!(DOC-VERIFIED|SUBSCRIPTION-VALIDATED|LAB-MEASURED|ASSUMPTION|TARGET)\]')


def load_manifest(path: Path, root: Path | None = None) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    base = root or path.parents[1]
    routes: set[str] = set()
    for page in manifest["pages"]:
        source = base / page["source"]
        if not source.is_file():
            raise FileNotFoundError(source)
        route = page["route"]
        if route in routes or not route.endswith(".html"):
            raise ValueError(f"Invalid or duplicate route: {route}")
        routes.add(route)
    return manifest


def render_markdown(text: str) -> str:
    rendered = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "toc", "pymdownx.superfences", "pymdownx.highlight"],
        extension_configs={"toc": {"permalink": True}},
    )
    rendered = MERMAID_RE.sub(lambda match: f'<pre class="mermaid">{html.unescape(match.group(1))}</pre>', rendered)
    return EVIDENCE_RE.sub(lambda match: f'<span class="evidence-label" data-evidence-label="{match.group(1)}">{match.group(1)}</span>', rendered)


def build_site(root: Path, destination: Path) -> None:
    manifest = load_manifest(root / "web/site-manifest.json", root=root)
    environment = Environment(
        loader=FileSystemLoader(root / "web/templates"),
        undefined=StrictUndefined,
        autoescape=select_autoescape(["html"]),
    )
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copytree(root / "web/assets", destination / "assets", dirs_exist_ok=True)
    page_template = environment.get_template("page.html")
    for index, page in enumerate(manifest["pages"]):
        source_text = (root / page["source"]).read_text(encoding="utf-8")
        output = page_template.render(
            site=manifest["site"],
            page=page,
            pages=manifest["pages"],
            content=render_markdown(source_text),
            previous=manifest["pages"][index - 1] if index else None,
            next=manifest["pages"][index + 1] if index + 1 < len(manifest["pages"]) else None,
        )
        (destination / page["route"]).write_text(output, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=Path("site"))
    args = parser.parse_args()
    build_site(args.root.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
```

Create accessible Jinja templates with one `main` landmark, skip link, header, ordered module navigation, article, previous/next links, and footer. Load `assets/styles.css`, `assets/app.js`, and Mermaid as an ES module. The templates must never interpolate raw manifest values without autoescaping; only rendered Markdown uses Jinja's `safe` filter.

Create `workshop/00-orientation.md` with a real Mermaid architecture excerpt, a `[!TARGET]` label beside the 80% → 40% objective, a production prohibition, and the two-VM security boundary. Create `docs/facilitator-guide.md` with the six-hour timing table and explicit preflight/deployment separation.

- [ ] **Step 4: Run the site tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/web/test_build_site.py -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit the renderer**

```powershell
git add web tests/web workshop/00-orientation.md docs/facilitator-guide.md
git commit -m "feat: add workshop static site renderer"
```

## Task 3: Implement the query-plan workbench visual system

**Files:**
- Create: `web/assets/styles.css`
- Create: `web/assets/app.js`
- Create: `tests/web/test_site_dom.py`
- Generate: `index.html`
- Generate: `assets/styles.css`
- Generate: `assets/app.js`

- [ ] **Step 1: Write failing DOM and asset tests**

Create `tests/web/test_site_dom.py`:

```python
from pathlib import Path

from bs4 import BeautifulSoup

from web.build_site import build_site

ROOT = Path(__file__).resolve().parents[2]


def built_page(tmp_path: Path) -> BeautifulSoup:
    build_site(ROOT, tmp_path)
    return BeautifulSoup((tmp_path / "index.html").read_text(encoding="utf-8"), "html.parser")


def test_page_has_accessible_landmarks_and_skip_link(tmp_path: Path) -> None:
    soup = built_page(tmp_path)
    assert soup.select_one('a[href="#main-content"]')
    assert len(soup.select("main")) == 1
    assert soup.select_one("nav[aria-label='Workshop modules']")


def test_assets_define_evidence_and_safety_tokens(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    css = (tmp_path / "assets/styles.css").read_text(encoding="utf-8")
    assert "--evidence-measured:" in css
    assert "--evidence-hypothesis:" in css
    assert "--safety-stop:" in css
    assert "@media (prefers-reduced-motion: reduce)" in css
    assert "@media print" in css


def test_script_has_copy_progress_and_memory_comparison(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    script = (tmp_path / "assets/app.js").read_text(encoding="utf-8")
    assert "navigator.clipboard.writeText" in script
    assert "localStorage" in script
    assert "grantUtilization" in script
    assert "targetStatus" in script
```

- [ ] **Step 2: Run the tests and confirm missing-asset failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/web/test_site_dom.py -q
```

Expected: failures because CSS and JavaScript do not exist.

- [ ] **Step 3: Implement the visual system and interactions**

Create `styles.css` with a restrained technical palette: canvas `#07131f`, panel `#0d2233`, text `#e7f2f8`, muted `#9ab0bf`, measured cyan `#35d0e8`, hypothesis amber `#f1b84b`, safety red `#ff5a65`, and decision green `#59d98e`. Define all colors as CSS custom properties. Use IBM Plex Sans-compatible system fallbacks for body and Cascadia Code-compatible fallbacks for code. Use execution-plan node shapes only in ordered phase navigation. Include focus-visible styles, 44-pixel minimum controls, responsive navigation, reduced motion, high contrast, and print styles.

Create `app.js` as an ES module with these pure helpers plus DOM adapters:

```javascript
export function grantUtilization(grantedKb, totalKb) {
  if (!Number.isFinite(grantedKb) || !Number.isFinite(totalKb) || totalKb <= 0 || grantedKb < 0) {
    throw new TypeError("Memory values must be finite and totalKb must be positive.");
  }
  return (grantedKb / totalKb) * 100;
}

export function targetStatus(baseline, optimized) {
  const baselineMet = baseline >= 75 && baseline <= 85;
  const optimizedMet = optimized >= 35 && optimized <= 45;
  if (baselineMet && optimizedMet) return "TargetMet";
  if (baseline - optimized >= 25) return "ImprovedOutsideTarget";
  return "NoMaterialImprovement";
}
```

Add event delegation for copy buttons, browser-local module completion, keyboard-friendly mobile navigation, and a memory comparison form that accepts granted and total KB for baseline and optimized runs. It must label target values as `TARGET` and never invent measured values.

- [ ] **Step 4: Build and test the site**

```powershell
.\.venv\Scripts\python.exe web/build_site.py --root . --output site
.\.venv\Scripts\python.exe -m pytest tests/web -q
Copy-Item site\index.html .\index.html -Force
Copy-Item site\assets .\assets -Recurse -Force
```

Expected: web tests pass and generated root assets exist.

- [ ] **Step 5: Commit the visual system and generated entry point**

```powershell
git add web/assets tests/web index.html assets
git commit -m "feat: add query-plan workbench experience"
```

## Task 4: Define Azure configuration and preflight as testable data

**Files:**
- Create: `deploy/Workshop.Azure.psd1`
- Create: `deploy/Workshop.Azure.psm1`
- Create: `deploy/WorkshopConfig.psd1`
- Create: `deploy/Test-WorkshopPrerequisites.ps1`
- Create: `tests/powershell/Workshop.Azure.Tests.ps1`

### Compliance follow-up research (2026-08-31)

- Verified baseline: commit `60d4e99` has 45 focused Pester tests passing and a clean worktree.
- Affected units are `deploy/Workshop.Azure.psm1`, `deploy/Test-WorkshopPrerequisites.ps1`, the module manifest, and `tests/powershell/Workshop.Azure.Tests.ps1`; there is no entry-script test file yet.
- Provider resource-type location metadata currently passes independently but explicitly does not validate the required Standard network SKUs. The preflight operation set therefore needs a required injectable `TestNetworkSkuDeployment` scriptblock.
- The default operation will build an in-memory subscription-scope ARM template using the `2018-05-01/subscriptionDeploymentTemplate.json#` schema. It will contain a temporary resource group plus a nested incremental resource-group deployment whose in-memory template contains exactly a Standard, Static, IPv4 public IP and a Standard NAT Gateway in the approved region. It will invoke only `Test-AzSubscriptionDeployment`; no template file or resource is created.
- Mocked operation results must independently drive `Network SKU Standard public IP` and `Network SKU Standard NAT Gateway`. Null, malformed, thrown, or error-bearing results fail closed with sanitized aggregate details; provider location checks remain separate.
- `BillableResourcesAcknowledged` is a mandatory Boolean through plan, preflight, and entry-script boundaries. The plan/card will enumerate Windows client compute/license responsibility, admin and SQL VM compute, SQL Enterprise PAYG, managed OS/data/log disks, two Standard public IPs, NAT hourly/data processing, and outbound transfer while stating that pricing was not queried.
- Decomposition verdict: atomic preflight compliance follow-up. Both findings change the same operation-set contract, plan object, plan card, entry point, and focused test suite. No modernization scenario skill root or breakdown-hint file was supplied for this task.
- Validation sequence: write focused failing Pester tests and capture RED; implement minimally; rerun focused Pester; run PSScriptAnalyzer; run the strict aggregate repository validation; verify static AST safety and commit only after all gates pass.

### Compliance follow-up progress details (append-only)

- Modified the preflight module, preflight entry script, focused Pester suite, and this execution reference; no Azure resource operation was run.
- Initial RED: 24 passed / 27 failed because the billable parameter and exact-SKU operation did not exist. Initial GREEN: 51 passed / 0 failed.
- Review regression RED: 51 passed / 1 failed for an error-bearing validation result that incorrectly passed. GREEN after fail-closed handling: 52 passed / 0 failed.
- Billable completeness RED: 50 passed / 2 failed until Private DNS zone/query charges were included alongside all user-specified categories.
- The default exact-SKU operation keeps the subscription and nested resource-group templates in memory and invokes validation only. Static tests reject mutating Az commands and constrain dynamic command invocation to the injected read-operation runner and the analyzer-compatible `Test-AzSubscriptionDeployment` resolution.
- Tenant ID remains optional and its existing omission test remains part of the focused suite. No deviations from the requested non-mutating Azure boundary were introduced.

- [ ] **Step 1: Write failing Pester tests for approved defaults and boundaries**

Create tests that import the module and assert:

```powershell
Describe 'Workshop configuration' {
    BeforeAll {
        Import-Module "$PSScriptRoot/../../deploy/Workshop.Azure.psd1" -Force
        $script:Config = Import-PowerShellDataFile "$PSScriptRoot/../../deploy/WorkshopConfig.psd1"
    }

    It 'uses the approved region and VM sizes' {
        $Config.Location | Should -Be 'indonesiacentral'
        $Config.AdminVm.Size | Should -Be 'Standard_D4s_v5'
        $Config.SqlVm.Size | Should -Be 'Standard_E8s_v5'
    }

    It 'assigns a public IP only to the administration VM' {
        $model = New-WorkshopNetworkModel -Config $Config -FacilitatorCidr '203.0.113.8/32'
        $model.Admin.PublicIpEnabled | Should -BeTrue
        $model.Sql.PublicIpEnabled | Should -BeFalse
    }

    It 'allows SQL only from the administration ASG' {
        $model = New-WorkshopNetworkModel -Config $Config -FacilitatorCidr '203.0.113.8/32'
        $sqlRule = $model.Sql.Rules | Where-Object Name -eq 'Allow-Admin-To-Sql'
        $sqlRule.SourceAsg | Should -Be 'asg-mcpsql-admin'
        $sqlRule.DestinationPort | Should -Be 1433
        $sqlRule.SourcePrefix | Should -BeNullOrEmpty
    }

    It 'rejects broad or non-host facilitator ranges' {
        { Assert-WorkshopHostCidr '0.0.0.0/0' } | Should -Throw
        { Assert-WorkshopHostCidr '198.51.100.0/24' } | Should -Throw
        { Assert-WorkshopHostCidr '198.51.100.22/32' } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Run Pester and confirm module-not-found failure**

```powershell
Invoke-Pester tests/powershell/Workshop.Azure.Tests.ps1 -Output Detailed
```

Expected: failure because the module does not exist.

- [ ] **Step 3: Implement the configuration module and defaults**

Create `WorkshopConfig.psd1` with concrete approved values:

```powershell
@{
    Location = 'indonesiacentral'
    ResourceGroupName = 'rg-mcp-sql-workshop'
    VNet = @{ Name = 'vnet-mcpsql-workshop'; AddressPrefix = '10.20.0.0/16' }
    AdminSubnet = @{ Name = 'snet-admin'; Prefix = '10.20.1.0/24'; DefaultOutboundAccess = $false }
    SqlSubnet = @{ Name = 'snet-sql'; Prefix = '10.20.2.0/24'; DefaultOutboundAccess = $false }
    AdminAsg = 'asg-mcpsql-admin'
    SqlAsg = 'asg-mcpsql-sql'
    PrivateDnsZone = 'mcpworkshop.internal'
    SqlPrivateIp = '10.20.2.10'
    AdminVm = @{
        Name = 'vm-mcpsql-admin'
        Size = 'Standard_D4s_v5'
        Publisher = 'MicrosoftWindowsDesktop'
        Offer = 'windows-11'
        Sku = 'win11-24h2-ent'
        OsDiskGiB = 128
    }
    SqlVm = @{
        Name = 'vm-mcpsql-sql'
        Size = 'Standard_E8s_v5'
        Publisher = 'MicrosoftSQLServer'
        Offer = 'SQL2022-WS2022'
        Sku = 'enterprise-gen2'
        OsDiskGiB = 128
        DataDiskGiB = 256
        LogDiskGiB = 128
        LicenseType = 'PAYG'
    }
    AutoShutdownTime = '1900'
    Tags = @{ environment = 'workshop'; workload = 'mcp-sql'; managedBy = 'PowerShell' }
}
```

Implement and export `Assert-WorkshopHostCidr`, `New-WorkshopNetworkModel`, `Get-WorkshopPlan`, `Test-WorkshopPrerequisites`, and `Format-WorkshopPlanCard`. Keep model-building functions free of Az calls. `Test-WorkshopPrerequisites` must validate Az modules, context, providers, exact image versions, SKU restrictions, family quota, resource-name collisions, source CIDR, licensing attestations, and price-category acknowledgement. It returns an object with `Passed`, `Checks`, `ResolvedImages`, and `Plan`; it never creates or registers anything.

The plan card must state `SQL public IP: none`, `Public ingress: Windows 11 RDP from <cidr> only`, `SQL ingress: Admin ASG to SQL ASG TCP 1433`, and list every billable category.

- [ ] **Step 4: Run Pester and verify all pure preflight tests pass**

```powershell
Invoke-Pester tests/powershell/Workshop.Azure.Tests.ps1 -Output Detailed
```

Expected: all tests pass without Azure writes.

- [ ] **Step 5: Commit configuration and preflight**

```powershell
git add deploy/Workshop.Azure.* deploy/WorkshopConfig.psd1 deploy/Test-WorkshopPrerequisites.ps1 tests/powershell/Workshop.Azure.Tests.ps1
git commit -m "feat: add non-destructive Azure workshop preflight"
```

## Task 5: Implement private network deployment and boundary verification

**Files:**
- Modify: `deploy/Workshop.Azure.psm1`
- Create: `deploy/Deploy-WorkshopEnvironment.ps1`
- Modify: `tests/powershell/Workshop.Azure.Tests.ps1`
- Create: `tests/powershell/EntryScripts.Tests.ps1`

- [ ] **Step 1: Add failing tests for network resource calls and confirmation**

Mock Az cmdlets and assert that `New-WorkshopNetwork` creates two private subnets, one NAT Gateway, two ASGs, separate subnet NSGs, one administration public IP, and no SQL public IP. Assert that a deny rule with priority lower than 65000 blocks other VNet traffic to the SQL subnet after the explicit admin rules. Assert that `Deploy-WorkshopEnvironment.ps1` requires both `-WindowsClientLicenseAttested` and `-ApproveBillableDeployment`.

Core assertion:

```powershell
It 'never creates an SQL public IP' {
    Mock New-AzPublicIpAddress { [pscustomobject]@{ Id = '/pip/mock' } }
    New-WorkshopNetwork -Config $Config -FacilitatorCidr '203.0.113.8/32'
    Should -Invoke New-AzPublicIpAddress -Times 1 -Exactly -ParameterFilter {
        $Name -eq 'pip-mcpsql-admin'
    }
}
```

- [ ] **Step 2: Run Pester and confirm missing-function failures**

```powershell
Invoke-Pester tests/powershell -Output Detailed
```

Expected: failures for `New-WorkshopNetwork`, `Test-WorkshopNetworkBoundary`, and deployment confirmation.

- [ ] **Step 3: Implement network creation and verification**

Implement `New-WorkshopNetwork` with idempotent get-or-create behavior and positive reads after each operation. Use subnet-level NSGs only. Create:

- `Allow-Facilitator-Rdp` on the administration NSG: TCP 3389 from the supplied `/32`.
- `Allow-Admin-To-Sql`: TCP 1433 from admin ASG to SQL ASG.
- `Allow-Admin-To-Sql-Rdp`: TCP 3389 from admin ASG to SQL ASG.
- `Deny-Other-VNet-To-Sql`: all protocols from `VirtualNetwork` to SQL ASG at priority 4000.

Associate a NAT Gateway with both private subnets. Implement `Test-WorkshopNetworkBoundary` to read back NIC/public-IP associations and effective rule intent. It fails if the SQL NIC has a public IP, any custom rule permits public 1433/1434, the administration RDP source is broader than `/32`, or either subnet lacks explicit outbound NAT.

Create `Deploy-WorkshopEnvironment.ps1` with `SupportsShouldProcess`, mandatory subscription ID and credentials, typed booleans for both approvals, preflight invocation, plan-card display, and an exact prompt requiring `DEPLOY rg-mcp-sql-workshop`. It calls no create function unless every preflight check passes and the phrase matches.

- [ ] **Step 4: Run the network and entry-script tests**

```powershell
Invoke-Pester tests/powershell -Output Detailed
```

Expected: all tests pass with Az calls mocked.

- [ ] **Step 5: Commit network deployment**

```powershell
git add deploy tests/powershell
git commit -m "feat: deploy private two-tier workshop network"
```

## Task 6: Implement VM creation, lifecycle, and immutable image resolution

**Files:**
- Modify: `deploy/Workshop.Azure.psm1`
- Create: `deploy/Stop-WorkshopEnvironment.ps1`
- Create: `deploy/Remove-WorkshopEnvironment.ps1`
- Modify: `tests/powershell/Workshop.Azure.Tests.ps1`
- Modify: `tests/powershell/EntryScripts.Tests.ps1`

- [ ] **Step 1: Add failing VM and lifecycle tests**

Tests must assert:

- image `latest` is resolved with `Get-AzVMImage` and the version passed to `Set-AzVMSourceImage` is immutable;
- Windows 11 uses Trusted Launch, secure boot, vTPM, and `LicenseType = Windows_Client` only after attestation;
- SQL VM uses the SQL Enterprise image, `Standard_E8s_v5`, PAYG SQL IaaS registration, and no public IP;
- shutdown schedules exist for both VMs;
- stop deallocates both VMs;
- remove requires the exact resource-group name and verifies `Get-AzResourceGroup` returns absent.

- [ ] **Step 2: Run tests and confirm missing VM/lifecycle behavior**

```powershell
Invoke-Pester tests/powershell -Output Detailed
```

Expected: failures for image resolution, VM creation, stop, and remove.

- [ ] **Step 3: Implement VM and lifecycle functions**

Add module functions `Resolve-WorkshopImageVersion`, `New-WorkshopAdminVm`, `New-WorkshopSqlVm`, `Register-WorkshopSqlIaas`, `Set-WorkshopAutoShutdown`, `Stop-WorkshopEnvironment`, and `Remove-WorkshopEnvironment`.

Use `New-AzVMConfig`, `Set-AzVMOperatingSystem`, `Set-AzVMSourceImage`, `Set-AzVMSecurityProfile`, `Set-AzVmUefi`, `Add-AzVMNetworkInterface`, and `New-AzVM`. Attach only the administration public IP to the administration NIC. Add data and log managed disks to SQL VM. Register SQL IaaS with `New-AzSqlVM -LicenseType PAYG` and verify the SQL virtual machine resource exists.

Create thin lifecycle entry scripts. Removal must require the phrase `DELETE rg-mcp-sql-workshop`, call `Remove-AzResourceGroup`, wait for terminal deletion state without sleeping in tests, and throw if any tagged resources remain.

- [ ] **Step 4: Run Pester and parse all PowerShell**

```powershell
Invoke-Pester tests/powershell -Output Detailed
Get-ChildItem deploy -Filter *.ps1 -Recurse | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $errors | Should -BeNullOrEmpty
}
```

Expected: all tests pass and no parser errors.

- [ ] **Step 5: Commit VM lifecycle automation**

```powershell
git add deploy tests/powershell
git commit -m "feat: add workshop VM lifecycle automation"
```

## Task 7: Add SQL safety preflight, instance configuration, and Resource Governor

**Files:**
- Create: `sql/00-Preflight.sql`
- Create: `sql/01-ConfigureInstance.sql`
- Create: `tests/sql/test_sql_contract.py`

- [ ] **Step 1: Write failing static SQL contract tests**

Create tests that require SQLCMD variables, `THROW` guards, SQL Server 2022 Enterprise checks, a lab marker, Query Store checks, Resource Governor classifier by application name, `MIN_MEMORY_PERCENT = 0`, a bounded `MAX_MEMORY_PERCENT`, and restoration metadata. Ban `DBCC DROPCLEANBUFFERS`, global `DBCC FREEPROCCACHE`, `WHILE 1=1`, and public-network commands across all SQL files.

```python
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SQL_DIR = ROOT / "sql"


def sql(name: str) -> str:
    return (SQL_DIR / name).read_text(encoding="utf-8")


def test_preflight_requires_enterprise_2022_and_lab_marker() -> None:
    text = sql("00-Preflight.sql").upper()
    assert "SERVERPROPERTY('PRODUCTMAJORVERSION')" in text
    assert "SERVERPROPERTY('EDITION')" in text
    assert "ENTERPRISE" in text
    assert "MCP_SQL_WORKSHOP" in text
    assert "THROW" in text


def test_resource_governor_is_bounded_and_classified() -> None:
    text = sql("01-ConfigureInstance.sql").upper()
    assert "CREATE RESOURCE POOL [MCP_SQL_WORKSHOP_POOL]" in text
    assert "MIN_MEMORY_PERCENT = 0" in text
    assert "MAX_MEMORY_PERCENT = 50" in text
    assert "APP_NAME()" in text
    assert "MCP-SQL-WORKSHOP" in text


def test_dangerous_global_cache_commands_are_absent() -> None:
    combined = "\n".join(path.read_text(encoding="utf-8").upper() for path in SQL_DIR.glob("*.sql"))
    assert "DBCC DROPCLEANBUFFERS" not in combined
    assert "DBCC FREEPROCCACHE" not in combined
    assert "WHILE 1=1" not in combined
```

- [ ] **Step 2: Run SQL static tests and confirm missing-file failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: failures because SQL scripts do not exist.

- [ ] **Step 3: Implement guarded preflight and Resource Governor setup**

`00-Preflight.sql` must run in SQLCMD mode with variables `ExpectedServerName`, `DatabaseName`, and `ExpectedPhysicalMemoryMB`. It throws unless the major version is 16, edition contains `Enterprise`, host memory is between 63,000 and 66,000 MB, the database exists, and a server-level extended property or database marker identifies this lab.

`01-ConfigureInstance.sql` must:

1. create `WorkshopAdmin.ConfigurationBackup` in a dedicated utility database;
2. record current max/min server memory, Query Store options, memory grant feedback settings, Resource Governor state, and prior classifier function;
3. set max server memory to 49,152 MB and min server memory to 0;
4. create resource pool `mcp_sql_workshop_pool` with `MIN_MEMORY_PERCENT = 0` and `MAX_MEMORY_PERCENT = 50`;
5. create workload group `mcp_sql_workshop_group` with `REQUEST_MAX_MEMORY_GRANT_PERCENT = 40`, `MAX_DOP = 4`, and `GROUP_MAX_REQUESTS = 4`;
6. create schema-bound classifier function `dbo.mcp_sql_workshop_classifier()` that returns the group only when `APP_NAME()` starts with `MCP-SQL-Workshop`;
7. preserve any existing classifier and refuse to replace a non-workshop classifier automatically;
8. reconfigure Resource Governor and verify effective DMV state.

Every create/alter statement must be idempotent or preceded by an exact-state check. Cleanup metadata must contain the values needed to restore prior configuration.

- [ ] **Step 4: Run SQL static tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: all current tests pass.

- [ ] **Step 5: Commit SQL safety and isolation**

```powershell
git add sql/00-Preflight.sql sql/01-ConfigureInstance.sql tests/sql
git commit -m "feat: isolate workshop query memory with Resource Governor"
```

## Task 8: Restore AdventureWorks and generate bounded synthetic data

**Files:**
- Create: `sql/02-RestoreAndConfigureDatabase.sql`
- Create: `sql/03-CreateScaledLabData.sql`
- Modify: `tests/sql/test_sql_contract.py`

- [ ] **Step 1: Add failing restore and bounded-generation tests**

Require `RESTORE VERIFYONLY`, `RESTORE FILELISTONLY`, explicit `MOVE` paths, Query Store `READ_WRITE`, compatibility level 160, batch-size and max-row SQLCMD variables, free-space validation, fixed seed logic, `TOP (@BatchSize)`, and no unbounded cross join.

- [ ] **Step 2: Run the tests and confirm failure**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: failures for missing restore and data scripts.

- [ ] **Step 3: Implement restore/configuration and deterministic data generation**

`02-RestoreAndConfigureDatabase.sql` accepts backup, data, and log paths. It verifies the backup, reads logical names, restores only when the target database is absent, sets compatibility level 160, enables Query Store with bounded storage/retention settings, verifies `actual_state_desc = READ_WRITE`, and creates `lab.WorkshopMarker` containing a fixed marker GUID and schema version.

`03-CreateScaledLabData.sql` creates:

- `lab.Numbers` with a primary key and exactly the bounded sequence required for generation;
- `lab.FactSales` with order date, territory, customer, product, quantity, price, amount, and a deterministic wide payload used only by the baseline query shape;
- clustered storage optimized for deterministic loading;
- a narrow index used by the optimized procedure only after the baseline capture checkpoint.

Use variables `TargetRows = 8000000`, `BatchSize = 100000`, `MinimumFreeSpaceMB = 65536`, and `MaximumDataFileSizeMB = 65536`. Generate dates and keys from deterministic modular arithmetic over `lab.Numbers` and AdventureWorks key tables. Commit each batch, write progress to `lab.DataGenerationLog`, and stop if the row cap, file-size cap, or free-space floor is reached. A rerun resumes from the last committed synthetic key and never duplicates rows.

- [ ] **Step 4: Run SQL contract tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: tests pass and all generation loops are statically bounded.

- [ ] **Step 5: Commit restore and data generation**

```powershell
git add sql/02-RestoreAndConfigureDatabase.sql sql/03-CreateScaledLabData.sql tests/sql
git commit -m "feat: add bounded AdventureWorks lab dataset"
```

## Task 9: Create baseline and optimized stored procedures with equivalent contracts

**Files:**
- Create: `sql/04-CreateBaselineProcedure.sql`
- Create: `sql/06-CreateOptimizedProcedure.sql`
- Create: `sql/07-ValidateEquivalence.sql`
- Modify: `tests/sql/test_sql_contract.py`

- [ ] **Step 1: Add failing procedure-contract tests**

Parse both procedure headers and assert identical parameter names/types/defaults. Require the baseline to contain a non-SARGable date conversion, wide intermediate payload, repeated fact access, hash aggregate, and sort. Require the optimized procedure to use a half-open date predicate, early projection, one fact access path, pre-aggregation, and the optimized index. Require bidirectional `EXCEPT`, row counts, metadata comparison, result hashes, and a concrete parameter matrix in the validation script.

- [ ] **Step 2: Run tests and confirm missing-procedure failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: failures for missing procedures and validation script.

- [ ] **Step 3: Implement the two procedures and correctness harness**

Both procedures use this exact signature:

```sql
@StartDate date,
@EndDateExclusive date,
@TerritoryID int = NULL,
@TopCount int = 100
```

Both reject invalid ranges, ranges over 366 days, `@TopCount` outside 1–1000, and unknown territories. Both return:

```text
TerritoryID int
CustomerID int
ProductID int
OrderCount bigint
TotalQuantity bigint
TotalSales decimal(38,4)
AverageUnitPrice decimal(19,4)
SalesRank bigint
```

The baseline intentionally applies `CONVERT(date, OrderDate)` in the filter, carries the wide payload through an intermediate materialization, scans the fact source twice, aggregates late, and sorts a wider rowset. The optimized version uses `OrderDate >= @StartDate AND OrderDate < @EndDateExclusive`, filters territory early, projects only required columns, aggregates once at the output grain, and calculates rank after the narrow aggregate. Do not add a hint that forces an artificially bad plan to the baseline.

`07-ValidateEquivalence.sql` executes both into typed temp tables for at least eight fixed cases, compares `sp_describe_first_result_set` metadata, row counts, bidirectional `EXCEPT`, and deterministic hashes. It throws with case name and difference count on any mismatch and writes passing cases to `lab.ValidationRun`.

- [ ] **Step 4: Run SQL contract tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: all procedure and correctness contracts pass statically.

- [ ] **Step 5: Commit stored procedure pair**

```powershell
git add sql/04-CreateBaselineProcedure.sql sql/06-CreateOptimizedProcedure.sql sql/07-ValidateEquivalence.sql tests/sql
git commit -m "feat: add equivalent baseline and optimized procedures"
```

## Task 10: Add diagnostic contract, evidence tables, and least-privileged SQL MCP login

**Files:**
- Create: `sql/05-CreateDiagnostics.sql`
- Modify: `tests/sql/test_sql_contract.py`

- [ ] **Step 1: Add failing diagnostic and permission tests**

Require bounded diagnostic procedures:

- `lab.usp_GetMemorySnapshot`;
- `lab.usp_GetActiveWorkshopGrants`;
- `lab.usp_GetQueryStoreTopQueries`;
- `lab.usp_GetQueryStoreWaits`;
- `lab.usp_GetProcedurePlanSummary`;
- `lab.usp_CompareWorkshopRuns`.

Require `@Top` limits, time-window limits, `EXECUTE AS OWNER` or module signing, a dedicated `mcp_workshop_reader` user, explicit `GRANT EXECUTE`, and explicit `DENY INSERT, UPDATE, DELETE, ALTER, CONTROL`. Require no `db_datareader`, `db_owner`, or server role membership.

- [ ] **Step 2: Run tests and confirm missing diagnostics**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: failures for diagnostic and permission requirements.

- [ ] **Step 3: Implement bounded diagnostics and evidence persistence**

Create tables `lab.WorkshopRun`, `lab.WorkshopSample`, `lab.WorkshopRequestSample`, and `lab.ValidationRun`. `WorkshopSample` records timestamp, phase, pool total/granted/used/available KB, utilization percent, grantee/waiter counts, host available MB, SQL process MB, Total Server Memory MB, Target Server Memory MB, and low-memory flags.

Diagnostic procedures expose only workshop-tagged sessions or bounded Query Store windows. `usp_GetMemorySnapshot` calculates:

```sql
CAST(100.0 * rs.granted_memory_kb / NULLIF(rs.total_memory_kb, 0) AS decimal(6,2))
```

for the regular semaphore of `mcp_sql_workshop_pool`. `usp_CompareWorkshopRuns` returns baseline and optimized peak/median grant utilization plus duration, CPU, reads, spills, wait time, and final outcome.

Create contained user/login setup driven by SQLCMD secret variables at bootstrap time, but do not put a password literal in source. Grant only execution on the six diagnostics and select on deliberately exposed summary views. Add negative permission verification with `EXECUTE AS USER` and `HAS_PERMS_BY_NAME`.

- [ ] **Step 4: Run SQL contract tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: all static diagnostics and least-privilege tests pass.

- [ ] **Step 5: Commit diagnostics**

```powershell
git add sql/05-CreateDiagnostics.sql tests/sql
git commit -m "feat: expose least-privileged workshop diagnostics"
```

## Task 11: Implement the bounded workload state machine and evidence schema

**Files:**
- Create: `workload/Workshop.Workload.psd1`
- Create: `workload/Workshop.Workload.psm1`
- Create: `evidence/evidence-schema.json`
- Create: `evidence/example-targets.json`
- Create: `tests/powershell/Workshop.Workload.Tests.ps1`
- Create: `tests/evidence/test_evidence_schema.py`

- [ ] **Step 1: Write failing state-machine and schema tests**

Pester cases must cover:

```powershell
Describe 'Get-WorkshopOutcome' {
    It 'returns TargetMet only for both approved bands' {
        Get-WorkshopOutcome -BaselinePeak 80 -OptimizedPeak 40 -CorrectnessPassed $true -MaterialRegression $false |
            Should -Be 'TargetMet'
    }

    It 'does not invent target success' {
        Get-WorkshopOutcome -BaselinePeak 80 -OptimizedPeak 51 -CorrectnessPassed $true -MaterialRegression $false |
            Should -Be 'ImprovedOutsideTarget'
    }

    It 'rejects a candidate with correctness failure' {
        Get-WorkshopOutcome -BaselinePeak 80 -OptimizedPeak 40 -CorrectnessPassed $false -MaterialRegression $false |
            Should -Be 'Failed'
    }
}

Describe 'Test-WorkshopSafetySample' {
    It 'stops above host safety utilization' {
        Test-WorkshopSafetySample -HostUsedPercent 88 -HostAvailableMB 9000 -ProcessPhysicalLow $false -ProcessVirtualLow $false |
            Should -Be 'SafetyStop'
    }
}
```

Python tests validate `example-targets.json` against the schema and require `evidenceClassification = TARGET`, null measured values, baseline band 75–85, and optimized band 35–45.

- [ ] **Step 2: Run tests and confirm missing module/schema failures**

```powershell
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
.\.venv\Scripts\python.exe -m pytest tests/evidence -q
```

Expected: failures because workload files are absent.

- [ ] **Step 3: Implement pure outcome and safety functions plus schema**

Export pure functions:

- `Get-GrantUtilization`;
- `Test-TargetBand`;
- `Test-WorkshopSafetySample`;
- `Get-WorkshopOutcome`;
- `New-WorkshopRunRecord`;
- `ConvertTo-WorkshopEvidence`.

`Get-WorkshopOutcome` returns only `TargetMet`, `ImprovedOutsideTarget`, `NoMaterialImprovement`, `BaselineTargetNotReached`, `SafetyStop`, `ManualStop`, or `Failed`. It requires correctness for any success state and never uses target values when measured values are null.

Define a JSON Schema requiring run ID, UTC timestamps, environment fingerprint, frozen A/B settings, target bands, measured samples, correctness result, outcome, and evidence classification. The target example must contain no field implying an executed benchmark.

- [ ] **Step 4: Run workload and evidence tests**

```powershell
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
.\.venv\Scripts\python.exe -m pytest tests/evidence -q
```

Expected: all tests pass.

- [ ] **Step 5: Commit state machine and evidence contract**

```powershell
git add workload evidence tests/powershell/Workshop.Workload.Tests.ps1 tests/evidence
git commit -m "feat: add truthful memory grant evidence model"
```

## Task 12: Implement baseline calibration, frozen optimized run, stop, and export

**Files:**
- Modify: `workload/Workshop.Workload.psm1`
- Create: `workload/Start-MemoryGrantLab.ps1`
- Create: `workload/Stop-MemoryGrantLab.ps1`
- Create: `workload/Export-WorkshopEvidence.ps1`
- Modify: `tests/powershell/Workshop.Workload.Tests.ps1`

- [ ] **Step 1: Add failing orchestration tests with mocked SQL calls**

Test that orchestration:

- verifies the lab marker and Enterprise edition;
- starts one worker and adds at most one every twenty seconds;
- never exceeds four workers or ten minutes;
- freezes worker count and parameter schedule after three baseline samples in 75–85%;
- uses those exact conditions for the optimized phase;
- does not alter pool, server memory, data, index, or database-scoped settings between phases;
- stops on host used memory over 87.5%, host available memory under 8 GiB, or SQL low-memory flags;
- terminates only sessions with both application-name and session-context tags;
- exports measured values rather than target values.

- [ ] **Step 2: Run Pester and confirm orchestration failures**

```powershell
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
```

Expected: failures for worker orchestration and evidence export.

- [ ] **Step 3: Implement bounded orchestration**

Use `Microsoft.Data.SqlClient` when available and fall back to `System.Data.SqlClient` only with an explicit warning in the readiness report. Every worker connection sets `Application Name=MCP-SQL-Workshop-<run-id>-<phase>-<worker>` and calls `sp_set_session_context` with the same run ID.

`Start-MemoryGrantLab.ps1` parameters have concrete bounds:

```powershell
[ValidateRange(1,4)][int]$MaximumWorkers = 4
[ValidateRange(60,600)][int]$MaximumDurationSeconds = 600
[ValidateRange(5,30)][int]$SampleIntervalSeconds = 5
[ValidateRange(10,60)][int]$WorkerRampSeconds = 20
```

Baseline workers run the baseline procedure using a fixed round-robin parameter schedule. When calibration succeeds, serialize and hash the frozen settings before stopping baseline workers. Optimized workers receive the exact serialized settings. After the target measurement, run twelve interleaved A/B trials using an `ABBA BAAB ABBA` order and write all results to evidence tables.

`Stop-MemoryGrantLab.ps1` creates a stop file and invokes a bounded cancellation procedure that verifies both tags before issuing `KILL` for each matching session. `Export-WorkshopEvidence.ps1` writes schema-valid JSON plus CSV samples to `evidence/runs/<run-id>/` and scans string fields for password/connection-string patterns before writing.

- [ ] **Step 4: Run workload tests**

```powershell
Invoke-Pester tests/powershell/Workshop.Workload.Tests.ps1 -Output Detailed
```

Expected: all state, safety, frozen-condition, and export tests pass.

- [ ] **Step 5: Commit workload controller**

```powershell
git add workload tests/powershell/Workshop.Workload.Tests.ps1
git commit -m "feat: orchestrate bounded 80-to-40 grant experiment"
```

## Task 13: Add optional Query Store hint and complete cleanup

**Files:**
- Create: `sql/08-OptionalQueryStoreHint.sql`
- Create: `sql/09-Cleanup.sql`
- Modify: `tests/sql/test_sql_contract.py`

- [ ] **Step 1: Add failing hint-lifecycle and cleanup tests**

Require the hint script to discover `query_id`, set a conservative hint, inspect `sys.query_store_query_hints`, clear it, and verify absence. Require cleanup to restore every captured setting, remove only the workshop classifier/group/pool when marker ownership matches, preserve AdventureWorks by default, and require an explicit variable to drop synthetic lab data.

- [ ] **Step 2: Run tests and confirm missing cleanup behavior**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql/test_sql_contract.py -q
```

Expected: failures for missing hint and cleanup scripts.

- [ ] **Step 3: Implement reversible hint and cleanup scripts**

The hint exercise applies `OPTION (MAX_GRANT_PERCENT = 10)` only to the discovered baseline query ID, records before/after statistics, displays failure details, and always clears the hint in a `TRY/CATCH` cleanup path. It explains that the hint is a temporary experiment and not the optimized procedure.

Cleanup refuses to run without marker ownership, terminates only doubly tagged sessions, clears workshop Query Store hints, restores memory-grant feedback and Query Store settings, restores prior Resource Governor classifier/state, removes workshop workload group and pool, restores max/min server memory, and optionally drops `lab` objects only when `DropLabData = 1`.

- [ ] **Step 4: Run all SQL contract tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/sql -q
```

Expected: all SQL tests pass.

- [ ] **Step 5: Commit hint and cleanup**

```powershell
git add sql/08-OptionalQueryStoreHint.sql sql/09-Cleanup.sql tests/sql
git commit -m "feat: add reversible query hint and lab cleanup"
```

## Task 14: Configure read-only SQL MCP and VS Code integration

**Files:**
- Create: `mcp/dab-config.json`
- Create: `mcp/.env.example`
- Create: `mcp/README.md`
- Create: `.vscode/mcp.json`
- Create: `.vscode/extensions.json`
- Create: `.github/copilot-instructions.md`
- Create: `tests/mcp/test_mcp_config.py`

- [ ] **Step 1: Write failing MCP security tests**

Create tests that parse both JSON files and assert:

- no literal password or real connection string;
- DAB uses `@env('MSSQL_CONNECTION_STRING')`;
- create, update, and delete DML tools are disabled;
- every entity has a description and field metadata;
- only the six diagnostic procedures plus summary views are exposed;
- custom tools point only to stored procedures;
- VS Code launches local `dab start --mcp-stdio role:workshop-reader`;
- no HTTP listener or public URL exists.

- [ ] **Step 2: Run tests and confirm missing-config failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/mcp -q
```

Expected: failures because MCP files are absent.

- [ ] **Step 3: Implement the DAB and VS Code configuration**

Initialize the DAB JSON using the documented 2.x schema. Configure the MSSQL connection through the environment expression. Disable REST and GraphQL for this workshop. Enable MCP with a server description and these global tools only: `describe-entities`, `read-records`, `aggregate-records`, and `execute-entity`; explicitly disable create, update, and delete.

Expose bounded run-summary views as read-only entities and each diagnostic procedure as a stored-procedure entity with `custom-tool: true`. Every object and field gets an operational description. The anonymous role is not used; use `workshop-reader`.

Create `.vscode/mcp.json`:

```json
{
  "servers": {
    "mcp-sql-query-store-workshop": {
      "type": "stdio",
      "command": "dab",
      "args": [
        "start",
        "--mcp-stdio",
        "role:workshop-reader",
        "--loglevel",
        "error",
        "--config",
        "${workspaceFolder}/mcp/dab-config.json"
      ]
    }
  }
}
```

Create `.env.example` with a private DNS server name and markers instead of values:

```text
MSSQL_CONNECTION_STRING=Server=sql01.mcpworkshop.internal,1433;Database=AdventureWorks2022;User ID=mcp_workshop_reader;Password=SET_LOCALLY_ON_ADMIN_VM;Encrypt=True;TrustServerCertificate=False;HostNameInCertificate=sql01.mcpworkshop.internal;Application Name=MCP-SQL-Workshop-MCP
```

Document that the line must be copied to ignored `.env` and the marker replaced interactively. Add GitHub Copilot instructions requiring observation, missing evidence, hypothesis, experiment, candidate change, risk, and validation sections; prohibit claiming target values as measurements.

- [ ] **Step 4: Run MCP tests and JSON parsing**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/mcp -q
Get-ChildItem mcp,.vscode -Filter *.json -Recurse | ForEach-Object { Get-Content -Raw $_ | ConvertFrom-Json | Out-Null }
```

Expected: all MCP tests pass and JSON parses.

- [ ] **Step 5: Commit SQL MCP integration**

```powershell
git add mcp .vscode .github/copilot-instructions.md tests/mcp
git commit -m "feat: add read-only SQL MCP diagnostic surface"
```

## Task 15: Implement SQL and administration VM bootstrap payloads

**Files:**
- Create: `deploy/Initialize-SqlVm.ps1`
- Create: `deploy/Initialize-AdminVm.ps1`
- Modify: `deploy/Workshop.Azure.psm1`
- Modify: `tests/powershell/EntryScripts.Tests.ps1`

- [ ] **Step 1: Add failing bootstrap tests**

Static and mocked tests require:

- SQL bootstrap verifies Enterprise 2022 and no public IP before database changes;
- disks are initialized with 64-KiB allocation units and explicit drive labels;
- AdventureWorks URL is the official release asset and `RESTORE VERIFYONLY` runs first;
- SQL TLS certificate is created for private DNS, private key is non-exportable, and only the public certificate moves to admin VM;
- admin bootstrap installs official VS Code, MSSQL, GitHub Copilot, SSMS, .NET, DAB, Git, and GitHub CLI packages;
- package versions are read back;
- `.env` ACL is restricted;
- readiness checks verify private DNS, TCP 1433, certificate validation, encrypted TDS, and expected MCP tools;
- no script logs secrets or protected settings.

- [ ] **Step 2: Run Pester and confirm missing bootstrap behavior**

```powershell
Invoke-Pester tests/powershell/EntryScripts.Tests.ps1 -Output Detailed
```

Expected: failures for missing bootstrap scripts.

- [ ] **Step 3: Implement SQL VM bootstrap**

Use strict mode and transcript redaction. Initialize attached disks by LUN, format NTFS with 64-KiB allocation units, and verify labels. Confirm Azure Instance Metadata reports no public IP. Configure SQL static private connectivity and Windows Firewall rules from `10.20.1.0/24` only.

Create a self-signed lab certificate with DNS SAN `sql01.mcpworkshop.internal`, server-auth EKU, non-exportable private key, and machine-key ACL for the SQL service account. Configure SQL Server's certificate thumbprint and force encryption, restart at one explicit checkpoint, then verify from SQL DMVs.

Download `AdventureWorks2022.bak` from the official Microsoft GitHub release URL, verify SHA-256 is recorded in readiness evidence, invoke the ordered SQL scripts with SQLCMD variables, and stop on the first failed read-back.

- [ ] **Step 4: Implement administration VM bootstrap and remote readiness**

Install packages through `winget` with exact package IDs where available and official fallbacks documented in code. Install DAB as a local .NET tool in the cloned repository. Copy only the SQL public certificate to the trusted root store. Create the ignored `.env` interactively from a secure string without printing it.

Verify:

```powershell
Resolve-DnsName sql01.mcpworkshop.internal
Test-NetConnection sql01.mcpworkshop.internal -Port 1433
code --version
dotnet --version
dotnet tool run dab --version
```

Open a validated encrypted SQL connection and query `sys.dm_exec_connections.encrypt_option`; require `TRUE`. Start the MCP server in a bounded verification process and require the expected tool list before marking readiness complete.

Use Azure VM Run Command or Custom Script Extension with protected settings for orchestration. No secret may appear in public settings, command arguments, deployment logs, or Git history.

- [ ] **Step 5: Run all PowerShell tests and analyzer**

```powershell
Invoke-Pester tests/powershell -Output Detailed
Invoke-ScriptAnalyzer deploy,workload -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse
```

Expected: tests pass and analyzer reports no errors.

- [ ] **Step 6: Commit bootstrap automation**

```powershell
git add deploy tests/powershell
git commit -m "feat: bootstrap private SQL and Windows admin VMs"
```

## Task 16: Write the complete six-hour L400 workshop and prompt book

**Files:**
- Create: `README.md`
- Create: `docs/attendee-guide.md`
- Create: `docs/troubleshooting.md`
- Create: `docs/evidence-and-sources.md`
- Modify: `docs/facilitator-guide.md`
- Modify: `workshop/00-orientation.md`
- Create: `workshop/01-mcp-and-copilot.md`
- Create: `workshop/02-scenario-and-architecture.md`
- Create: `workshop/03-deploy-with-powershell.md`
- Create: `workshop/04-create-memory-pressure.md`
- Create: `workshop/05-investigate-with-vscode.md`
- Create: `workshop/06-optimize-and-prove.md`
- Create: `workshop/07-teardown.md`
- Create: `prompts/investigation-prompts.md`
- Create: `prompts/prompt-evaluation-rubric.md`
- Modify: `web/site-manifest.json`
- Create: `tests/content/test_content_contract.py`

- [ ] **Step 1: Write failing content-contract tests**

Tests require all eight modules, exact total duration 360, at least two Mermaid diagrams, official source links, public-SQL prohibition, 80/40 target labels, a production warning, facilitator checkpoints, teardown proof, and at least twelve structured prompts. Tests reject unsupported phrases such as `guaranteed 40%`, `Copilot fixed`, or `SQL MCP can run any query`.

- [ ] **Step 2: Run tests and confirm missing-content failures**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/content -q
```

Expected: failures listing the missing modules and contracts.

- [ ] **Step 3: Write modules 00–03**

Module 00 covers learning objectives, target-versus-measured labels, production prohibition, licensing, cost, and safety contract.

Module 01 provides L400 MCP internals: JSON-RPC lifecycle, initialization, transport, tool discovery, tool invocation, role enforcement, human approvals, prompt injection and tool-output trust boundaries, SQL MCP DML scope, field metadata, and how SSMS Agent mode differs from VS Code SQL MCP.

Module 02 presents the two-VM Mermaid architecture and end-to-end sequence, traces every trust boundary, and includes a student exercise proving the SQL VM has no public IP.

Module 03 walks through Az module setup, context selection, read-only preflight, plan-card review, Windows license attestation, billable deployment confirmation, positive read-backs, RDP, and private SQL connectivity. It does not instruct readers to bypass the approval switch.

- [ ] **Step 4: Write modules 04–07**

Module 04 defines query workspace memory, Resource Governor, memory grants, RESOURCE_SEMAPHORE, spills, Query Store, target bands, calibration, safety states, and exact start/stop commands.

Module 05 guides VS Code connection, `@mssql` schema exploration, actual-plan capture, SQL MCP server start, `describe_entities`, each diagnostic custom tool, and prompts that separate observations from hypotheses.

Module 06 guides candidate generation with GitHub Copilot, human review, side-by-side procedure creation, correctness matrix, frozen-condition optimized run, interleaved A/B test, outcome classification, and optional Query Store hint lifecycle.

Module 07 covers stopping/deallocating versus deleting, typed teardown confirmation, Azure absence verification, local secret removal, GitHub evidence review, and production adoption considerations.

- [ ] **Step 5: Write facilitator, attendee, troubleshooting, sources, and prompt material**

The facilitator guide contains minute-by-minute checkpoints, expected target states, recovery branches, and explicit instructions for a truthful `BaselineTargetNotReached` or `ImprovedOutsideTarget` result. The attendee guide contains an evidence worksheet.

The prompt book includes at least twelve prompts. Each prompt requires these headings:

```text
Observations
Missing evidence
Hypotheses ranked by confidence
Proposed experiments
Candidate changes
Risks and rollback
Validation criteria
```

The rubric scores evidence attribution, contract preservation, security, reversibility, measurement quality, and unsupported certainty. The source guide maps every `DOC-VERIFIED` claim to an official URL and records the verification date.

- [ ] **Step 6: Run content and site tests**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/content tests/web -q
.\.venv\Scripts\python.exe web/build_site.py --root . --output site
```

Expected: all tests pass and every manifest route is generated.

- [ ] **Step 7: Commit workshop content**

```powershell
git add README.md docs workshop prompts web/site-manifest.json tests/content
git commit -m "docs: add complete L400 MCP SQL workshop"
```

## Task 17: Add CI validation and GitHub Pages deployment

**Files:**
- Create: `.github/workflows/validate.yml`
- Create: `.github/workflows/pages.yml`
- Modify: `build/Test-Repository.ps1`
- Create: `tests/repository/test_workflows.py`

- [ ] **Step 1: Write failing workflow-policy tests**

Require least-privilege workflow permissions, pinned major action versions, validation before deployment, Pages environment protection, Python and PowerShell tests, site artifact upload, and no Azure credential requirement.

- [ ] **Step 2: Run tests and confirm missing workflows**

```powershell
.\.venv\Scripts\python.exe -m pytest tests/repository/test_workflows.py -q
```

Expected: failures because workflow files are absent.

- [ ] **Step 3: Implement validation workflow**

`validate.yml` runs on pull requests and pushes to `main`, checks out source, configures Python, installs requirements, installs Pester/PSScriptAnalyzer, executes `build/Test-Repository.ps1`, builds `site/`, and uploads the generated site as a diagnostic artifact. Default permissions are `contents: read`.

- [ ] **Step 4: Implement Pages workflow**

`pages.yml` runs on pushes to `main` and manual dispatch. It repeats the validation gate, builds the site, uploads the Pages artifact, and deploys only after validation. Use permissions:

```yaml
permissions:
  contents: read
  pages: write
  id-token: write
```

Use concurrency group `pages` with `cancel-in-progress: false` and environment `github-pages` with the deployment URL from the action output.

- [ ] **Step 5: Run repository validation locally**

```powershell
.\build\Test-Repository.ps1
```

Expected: every named gate passes and the site builds.

- [ ] **Step 6: Commit CI and Pages workflows**

```powershell
git add .github/workflows build/Test-Repository.ps1 tests/repository/test_workflows.py
git commit -m "ci: validate and publish workshop pages"
```

## Task 18: Perform final local and browser verification

**Files:**
- Regenerate: `index.html`
- Regenerate: `assets/`
- Modify only if tests find defects: relevant source files

- [ ] **Step 1: Run the complete test suite from a clean generated state**

```powershell
if (Test-Path site) { Remove-Item site -Recurse -Force }
.\build\Test-Repository.ps1
```

Expected: all Python, Pester, PSScriptAnalyzer, JSON, secret, SQL-safety, content, link, and site gates pass.

- [ ] **Step 2: Generate the committed Pages entry point**

```powershell
.\.venv\Scripts\python.exe web/build_site.py --root . --output site
Copy-Item site\index.html .\index.html -Force
if (Test-Path assets) { Remove-Item assets -Recurse -Force }
Copy-Item site\assets .\assets -Recurse
```

Expected: root `index.html` and `assets/` exactly match the current source build.

- [ ] **Step 3: Serve and inspect the site in a browser**

Run a local HTTP server from the repository root, then verify desktop, tablet, and mobile layouts; keyboard focus; skip link; module navigation; copy controls; Mermaid rendering; target labels; and the 80% → 40% calculator. Stop the server after validation.

- [ ] **Step 4: Verify no billable resources were created**

Run a read-only check for resources tagged `workload=mcp-sql` in the selected subscription. Expected: no new workshop resources from repository implementation. If pre-existing matching resources exist, report them without deleting them.

- [ ] **Step 5: Commit generated site and final fixes**

```powershell
git add index.html assets
git commit -m "build: generate validated workshop site"
```

Expected: commit succeeds or Git reports no changes because output is already current.

## Task 19: Review implementation against the approved specification

**Files:**
- Review: all tracked files
- Modify: only files needed to close verified findings

- [ ] **Step 1: Run a requirements traceability review**

Map every section of the approved design to a file and test. Pay particular attention to:

- primary goal: GitHub Copilot assisted by SQL MCP optimizes a stored procedure;
- only Windows 11 VM has public ingress;
- SQL VM has no public IP;
- 80% → 40% is query-workspace grant utilization, not Task Manager memory;
- A/B settings remain frozen;
- target misses are reported truthfully;
- SQL MCP is read-only and allowlisted;
- workload is bounded and non-production;
- publication includes full source and live Pages.

- [ ] **Step 2: Run a security-focused review**

Check credential handling, protected settings, TDS validation, NSG priorities, public-IP associations, SQL permissions, MCP tool exposure, shell/SQL injection, evidence redaction, and teardown behavior. Fix every high- or medium-severity finding and add a regression test before implementation changes.

- [ ] **Step 3: Run final verification after review fixes**

```powershell
.\build\Test-Repository.ps1
git diff --check
git status --short
```

Expected: all gates pass, no whitespace errors, and only intended review changes remain.

- [ ] **Step 4: Commit review fixes**

```powershell
git add -A
git commit -m "fix: address final workshop review findings"
```

If there are no findings, do not create an empty commit; record the clean review in the publication notes.

## Task 20: Create the public GitHub repository and publish Pages

**Files:**
- No source changes unless publication validation exposes a defect

- [ ] **Step 1: Verify publishing prerequisites and identity**

```powershell
gh auth status
gh api user --jq .login
git status --short --branch
```

Expected: active login is `ibranibeny`, working tree is clean, and branch is `main`.

- [ ] **Step 2: Verify repository name is available**

```powershell
$repo = 'ibranibeny/mcp-sql-query-store-workshop'
$exists = gh repo view $repo --json name 2>$null
if ($LASTEXITCODE -eq 0) { throw "Repository already exists: $repo" }
```

Expected: repository does not exist. If it exists, stop and request explicit authorization to reuse it; do not overwrite it.

- [ ] **Step 3: Create and push the full public repository**

```powershell
gh repo create ibranibeny/mcp-sql-query-store-workshop --public --source . --remote origin --description "L400 workshop: optimize SQL Server stored procedures with GitHub Copilot and Microsoft SQL MCP Server"
$env:GIT_TERMINAL_PROMPT = '0'
git push -u origin main
```

Expected: source repository is available at `https://github.com/ibranibeny/mcp-sql-query-store-workshop`.

- [ ] **Step 4: Enable GitHub Pages through Actions and verify configuration**

```powershell
gh api repos/ibranibeny/mcp-sql-query-store-workshop/pages -X POST -f build_type=workflow 2>$null
if ($LASTEXITCODE -ne 0) {
    gh api repos/ibranibeny/mcp-sql-query-store-workshop/pages -X PUT -f build_type=workflow
}
gh workflow run pages.yml --repo ibranibeny/mcp-sql-query-store-workshop
```

Use the GitHub Actions run status rather than assuming success. Wait for the workflow through `gh run watch` and inspect the final conclusion.

- [ ] **Step 5: Verify repository and live Pages endpoint**

```powershell
gh repo view ibranibeny/mcp-sql-query-store-workshop --json url,visibility,defaultBranchRef
gh api repos/ibranibeny/mcp-sql-query-store-workshop/pages
Invoke-WebRequest -Uri 'https://ibranibeny.github.io/mcp-sql-query-store-workshop/' -UseBasicParsing
```

Expected: repository visibility is `PUBLIC`, default branch is `main`, Pages reports the expected URL, and HTTP response is successful with the workshop title in the body.

- [ ] **Step 6: Report truthful completion state**

Report:

- repository URL;
- live Pages URL;
- final workflow conclusion;
- local validation summary;
- explicit statement that Azure resources were not deployed;
- the command that starts non-destructive preflight;
- requirement for separate approval before billable deployment.

Do not report the 80% → 40% result as achieved until a real `LAB-MEASURED` evidence bundle passes schema validation.

---

## Plan self-review

### Specification coverage

- Primary GitHub Copilot plus SQL MCP optimization goal: Tasks 10, 14, and 16.
- Two-VM private SQL topology: Tasks 4–6 and 15.
- Only Windows 11 VM published for RDP: Tasks 4–6, 15, and 19.
- SQL Server 2022 Enterprise with 64 GiB: Tasks 4, 6, 7, and 15.
- AdventureWorks and complex procedure: Tasks 8–10.
- 80% → 40% measured query-grant experiment: Tasks 7 and 11–13.
- Query Store evidence and optional hint: Tasks 7, 10, and 13.
- Read-only SQL MCP: Task 14.
- Six-hour L400 guidance: Task 16.
- Mermaid architecture and flow: Tasks 2, 3, and 16.
- Native Az PowerShell deployment: Tasks 4–6 and 15.
- Security, licensing, cost controls, and teardown: Tasks 4–6, 15, 16, and 19.
- Public GitHub repository and Pages: Tasks 17, 18, and 20.

### Invariants for every implementation task

1. A target value is never serialized as a measured value.
2. The SQL VM never receives a public IP.
3. No rule permits public SQL traffic.
4. No unbounded workload or global cache flush is introduced.
5. Secrets enter only interactive secure inputs or protected runtime settings.
6. Every state-changing operation has a positive read-back.
7. Azure creation remains separately approval-gated.
