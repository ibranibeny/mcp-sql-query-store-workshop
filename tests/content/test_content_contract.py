from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from bs4 import BeautifulSoup

from web.build_site import build_site, render_markdown

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "web" / "site-manifest.json"
SCREENSHOT_MANIFEST_PATH = ROOT / "docs" / "images" / "screenshot-manifest.json"
SCENARIO = "workshop/scenario-a-vscode-scenario-b-ssms.md"
SCENARIO_ROUTE = "scenario-a-vscode-scenario-b-ssms.html"
SCENARIO_ARTIFACT_REVISION = "1aebe319edd7760a6f37fa21149c0474df23b284"
DAB_AUTHORIZATION_URL = (
    "https://learn.microsoft.com/en-us/azure/data-api-builder/"
    "concept/security/authorization-overview"
)
OFFICIAL_EXTERNAL_LINK_ALLOWLIST = {
    DAB_AUTHORIZATION_URL,
}

MODULES = [
    "workshop/00-orientation.md",
    "workshop/01-mcp-and-copilot.md",
    "workshop/02-scenario-and-architecture.md",
    "workshop/03-deploy-with-powershell.md",
    "workshop/04-create-memory-pressure.md",
    "workshop/05-investigate-with-vscode.md",
    "workshop/06-optimize-and-prove.md",
    "workshop/07-teardown.md",
]
SUPPORTING_PAGES = [
    "docs/facilitator-guide.md",
    "docs/attendee-guide.md",
    "docs/troubleshooting.md",
    "docs/evidence-and-sources.md",
    "docs/offline-dependencies.md",
    "prompts/investigation-prompts.md",
    "prompts/prompt-evaluation-rubric.md",
]
SCREENSHOTS = [
    "local-home.png",
    "local-architecture.png",
    "local-memory-target.png",
    "azure-01-preflight.png",
    "azure-02-network.png",
    "azure-03-vms.png",
    "azure-04-sql-readiness.png",
    "azure-05-admin-readiness.png",
    "azure-06-workload.png",
    "azure-07-pages.png",
]
PROMPT_HEADINGS = [
    "Observations",
    "Missing evidence",
    "Hypotheses ranked by confidence",
    "Proposed experiments",
    "Candidate changes",
    "Risks and rollback",
    "Validation criteria",
]
SCENARIO_HEADINGS = [
    ("##", "Outcome"),
    ("##", "Safety rules"),
    ("##", "Readiness gate"),
    ("##", "Shared nonoptimized workload"),
    ("###", "Business request"),
    ("###", "Representative nonoptimized query shape"),
    ("###", "Bounded diagnostic invocation"),
    ("##", "Scenario A — RDP, VS Code, MSSQL, GitHub Copilot, and SQL MCP"),
    ("###", "A1. Enter the administration VM"),
    ("###", "A2. Verify VS Code tooling"),
    ("###", "A3. Connect MSSQL to the private database"),
    ("###", "A4. Validate and start SQL MCP"),
    ("###", "A5. Inspect the baseline"),
    ("###", "A6. Ask GitHub Copilot to explain"),
    ("###", "A7. Ground the review with SQL MCP"),
    ("###", "A8. Ask GitHub Copilot to optimize"),
    ("##", "Scenario B — RDP, SSMS, and GitHub Copilot"),
    ("###", "B1. Open SSMS and connect"),
    ("###", "B2. Recreate the same review context"),
    ("###", "B3. Use `/explain`"),
    ("###", "B4. Use `/optimize`"),
    ("###", "B5. Optional Agent mode demonstration"),
    ("##", "Reconcile, approve, and prove"),
    ("###", "Compare Candidate A and Candidate B"),
    ("###", "Apply exactly one approved candidate"),
    ("###", "Correctness gate"),
    ("###", "Shared performance gate"),
    ("###", "Decision"),
    ("###", "Screenshot checklist"),
    ("##", "Official references"),
]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def all_content() -> str:
    paths = ["README.md", *MODULES, SCENARIO, *SUPPORTING_PAGES]
    return "\n".join(read(path) for path in paths)


