import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
VALIDATION_MODULE = ROOT / "build" / "RepositoryValidation.psm1"
REPOSITORY_TEST_SCRIPT = ROOT / "build" / "Test-Repository.ps1"


def run_powershell(command: str, *, environment: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["pwsh", "-NoProfile", "-NonInteractive", "-Command", command],
        check=False,
        capture_output=True,
        text=True,
        env={**os.environ, **environment},
    )


def validation_module_import() -> str:
    return """
Import-Module $env:REPOSITORY_VALIDATION_MODULE -Force
"""


def initialize_git_repository(path: Path) -> None:
    subprocess.run(["git", "-C", str(path), "init", "--quiet"], check=True)


def test_sensitive_and_generated_files_are_ignored() -> None:
    rules = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    required = {
        ".worktrees/",
        ".env",
        "*.pfx",
        "*.pfx.password",
        "*.cer.private",
        "*.key",
        "*.bak",
        "*.trc",
        "*.xel",
        "*.blg",
        "*.sqlplan",
        "evidence/runs/",
        "site/",
        ".venv/",
        "__pycache__/",
        ".pytest_cache/",
        ".coverage",
        "htmlcov/",
        "TestResults/",
        ".vscode/settings.json",
        "*.user",
        ".DS_Store",
        "Thumbs.db",
    }
    assert required.issubset(set(rules))


def test_missing_psscriptanalyzer_skips_the_optional_gate() -> None:
    command = validation_module_import() + """
$result = Get-PSScriptAnalyzerGateResult -AnalyzerAvailable:$false
if ($result.Failed -or -not $result.Skipped) { throw 'Expected a non-failing skip.' }
if ($result.Message -ne 'SKIP: PSScriptAnalyzer (not installed; run build/Install-DevDependencies.ps1)') {
    throw "Unexpected skip message: $($result.Message)"
}
"""
    result = run_powershell(
        command,
        environment={"REPOSITORY_VALIDATION_MODULE": str(VALIDATION_MODULE)},
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_repository_validation_has_named_recursive_pester_gate() -> None:
    script = REPOSITORY_TEST_SCRIPT.read_text(encoding="utf-8")

    assert "function Test-Pester" in script
    assert "Invoke-Pester" in script
    assert "-PassThru" in script
    assert "Invoke-ValidationGate -Name 'Pester tests' -Validation { Test-Pester }" in script


def test_repository_validation_has_canonical_evidence_gate() -> None:
    script = REPOSITORY_TEST_SCRIPT.read_text(encoding="utf-8")

    assert "function Test-Evidence" in script
    assert "evidence/validate_evidence.py" in script
    assert "Get-RepositoryEvidenceJsonFile" in script
    assert "Invoke-ValidationGate -Name 'Evidence semantics'" in script


def test_repository_validation_verifies_current_venv_without_installing() -> None:
    script = REPOSITORY_TEST_SCRIPT.read_text(encoding="utf-8")

    assert "function Test-PythonDependency" in script
    assert "Test-PythonDependencies.py" in script
    assert "Invoke-ValidationGate -Name 'Python dependency bounds'" in script
    assert "pip install" not in script.lower()


def test_json_validation_skips_node_modules(tmp_path: Path) -> None:
    initialize_git_repository(tmp_path)
    (tmp_path / ".gitignore").write_text("node_modules/\n", encoding="utf-8")
    vendor_directory = tmp_path / "node_modules" / "dependency"
    vendor_directory.mkdir(parents=True)
    (vendor_directory / "generated.json").write_text("not json", encoding="utf-8")
    (tmp_path / "project.json").write_text('{"tracked": true}', encoding="utf-8")
    command = validation_module_import() + """
$files = @(Get-RepositoryJsonFile -RepositoryRoot $env:JSON_TEST_ROOT)
if ($files -contains 'node_modules/dependency/generated.json') { throw 'Ignored JSON was enumerated.' }
if ($files -notcontains 'project.json') { throw 'Project JSON was not enumerated.' }
"""
    result = run_powershell(
        command,
        environment={
            "REPOSITORY_VALIDATION_MODULE": str(VALIDATION_MODULE),
            "JSON_TEST_ROOT": str(tmp_path),
        },
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_json_validation_checks_project_json(tmp_path: Path) -> None:
    initialize_git_repository(tmp_path)
    (tmp_path / "project.json").write_text("not json", encoding="utf-8")
    command = validation_module_import() + """
foreach ($relativePath in Get-RepositoryJsonFile -RepositoryRoot $env:JSON_TEST_ROOT) {
    Get-Content -LiteralPath (Join-Path $env:JSON_TEST_ROOT $relativePath) -Raw |
        ConvertFrom-Json -ErrorAction Stop | Out-Null
}
"""
    result = run_powershell(
        command,
        environment={
            "REPOSITORY_VALIDATION_MODULE": str(VALIDATION_MODULE),
            "JSON_TEST_ROOT": str(tmp_path),
        },
    )

    assert result.returncode != 0


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
