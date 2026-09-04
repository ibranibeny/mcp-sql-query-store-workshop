from __future__ import annotations

import base64
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from bs4 import BeautifulSoup

from web.build_site import build_site

ROOT = Path(__file__).resolve().parents[2]

CLAWPILOT_THEME_SCRIPT = (
    "\n"
    "  (() => {\n"
    '    const param = new URLSearchParams(window.location.search).get("scoutTheme");\n'
    "    const theme =\n"
    '      param || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");\n'
    '    document.documentElement.setAttribute("data-theme", theme);\n'
    "  })();\n"
)

CLAWPILOT_THEME_CSS = ''':root {
    color-scheme: light;
    --cp-bg: #f7f4ef;
    --cp-bg-elevated: #fcfbf8;
    --cp-surface: #ffffff;
    --cp-surface-soft: #f5f5f5;
    --cp-border: #dedede;
    --cp-border-strong: #919191;
    --cp-text: #242424;
    --cp-text-muted: #5c5c5c;
    --cp-text-soft: #6f6f6f;
    --cp-accent: #b11f4b;
    --cp-accent-hover: #9a1a41;
    --cp-accent-soft: rgba(177, 31, 75, 0.08);
    --cp-accent-fg: #ffffff;
    --cp-success: #16a34a;
    --cp-danger: #dc2626;
    --cp-warning: #f59e0b;
    --cp-link: #0078d4;
    --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.12);
    --cp-overlay: rgba(255, 255, 255, 0.8);
    --cp-panel: rgba(255, 255, 255, 0.86);
    --cp-panel-strong: rgba(255, 255, 255, 0.96);
    --cp-sheen: rgba(255, 255, 255, 0.55);
    --cp-highlight: rgba(177, 31, 75, 0.12);
    --cp-diagram-ext-fill: #fde68a;
    --cp-diagram-ext-stroke: #b45309;
    --cp-diagram-pub-fill: #fecaca;
    --cp-diagram-pub-stroke: #b91c1c;
    --cp-diagram-admin-fill: #bfdbfe;
    --cp-diagram-admin-stroke: #1d4ed8;
    --cp-diagram-mcp-fill: #ddd6fe;
    --cp-diagram-mcp-stroke: #6d28d9;
    --cp-diagram-sql-fill: #bbf7d0;
    --cp-diagram-sql-stroke: #15803d;
    --cp-diagram-data-fill: #dcfce7;
    --cp-diagram-data-stroke: #16a34a;
    --cp-diagram-net-fill: #cffafe;
    --cp-diagram-net-stroke: #0e7490;
}
html[data-theme="dark"] {
    color-scheme: dark;
    --cp-bg: #3d3b3a;
    --cp-bg-elevated: #343231;
    --cp-surface: #292929;
    --cp-surface-soft: #2e2e2e;
    --cp-border: #474747;
    --cp-border-strong: #5f5f5f;
    --cp-text: #dedede;
    --cp-text-muted: #919191;
    --cp-text-soft: #b0b0b0;
    --cp-accent: #fd8ea1;
    --cp-accent-hover: #fb7b91;
    --cp-accent-soft: rgba(253, 142, 161, 0.14);
    --cp-accent-fg: #1a1a1a;
    --cp-success: #4ade80;
    --cp-danger: #f87171;
    --cp-warning: #fbbf24;
    --cp-link: #4da6ff;
    --cp-shadow: 0 18px 48px rgba(0, 0, 0, 0.32);
    --cp-overlay: rgba(41, 41, 41, 0.88);
    --cp-panel: rgba(41, 41, 41, 0.72);
    --cp-panel-strong: rgba(41, 41, 41, 0.96);
    --cp-sheen: rgba(255, 255, 255, 0.04);
    --cp-highlight: rgba(253, 142, 161, 0.12);
    --cp-diagram-ext-fill: #4d3a12;
    --cp-diagram-ext-stroke: #f59e0b;
    --cp-diagram-pub-fill: #4d1f1f;
    --cp-diagram-pub-stroke: #f87171;
    --cp-diagram-admin-fill: #1e2f4d;
    --cp-diagram-admin-stroke: #60a5fa;
    --cp-diagram-mcp-fill: #2e2450;
    --cp-diagram-mcp-stroke: #a78bfa;
    --cp-diagram-sql-fill: #14351f;
    --cp-diagram-sql-stroke: #4ade80;
    --cp-diagram-data-fill: #123024;
    --cp-diagram-data-stroke: #34d399;
    --cp-diagram-net-fill: #0e3038;
    --cp-diagram-net-stroke: #22d3ee;
}
'''


