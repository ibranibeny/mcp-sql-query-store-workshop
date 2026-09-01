from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
VALIDATE = WORKFLOWS / "validate.yml"
PAGES = WORKFLOWS / "pages.yml"
REPOSITORY_VALIDATION = ROOT / "build" / "Test-Repository.ps1"

ACTION_RELEASES = {
    "actions/checkout": ("v7.0.1", "3d3c42e5aac5ba805825da76410c181273ba90b1"),
    "actions/setup-python": ("v7.0.0", "5fda3b95a4ea91299a34e894583c3862153e4b97"),
    "actions/upload-artifact": ("v7.0.1", "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"),
    "actions/configure-pages": ("v6.0.0", "45bfe0192ca1faeb007ade9deae92b16b8254a0d"),
    "actions/upload-pages-artifact": ("v5.0.0", "fc324d3547104276b827a68afc52ff2a11cc49c9"),
    "actions/deploy-pages": ("v5.0.0", "cd2ce8fcbc39b97be8ca5fce6e763baed58fa128"),
}


def workflow(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def yaml_block(text: str, key: str, indent: int = 0) -> str:
    lines = text.splitlines()
    header = f"{' ' * indent}{key}:"
    try:
        start = next(index for index, line in enumerate(lines) if line == header)
    except StopIteration as error:
        raise AssertionError(f"Missing YAML block {key!r} at indentation {indent}") from error

    end = len(lines)
    for index in range(start + 1, len(lines)):
        line = lines[index]
        if line.strip() and len(line) - len(line.lstrip(" ")) <= indent:
            end = index
            break
    return "\n".join(lines[start:end])


def child_keys(block: str, indent: int) -> set[str]:
    keys: set[str] = set()
    pattern = re.compile(rf"^{' ' * indent}([A-Za-z0-9_-]+):(?:\s.*)?$")
    for line in block.splitlines()[1:]:
        match = pattern.match(line)
        if match:
            keys.add(match.group(1))
    return keys


def action_uses(text: str) -> list[tuple[str, str, str]]:
    pattern = re.compile(
        r"(?m)^\s*-?\s*uses:\s*(actions/[A-Za-z0-9_-]+)@([0-9a-f]{40})\s+#\s+(v\d+(?:\.\d+){1,2})\s*$"
    )
    return pattern.findall(text)


def run_block_containing(text: str, required_text: str) -> str:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if line != "        run: |":
            continue
        end = index + 1
        while end < len(lines):
            candidate = lines[end]
            if candidate.strip() and len(candidate) - len(candidate.lstrip(" ")) <= 8:
                break
            end += 1
        block = "\n".join(lines[index:end])
        if required_text in block:
            return block
    raise AssertionError(f"Missing run block containing {required_text!r}")


def assert_common_validation_contract(text: str) -> None:
    assert "runs-on: windows-latest" in text
    assert "uses: actions/setup-python@" in text
    assert re.search(r"(?m)^\s+python-version:\s*['\"]?3\.12['\"]?\s*$", text)
    assert "python -m venv .venv" in text
    assert (
        "./build/Install-DevDependencies.ps1 "
        "-AllowPublicPackageIndex -AllowPowerShellGallery"
    ) in text

    validation = run_block_containing(text, "./build/Test-Repository.ps1")
    assert "./build/Test-Repository.ps1" in validation
    assert "-RequirePSScriptAnalyzer" in validation
    assert "-BaseRef $env:VALIDATION_BASE_REF" in validation
    assert "${{" not in validation
    assert "VALIDATION_BASE_REF:" in text
    assert "github.event.pull_request.base.sha" in text
    assert "github.event.before" in text

    build_index = text.index("web/build_site.py --root . --output site")
    assert build_index > text.index("./build/Test-Repository.ps1")


def test_validation_workflow_has_exact_triggers_and_least_privilege() -> None:
    text = workflow(VALIDATE)
    triggers = yaml_block(text, "on")
    assert child_keys(triggers, 2) == {"pull_request", "push", "workflow_dispatch"}
    assert re.search(r"(?m)^  push:\s*$\n^    branches: \[main\]\s*$", triggers)

    permissions = yaml_block(text, "permissions")
    assert child_keys(permissions, 2) == {"contents"}
    assert re.search(r"(?m)^  contents: read\s*$", permissions)


def test_validation_workflow_runs_strict_validation_and_uploads_diagnostic_site() -> None:
    text = workflow(VALIDATE)
    assert_common_validation_contract(text)
    assert "uses: actions/upload-artifact@" in text
    assert "name: workshop-site-validation" in text
    assert re.search(r"(?m)^\s+path: site\s*$", text)
    assert re.search(r"(?m)^\s+retention-days: 7\s*$", text)
    assert text.index("web/build_site.py --root . --output site") < text.index(
        "uses: actions/upload-artifact@"
    )


def test_pages_workflow_has_exact_triggers_permissions_and_concurrency() -> None:
    text = workflow(PAGES)
    triggers = yaml_block(text, "on")
    assert child_keys(triggers, 2) == {"push", "workflow_dispatch"}
    assert re.search(r"(?m)^  push:\s*$\n^    branches: \[main\]\s*$", triggers)

    permissions = yaml_block(text, "permissions")
    assert child_keys(permissions, 2) == {"contents", "pages", "id-token"}
    assert re.search(r"(?m)^  contents: read\s*$", permissions)
    assert re.search(r"(?m)^  pages: write\s*$", permissions)
    assert re.search(r"(?m)^  id-token: write\s*$", permissions)

    concurrency = yaml_block(text, "concurrency")
    assert re.search(r"(?m)^  group: pages\s*$", concurrency)
    assert re.search(r"(?m)^  cancel-in-progress: false\s*$", concurrency)


def test_pages_build_repeats_validation_and_publishes_generated_site() -> None:
    text = workflow(PAGES)
    assert_common_validation_contract(text)
    assert "uses: actions/configure-pages@" in text
    assert "uses: actions/upload-pages-artifact@" in text
    assert re.search(r"(?m)^\s+path: site\s*$", text)

    validation_index = text.index("./build/Test-Repository.ps1")
    configure_index = text.index("uses: actions/configure-pages@")
    build_index = text.index("web/build_site.py --root . --output site")
    upload_index = text.index("uses: actions/upload-pages-artifact@")
    assert validation_index < configure_index < build_index < upload_index


def test_pages_deploy_requires_validated_build_and_uses_pages_environment() -> None:
    text = workflow(PAGES)
    deploy = yaml_block(text, "deploy", 2)
    assert re.search(r"(?m)^    needs: build\s*$", deploy)
    assert re.search(r"(?m)^      name: github-pages\s*$", deploy)
    assert "url: ${{ steps.deployment.outputs.page_url }}" in deploy
    assert "id: deployment" in deploy
    assert "uses: actions/deploy-pages@" in deploy


def test_all_actions_are_official_and_pinned_to_verified_release_commits() -> None:
    combined = workflow(VALIDATE) + "\n" + workflow(PAGES)
    uses_lines = [line for line in combined.splitlines() if "uses:" in line]
    pins = action_uses(combined)
    assert len(pins) == len(uses_lines), "Every action must use a 40-hex SHA and version comment"

    for repository, commit, version in pins:
        assert repository in ACTION_RELEASES
        assert (version, commit) == ACTION_RELEASES[repository]


def test_workflows_do_not_require_cloud_credentials_or_third_party_actions() -> None:
    combined = (workflow(VALIDATE) + "\n" + workflow(PAGES)).lower()
    assert "azure" not in combined
    assert "secrets." not in combined
    assert "client-id" not in combined
    assert "tenant-id" not in combined
    assert "subscription-id" not in combined


def test_repository_validation_treats_all_zero_ci_base_as_fallback() -> None:
    script = REPOSITORY_VALIDATION.read_text(encoding="utf-8")
    assert re.search(r"\$BaseRef\s+-match\s+'\^0\{40\}\$'", script)
    assert "$script:RequestedBaseRef = $null" in script
