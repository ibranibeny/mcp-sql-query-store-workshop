from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess

from bs4 import BeautifulSoup

from web.build_site import build_site

ROOT = Path(__file__).resolve().parents[2]


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


def test_assets_define_exact_palette_typography_and_accessibility_rules(tmp_path: Path) -> None:
    destination, _ = build_pages(tmp_path)
    css = (destination / "assets/styles.css").read_text(encoding="utf-8")

    expected_tokens = {
        "--canvas": "#07131f",
        "--panel": "#0d2233",
        "--text": "#e7f2f8",
        "--muted": "#9ab0bf",
        "--evidence-measured": "#35d0e8",
        "--evidence-hypothesis": "#f1b84b",
        "--safety-stop": "#ff5a65",
        "--decision": "#59d98e",
    }
    for token, value in expected_tokens.items():
        assert re.search(rf"{re.escape(token)}\s*:\s*{re.escape(value)}\s*;", css, re.IGNORECASE)

    assert "IBM Plex Sans" in css
    assert "Cascadia Code" in css
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


def test_scripts_are_csp_friendly_pinned_modules(tmp_path: Path) -> None:
    _, pages = build_pages(tmp_path)
    soup = pages[0]

    local_module = soup.select_one('script[type="module"][src$="assets/app.js"]')
    assert local_module is not None
    app = (ROOT / "web/assets/app.js").read_text(encoding="utf-8")
    assert "https://cdn.jsdelivr.net/npm/mermaid@11.12.0/dist/mermaid.esm.min.mjs" in app
    assert not soup.select("script:not([src])")
    csp = soup.select_one('meta[http-equiv="Content-Security-Policy"]')["content"]
    assert "script-src 'self' https://cdn.jsdelivr.net" in csp
    assert "style-src 'self' 'unsafe-inline'" in csp
    assert "script-src 'self' 'unsafe-inline'" not in csp
    assert "'unsafe-eval'" not in csp


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