def test_all_required_content_exists_and_manifest_routes_every_page() -> None:
    required = ["README.md", *MODULES, *SUPPORTING_PAGES, "docs/images/README.md"]
    assert all((ROOT / path).is_file() for path in required)

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    sources = [page["source"] for page in manifest["pages"]]
    routes = [page["route"] for page in manifest["pages"]]
    workshop_sources = [
        page["source"]
        for page in manifest["pages"]
        if re.fullmatch(r"Workshop \d{2}", page["phase"])
    ]
    assert workshop_sources == MODULES
    assert SCENARIO in sources
    assert set(SUPPORTING_PAGES).issubset(sources)
    assert routes[0] == "index.html"
    assert len(routes) == len(set(route.casefold() for route in routes))


def test_workshop_duration_is_exactly_360_with_two_breaks() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    workshop = [page for page in manifest["pages"] if re.fullmatch(r"Workshop \d{2}", page["phase"])]
    assert len(workshop) == 8
    assert sum(page["durationMinutes"] for page in workshop) == 360
    assert [page.get("breakAfterMinutes", 0) for page in workshop] == [0, 0, 0, 10, 0, 10, 0, 0]
    assert sum(page.get("instructionMinutes", page["durationMinutes"]) for page in workshop) == 340


def test_dual_copilot_scenario_is_routed_and_preserves_shared_evidence_contract() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    pages = manifest["pages"]
    scenario = next(page for page in pages if page["source"] == SCENARIO)

    assert scenario == {
        "source": SCENARIO,
        "route": SCENARIO_ROUTE,
        "title": "Scenario A: VS Code and Scenario B: SSMS",
        "phase": "Workshop resource",
        "durationMinutes": 0,
    }
    scenario_index = pages.index(scenario)
    assert pages[scenario_index - 1]["phase"] == "Workshop 06"
    assert pages[scenario_index + 1]["phase"] == "Workshop 07"

    content = read(SCENARIO)
    headings = re.findall(r"(?m)^(#{1,6})\s+(.+)$", content)
    assert headings == SCENARIO_HEADINGS
    for token in (
        "one baseline",
        "two independent Copilot reviews",
        "Candidate A",
        "Candidate B",
        "Approve-WorkshopCandidate.ps1",
        "ABBA BAAB ABBA",
    ):
        assert token in content


def test_dual_copilot_scenario_pins_executable_artifacts_to_immutable_revision() -> None:
    content = read(SCENARIO)
    repository = "https://github.com/ibranibeny/mcp-sql-query-store-workshop/blob"
    artifact_paths = (
        "sql/04-CreateBaselineProcedure.sql",
        "sql/06-CreateOptimizedProcedure.sql",
        "deploy/Approve-WorkshopCandidate.ps1",
        "sql/07-ValidateEquivalence.sql",
    )

    assert f"{repository}/main/" not in content
    for artifact_path in artifact_paths:
        assert f"{repository}/{SCENARIO_ARTIFACT_REVISION}/{artifact_path}" in content
    assert "[Workshop 04: Create bounded query-memory pressure](04-create-memory-pressure.html)" in content


def test_modules_cover_architecture_evidence_safety_and_teardown() -> None:
    content = all_content()
    assert content.count("```mermaid") >= 2
    assert "The SQL VM has no public IP" in content
    assert "Do not run the workshop workload scripts against production." in content
    assert "75–85%" in content and "35–45%" in content
    assert "[!TARGET]" in content
    assert "Task Manager" in content and "not" in content
    assert "DELETE rg-mcp-sql-workshop" in read("workshop/07-teardown.md")
    assert "resource group is absent" in read("workshop/07-teardown.md").lower()
    assert "BaselineTargetNotReached" in read("docs/facilitator-guide.md")
    assert "ImprovedOutsideTarget" in read("docs/facilitator-guide.md")


def test_mcp_module_is_l400_and_bounded() -> None:
    module = read("workshop/01-mcp-and-copilot.md")
    required = [
        "JSON-RPC",
        "initialize",
        "notifications/initialized",
        "tools/list",
        "tools/call",
        "stdio",
        "Data API Builder 2.0.9",
        "describe_entities",
        "read_records",
        "aggregate_records",
        "execute_entity",
        "ms-mssql.mssql",
        "@mssql",
        "SSMS 22.7",
        "Agent mode",
        "RBAC",
        "natural-language-to-SQL",
        "DDL",
    ]
    assert all(value in module for value in required)
    assert module.index("stdio") < module.index("JSON-RPC lifecycle")
    assert "https://learn.microsoft.com/" in module