def build_pages(tmp_path: Path) -> tuple[Path, list[BeautifulSoup]]:
    destination = tmp_path / "site"
    build_site(ROOT, destination)
    manifest = json.loads((ROOT / "web/site-manifest.json").read_text(encoding="utf-8"))
    pages = [
        BeautifulSoup((destination / page["route"]).read_text(encoding="utf-8"), "html.parser")
        for page in manifest["pages"]
    ]
    return destination, pages


def test_every_page_has_accessible_document_and_landmarks(tmp_path: Path) -> None:
    _, pages = build_pages(tmp_path)

    for soup in pages:
        assert soup.html and soup.html.get("lang") == "en"
        assert soup.title and soup.title.get_text(strip=True)
        assert soup.select_one('meta[name="viewport"][content="width=device-width, initial-scale=1"]')
        assert soup.select_one('a.skip-link[href="#main-content"]')
        assert len(soup.select("main")) == 1
        assert soup.select_one("main#main-content")
        assert soup.select_one("nav[aria-label='Workshop modules']")
        assert len(soup.select("article")) == 1
        assert soup.select_one("article > header > h1")
        assert soup.select_one("body > footer")


def test_module_navigation_and_progress_controls_are_accessible(tmp_path: Path) -> None:
    _, pages = build_pages(tmp_path)

    for soup in pages:
        module_nav = soup.select_one("nav[aria-label='Workshop modules']")
        assert module_nav is not None and module_nav.get("id")
        toggle = soup.select_one("button[data-nav-toggle]")
        assert toggle and toggle.get("aria-controls") == module_nav["id"]
        assert toggle.get("aria-expanded") == "false"
        progress = soup.select_one("button[data-progress-toggle]")
        assert progress and progress.get("aria-pressed") == "false"
        assert progress.get("data-module-id")
        assert soup.select_one('[role="status"][data-progress-status]')


def test_module_navigation_links_are_ordered_execution_plan_nodes(tmp_path: Path) -> None:
    _, pages = build_pages(tmp_path)

    for soup in pages:
        links = soup.select(".module-navigation ol > li.module-node > a.module-node-link")
        assert links
        for link in links:
            glyphs = link.select(".module-operator-glyph[aria-hidden='true']")
            assert len(glyphs) == 1
            assert not glyphs[0].get_text(strip=True)


