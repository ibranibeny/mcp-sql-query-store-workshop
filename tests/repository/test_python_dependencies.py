from __future__ import annotations

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "build" / "Test-PythonDependencies.py"


def write_distribution(site_packages: Path, name: str, version: str) -> None:
    dist_info = site_packages / f"{name}-{version}.dist-info"
    dist_info.mkdir()
    (dist_info / "METADATA").write_text(
        f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
        encoding="utf-8",
    )


def run_verifier(requirements: Path, site_packages: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(VERIFIER),
            "--requirements",
            str(requirements),
            "--site-packages",
            str(site_packages),
        ],
        check=False,
        capture_output=True,
        text=True,
    )


def test_verifier_accepts_bounded_installed_distributions_and_canonicalizes_names(
    tmp_path: Path,
) -> None:
    requirements = tmp_path / "requirements-dev.txt"
    requirements.write_text("Demo_Package>=1.2,<2\n", encoding="utf-8")
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()
    write_distribution(site_packages, "demo.package", "1.5.0")

    result = run_verifier(requirements, site_packages)

    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.strip() == (
        "Demo_Package | required: >=1.2,<2 | detected: 1.5.0 | status: satisfied"
    )
    assert str(tmp_path) not in result.stdout


def test_verifier_reports_missing_and_out_of_bounds_without_environment_details(
    tmp_path: Path,
) -> None:
    requirements = tmp_path / "requirements-dev.txt"
    requirements.write_text("OldThing>=2,<3\nMissingThing>=1,<2\n", encoding="utf-8")
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()
    write_distribution(site_packages, "oldthing", "1.9")

    result = run_verifier(requirements, site_packages)

    assert result.returncode == 1
    assert "OldThing | required: >=2,<3 | detected: 1.9 | status: out-of-bounds" in result.stdout
    assert "MissingThing | required: >=1,<2 | detected: not-installed | status: missing" in result.stdout
    assert str(tmp_path) not in result.stdout
    assert result.stderr == ""


def test_verifier_rejects_unbounded_or_unsupported_requirement_syntax(tmp_path: Path) -> None:
    requirements = tmp_path / "requirements-dev.txt"
    requirements.write_text("anything>=1\n", encoding="utf-8")
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()

    result = run_verifier(requirements, site_packages)

    assert result.returncode == 2
    assert result.stdout.strip() == (
        "anything | required: unsupported | detected: not-checked | status: invalid-requirement"
    )
    assert result.stderr == ""


def test_verifier_orders_post_release_development_versions_after_the_base_release(
    tmp_path: Path,
) -> None:
    requirements = tmp_path / "requirements-dev.txt"
    requirements.write_text("Demo>=3.7,<4\n", encoding="utf-8")
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()
    write_distribution(site_packages, "Demo", "3.7.post1.dev1")

    result = run_verifier(requirements, site_packages)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "status: satisfied" in result.stdout


def test_verifier_excludes_prerelease_of_the_exclusive_upper_bound(tmp_path: Path) -> None:
    requirements = tmp_path / "requirements-dev.txt"
    requirements.write_text("Demo>=8,<10\n", encoding="utf-8")
    site_packages = tmp_path / "site-packages"
    site_packages.mkdir()
    write_distribution(site_packages, "Demo", "10.0rc1")

    result = run_verifier(requirements, site_packages)

    assert result.returncode == 1
    assert "status: out-of-bounds" in result.stdout