from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_sensitive_and_generated_files_are_ignored() -> None:
    rules = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    required = {
        ".worktrees/",
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