def test_deployment_and_workload_modules_match_repository_entry_points() -> None:
    deployment = read("workshop/03-deploy-with-powershell.md")
    workload = read("workshop/04-create-memory-pressure.md")
    teardown = read("workshop/07-teardown.md")
    for token in (
        "-SubscriptionId",
        "-FacilitatorCidr",
        "-ExpiresOn",
        "-WindowsClientLicenseAttested",
        "-SqlEnterpriseCostAcknowledged",
        "-BillableResourcesAcknowledged",
        "Get-Credential",
        "-ApproveBillableDeployment",
        "DEPLOY rg-mcp-sql-workshop",
    ):
        assert token in deployment
    for token in (
        "Start-MemoryGrantLab.ps1",
        "Stop-MemoryGrantLab.ps1",
        "-RunId",
        "-Server",
        "-Credential",
        "MaximumDurationSeconds 600",
        "granted_memory_kb",
        "total_memory_kb",
    ):
        assert token in workload
    assert "Stop-WorkshopEnvironment.ps1" in teardown
    assert "Remove-WorkshopEnvironment.ps1" in teardown


def test_bootstrap_stops_before_candidate_and_module_six_owns_explicit_approval() -> None:
    setup = read("workshop/04-create-memory-pressure.md")
    proof = read("workshop/06-optimize-and-prove.md")
    facilitator = read("docs/facilitator-guide.md")
    assert "sql/00-Preflight.sql` through `sql/05-CreateDiagnostics.sql" in setup
    assert "through `sql/07-ValidateEquivalence.sql" not in setup
    assert "must not run `sql/06-CreateOptimizedProcedure.sql`" in setup
    for content in (proof, facilitator):
        assert "deploy/Approve-WorkshopCandidate.ps1" in content
        assert "APPROVE AdventureWorks2022 candidate" in content
        assert "after" in content.lower() and "investigation" in content.lower()
    assert proof.index("deploy/Approve-WorkshopCandidate.ps1") < proof.index("ABBA BAAB ABBA")


def test_investigation_and_proof_modules_name_real_surfaces() -> None:
    investigation = read("workshop/05-investigate-with-vscode.md")
    proof = read("workshop/06-optimize-and-prove.md")
    for extension_id in ("ms-mssql.mssql", "GitHub.copilot", "GitHub.copilot-chat"):
        assert extension_id in investigation
    for tool in (
        "get_memory_snapshot",
        "get_active_workshop_grants",
        "get_query_store_top_queries",
        "get_query_store_waits",
        "get_procedure_plan_summary",
        "compare_workshop_runs",
    ):
        assert tool in investigation
    assert "MCP: List Servers" in investigation
    assert "dab validate --config mcp/dab-config.json" in investigation
    assert "sql/04-CreateBaselineProcedure.sql" in proof
    assert "sql/06-CreateOptimizedProcedure.sql" in proof
    assert "sql/07-ValidateEquivalence.sql" in proof
    assert "ABBA BAAB ABBA" in proof
    assert "sql/08-OptionalQueryStoreHint.sql" in proof


def test_prompt_book_has_twelve_distinct_prompts_with_required_headings() -> None:
    prompt_book = read("prompts/investigation-prompts.md")
    sections = re.split(r"(?m)^## Prompt \d+:", prompt_book)[1:]
    assert len(sections) >= 12
    assert len({section.splitlines()[0].strip() for section in sections}) == len(sections)
    for section in sections:
        assert all(f"### {heading}" in section for heading in PROMPT_HEADINGS)


def test_rubric_scores_required_dimensions_and_has_fail_conditions() -> None:
    rubric = read("prompts/prompt-evaluation-rubric.md")
    for dimension in (
        "Evidence attribution",
        "Contract preservation",
        "Security",
        "Reversibility",
        "Measurement quality",
        "Certainty",
    ):
        assert dimension in rubric
    assert "Automatic fail conditions" in rubric


def test_sources_are_official_mapped_and_verified_on_required_date() -> None:
    sources = read("docs/evidence-and-sources.md")
    assert "2026-09-01" in sources
    assert sources.count("https://learn.microsoft.com/") >= 12
    for label in ("DOC-VERIFIED", "SUBSCRIPTION-VALIDATED", "LAB-MEASURED", "TARGET", "ASSUMPTION"):
        assert label in sources
    assert "Claim" in sources and "Official source" in sources


def test_dab_authorization_uses_canonical_official_url_without_network_access(
    tmp_path: Path,
) -> None:
    assert DAB_AUTHORIZATION_URL in OFFICIAL_EXTERNAL_LINK_ALLOWLIST
    assert DAB_AUTHORIZATION_URL in read("workshop/01-mcp-and-copilot.md")
    assert DAB_AUTHORIZATION_URL in read("docs/evidence-and-sources.md")

    build_site(ROOT, tmp_path)
    generated = "\n".join(
        path.read_text(encoding="utf-8") for path in sorted(tmp_path.glob("*.html"))
    )
    assert generated.count(DAB_AUTHORIZATION_URL) == 2
    assert "/azure/data-api-builder/concept/authorization" not in generated.replace(
        DAB_AUTHORIZATION_URL, ""
    )


def test_screenshot_manifest_is_truthful_and_complete() -> None:
    manifest = json.loads(SCREENSHOT_MANIFEST_PATH.read_text(encoding="utf-8"))
    entries = manifest["screenshots"]
    assert [entry["file"] for entry in entries] == SCREENSHOTS
    assert "LocalVerified" in manifest["allowedClassifications"]
    assert "AzurePending" in manifest["allowedClassifications"]
    assert manifest["redactionRules"]
    for entry in entries:
        image = ROOT / "docs" / "images" / entry["file"]
        if entry["classification"].endswith("Verified"):
            assert image.is_file(), f"Verified screenshot is absent: {entry['file']}"
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            assert entry.get("sha256") == digest
        if not image.is_file():
            assert not entry["classification"].endswith("Verified")
            assert entry.get("sha256") in (None, "")


def test_missing_screenshots_render_pending_cards_not_broken_images(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    generated = "\n".join(path.read_text(encoding="utf-8") for path in tmp_path.glob("*.html"))
    for name in SCREENSHOTS:
        image = ROOT / "docs" / "images" / name
        if not image.exists():
            assert f'data-screenshot-file="{name}"' in generated
    assert "Screenshot pending verified milestone" in generated


def test_screenshot_rendering_requires_verified_manifest_decision(tmp_path: Path) -> None:
    image_root = tmp_path / "images"
    image_root.mkdir()
    (image_root / "capture.png").write_bytes(b"real-capture")
    source = "![Verified milestone](docs/images/capture.png)"

    unverified = render_markdown(source, image_root, verified_screenshots=set())
    verified = render_markdown(source, image_root, verified_screenshots={"capture.png"})

    assert "Screenshot pending verified milestone" in unverified
    assert "<img " not in unverified
    assert '<img src="docs/images/capture.png"' in verified


def test_no_unsupported_claims_or_unfinished_placeholders() -> None:
    content = all_content()
    lowered = content.lower()
    for phrase in ("guaranteed 40%", "copilot fixed", "sql mcp can run any query"):
        assert phrase not in lowered
    assert not re.search(r"(?im)\b(?:TBD|TODO)\b", content)
    assert not re.search(r"(?m)^\s*\[!LAB-MEASURED\]", content)


def test_built_routes_have_no_missing_internal_links_or_assets(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    for page in manifest["pages"]:
        html_path = tmp_path / page["route"]
        assert html_path.is_file()
        soup = BeautifulSoup(html_path.read_text(encoding="utf-8"), "html.parser")
        references = [
            *((tag, "href") for tag in soup.select("a[href]")),
            *((tag, "src") for tag in soup.select("[src]")),
        ]
        for element, attribute in references:
            value = element.get(attribute, "")
            parsed = urlsplit(value)
            if parsed.scheme or parsed.netloc or value.startswith(("#", "mailto:")):
                continue
            target = (html_path.parent / parsed.path).resolve()
            assert target.exists(), f"Missing internal target from {page['route']}: {value}"