def test_module_navigation_css_scopes_plan_nodes_and_flow_connectors(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    css = (destination / "assets/styles.css").read_text(encoding="utf-8")

    assert re.search(r"\.module-navigation\s+\.module-node-link\s*\{", css)
    assert re.search(r"\.module-navigation\s+\.module-operator-glyph\s*\{", css)
    assert re.search(
        r"\.module-navigation\s+\.module-node\s*\+\s*\.module-node::before\s*\{",
        css,
    )
    assert re.search(
        r"\.module-navigation\s+\.module-node\s*\+\s*\.module-node::after\s*\{",
        css,
    )
    assert re.search(
        r"\.module-navigation\s+\.module-node-link\[aria-current=\"page\"\]"
        r"\s+\.module-operator-glyph\s*\{",
        css,
    )
    node_rule = re.search(
        r"\.module-navigation\s+\.module-node\s*\{(?P<body>[^}]*)\}", css
    )
    connector_rule = re.search(
        r"\.module-navigation\s+\.module-node\s*\+\s*\.module-node::before\s*\{"
        r"(?P<body>[^}]*)\}",
        css,
    )
    arrow_rule = re.search(
        r"\.module-navigation\s+\.module-node\s*\+\s*\.module-node::after\s*\{"
        r"(?P<body>[^}]*)\}",
        css,
    )
    assert node_rule and "flex: 0 0 14rem" in node_rule.group("body")
    assert connector_rule and "left: calc(-100% + 1.5rem)" in connector_rule.group("body")
    assert "width: 100%" in connector_rule.group("body")
    assert arrow_rule and "left: 0.55rem" in arrow_rule.group("body")
    assert "min-height: 4.5rem" in css
    assert "@media (forced-colors: active) and (max-width: 640px)" in css
    assert "@media print" in css


def test_page_has_evidence_path_and_progressive_grant_calculator(tmp_path: Path) -> None:
    _, pages = build_pages(tmp_path)
    soup = pages[0]

    path_labels = [item.get_text(" ", strip=True) for item in soup.select(".evidence-path li")]
    assert path_labels == ["TARGET / HYPOTHESIS", "MEASURED", "DECISION"]
    form = soup.select_one("form[data-grant-calculator]")
    assert form is not None
    for field in (
        "baseline-granted-kb",
        "baseline-total-kb",
        "optimized-granted-kb",
        "optimized-total-kb",
    ):
        control = form.select_one(f"#{field}")
        assert control and control.get("type") == "number"
        assert form.select_one(f'label[for="{field}"]')
    assert form.select_one("button[type='submit']")
    assert form.select_one("output#grant-result[aria-live='polite']")
    assert "TARGET" in form.get_text(" ", strip=True)
    assert "LAB-MEASURED" not in form.get_text(" ", strip=True)


def test_assets_define_exact_clawpilot_theme_typography_and_accessibility_rules(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    css = (destination / "assets/styles.css").read_text(encoding="utf-8")

    contract_end = css.index("}\n", css.index('html[data-theme="dark"]')) + 2
    normalize = lambda value: "\n".join(line.strip() for line in value.splitlines())
    assert normalize(css[:contract_end]) == normalize(CLAWPILOT_THEME_CSS)

    expected_tokens = {
        "--cp-bg": ("#f7f4ef", "#3d3b3a"),
        "--cp-bg-elevated": ("#fcfbf8", "#343231"),
        "--cp-surface": ("#ffffff", "#292929"),
        "--cp-surface-soft": ("#f5f5f5", "#2e2e2e"),
        "--cp-border": ("#dedede", "#474747"),
        "--cp-border-strong": ("#919191", "#5f5f5f"),
        "--cp-text": ("#242424", "#dedede"),
        "--cp-text-muted": ("#5c5c5c", "#919191"),
        "--cp-text-soft": ("#6f6f6f", "#b0b0b0"),
        "--cp-accent": ("#b11f4b", "#fd8ea1"),
        "--cp-accent-hover": ("#9a1a41", "#fb7b91"),
        "--cp-accent-soft": ("rgba(177, 31, 75, 0.08)", "rgba(253, 142, 161, 0.14)"),
        "--cp-accent-fg": ("#ffffff", "#1a1a1a"),
        "--cp-success": ("#16a34a", "#4ade80"),
        "--cp-danger": ("#dc2626", "#f87171"),
        "--cp-warning": ("#f59e0b", "#fbbf24"),
        "--cp-link": ("#0078d4", "#4da6ff"),
    }
    for token, values in expected_tokens.items():
        for value in values:
            assert re.search(rf"{re.escape(token)}\s*:\s*{re.escape(value)}\s*;", css, re.IGNORECASE)

    assert '"Segoe UI", Aptos, Calibri' in css
    assert 'Consolas, "Courier New", Courier, monospace' in css
    assert "min-height: 44px" in css
    assert ":focus-visible" in css
    assert "@media (max-width: 960px)" in css
    assert "@media (max-width: 640px)" in css
    assert "@media (prefers-contrast: more)" in css
    assert "@media (forced-colors: active)" in css
    assert "@media (prefers-reduced-motion: reduce)" in css
    assert "@media print" in css
    assert "linear-gradient" not in css
    assert "backdrop-filter" not in css

    declarations = re.sub(r"--cp-[\w-]+\s*:\s*[^;]+;", "", css)
    assert not re.search(r"#[0-9a-f]{3,8}|rgba?\(|hsla?\(", declarations, re.IGNORECASE)


def test_scripts_and_csp_do_not_allow_remote_executable_code(tmp_path: Path) -> None:
    destination, pages = build_pages(tmp_path)
    soup = pages[0]

    local_module = soup.select_one('script[type="module"][src$="assets/app.js"]')
    assert local_module is not None
    scripts = soup.select("script")
    assert scripts[0].get("src") is None
    assert scripts[0].string == CLAWPILOT_THEME_SCRIPT
    app = (destination / "assets/app.js").read_text(encoding="utf-8")
    assert "https://" not in app
    assert "http://" not in app
    assert "cdn.jsdelivr.net" not in app
    assert "import(" not in app
    assert len(soup.select("script:not([src])")) == 1
    expected_hash = base64.b64encode(
        hashlib.sha256(CLAWPILOT_THEME_SCRIPT.encode("utf-8")).digest()
    ).decode("ascii")
    for page in pages:
        csp = page.select_one('meta[http-equiv="Content-Security-Policy"]')["content"]
        assert "script-src 'self'" in csp
        assert f"'sha256-{expected_hash}'" in csp
        assert "style-src 'self' 'unsafe-inline'" in csp
        assert "http://" not in csp
        assert "https://" not in csp
        assert "'unsafe-eval'" not in csp


def test_architecture_route_preserves_two_static_svg_diagrams(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    soup = BeautifulSoup(
        (destination / "02-scenario-and-architecture.html").read_text(encoding="utf-8"),
        "html.parser",
    )

    diagrams = soup.select("figure.architecture-diagram > svg[role='img']")
    assert len(diagrams) == 2
    assert soup.select_one("figure.flowchart-diagram > svg title")
    assert soup.select_one("figure.sequence-diagram > svg title")
    assert not soup.select("pre.mermaid")


def test_architecture_route_svg_nodes_are_inside_complete_viewboxes(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    soup = BeautifulSoup(
        (destination / "02-scenario-and-architecture.html").read_text(encoding="utf-8"),
        "html.parser",
    )

    for svg in soup.select("figure.architecture-diagram > svg"):
        view_x, view_y, view_width, view_height = map(float, svg["viewbox"].split())
        assert view_width > 0 and view_height > 0
        for node in svg.select("rect.diagram-node"):
            x, y = float(node["x"]), float(node["y"])
            width, height = float(node["width"]), float(node["height"])
            assert view_x <= x < x + width <= view_x + view_width
            assert view_y <= y < y + height <= view_y + view_height


def test_architecture_flow_routes_are_deterministic_orthogonal_and_avoid_other_nodes(
    tmp_path: Path,
) -> None:
    first_destination, _ = build_pages(tmp_path / "first")
    second_destination, _ = build_pages(tmp_path / "second")

    def flow_svg(destination: Path):
        soup = BeautifulSoup(
            (destination / "02-scenario-and-architecture.html").read_text(encoding="utf-8"),
            "html.parser",
        )
        return soup.select_one("figure.flowchart-diagram > svg")

    first = flow_svg(first_destination)
    second = flow_svg(second_destination)
    assert first is not None and second is not None
    assert str(first) == str(second)

    boxes = {
        node["data-node-id"]: (
            float(node["x"]),
            float(node["y"]),
            float(node["x"]) + float(node["width"]),
            float(node["y"]) + float(node["height"]),
        )
        for node in first.select("rect.diagram-node[data-node-id]")
    }
    assert {"A", "SN", "S", "NAT"}.issubset(boxes)

    routes = first.select("path.diagram-edge[data-source][data-target]")
    assert routes
    for route in routes:
        coordinates = [float(value) for value in re.findall(r"-?\d+(?:\.\d+)?", route["d"])]
        points = list(zip(coordinates[::2], coordinates[1::2]))
        assert len(points) >= 2
        for (x1, y1), (x2, y2) in zip(points, points[1:]):
            assert x1 == x2 or y1 == y2
            for node_id, (left, top, right, bottom) in boxes.items():
                if node_id in {route["data-source"], route["data-target"]}:
                    continue
                crosses_horizontal = y1 == y2 and top < y1 < bottom and max(x1, x2) > left and min(x1, x2) < right
                crosses_vertical = x1 == x2 and left < x1 < right and max(y1, y2) > top and min(y1, y2) < bottom
                assert not (crosses_horizontal or crosses_vertical), (
                    f'{route["data-source"]} -> {route["data-target"]} crosses {node_id}'
                )


def test_architecture_svgs_describe_parsed_relationships_and_retain_sources(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    soup = BeautifulSoup(
        (destination / "02-scenario-and-architecture.html").read_text(encoding="utf-8"),
        "html.parser",
    )
    flow = soup.select_one("figure.flowchart-diagram > svg")
    sequence = soup.select_one("figure.sequence-diagram > svg")
    assert flow is not None and sequence is not None

    assert "Facilitator workstation" in flow.title.get_text(" ", strip=True)
    assert "Facilitator workstation to Admin public IP" in flow.desc.get_text(" ", strip=True)
    assert "to NAT Gateway" in flow.desc.get_text(" ", strip=True)
    assert "to Query Store" in flow.desc.get_text(" ", strip=True)
    assert "DBA" in sequence.title.get_text(" ", strip=True)
    assert "Private SQL Server" in sequence.title.get_text(" ", strip=True)
    assert "DBA to Az PowerShell: Run read-only preflight" in sequence.desc.get_text(" ", strip=True)
    assert "Private SQL Server to Query Store: Persist plans, runtime, and waits" in sequence.desc.get_text(" ", strip=True)
    for svg in (flow, sequence):
        labelled_by = svg["aria-labelledby"].split()
        assert labelled_by == [svg.title["id"], svg.desc["id"]]
    for figure in soup.select("figure.architecture-diagram"):
        assert figure.select_one("details > summary").get_text(strip=True) == "Diagram source"
        assert "mermaid" not in figure.select_one("details > pre").get("class", [])


def test_architecture_sequence_replies_use_only_declared_participants(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    soup = BeautifulSoup(
        (destination / "02-scenario-and-architecture.html").read_text(encoding="utf-8"),
        "html.parser",
    )
    sequence = soup.select_one("figure.sequence-diagram > svg")
    assert sequence is not None

    description = sequence.desc.get_text(" ", strip=True)
    participant_text, message_text = description.removeprefix("Participants: ").split(
        ". Messages: ", maxsplit=1
    )
    assert participant_text.split(", ") == [
        "DBA",
        "Az PowerShell",
        "Azure",
        "VS Code + Copilot",
        "MSSQL extension",
        "DAB SQL MCP",
        "Private SQL Server",
        "Query Store",
    ]
    assert len(sequence.select("rect.diagram-node")) == 8
    for invented_participant in ("AZ-", "SQL-", "MCP-", "VS-"):
        assert invented_participant not in description
    for reply in (
        "Azure to Az PowerShell: Current subscription evidence",
        "Private SQL Server to DAB SQL MCP: Typed evidence",
        "DAB SQL MCP to VS Code + Copilot: Structured result",
        "VS Code + Copilot to DBA: Observations, gaps, hypotheses, experiments",
        "Private SQL Server to DBA: Actual outcome and evidence bundle",
    ):
        assert reply in message_text


def test_script_contracts_cover_helpers_and_safe_dom_adapters(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    script = (destination / "assets/app.js").read_text(encoding="utf-8")

    assert "export function grantUtilization(grantedKb, totalKb)" in script
    assert "export function targetStatus(baseline, optimized)" in script
    assert "navigator.clipboard.writeText" in script
    assert "localStorage" in script
    assert "mcp-sql-workshop:v1:module-progress" in script
    assert "data-nav-toggle" in script
    assert "data-grant-calculator" in script
    assert "data-site-search" in script
    assert 'querySelectorAll("pre:not(.mermaid)")' in script
    assert "event.target instanceof Element" in script
    assert "textContent" in script
    assert "innerHTML" not in script
    assert "matchMedia(\"(prefers-reduced-motion: reduce)\")" in script


def test_pure_javascript_helper_semantics_when_node_is_available(tmp_path: Path) -> None:
    node = shutil.which("node")
    if node is None:
        return

    source = (ROOT / "web/assets/app.js").read_text(encoding="utf-8")
    source = re.sub(r"^import mermaid from .*?;\s*", "", source, count=1)
    module_path = tmp_path / "helpers.mjs"
    module_path.write_text(source, encoding="utf-8")
    checks = tmp_path / "checks.mjs"
    checks.write_text(
        "import assert from 'node:assert/strict';\n"
        "import { grantUtilization, targetStatus } from './helpers.mjs';\n"
        "assert.equal(grantUtilization(40, 100), 40);\n"
        "assert.equal(targetStatus(80, 40), 'TargetMet');\n"
        "assert.equal(targetStatus(70, 40), 'ImprovedOutsideTarget');\n"
        "assert.equal(targetStatus(60, 50), 'NoMaterialImprovement');\n"
        "for (const values of [[-1, 10], [1, 0], [11, 10], [NaN, 10]]) {\n"
        "  assert.throws(() => grantUtilization(...values), TypeError);\n"
        "}\n"
        "for (const values of [[-1, 40], [80, -1], [101, 40], [80, 101], [NaN, 40]]) {\n"
        "  assert.throws(() => targetStatus(...values), TypeError);\n"
        "}\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [node, str(checks)],
        cwd=tmp_path,
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr