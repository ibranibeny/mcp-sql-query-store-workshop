import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

from web.build_site import build_site, load_manifest, render_markdown

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "web" / "site-manifest.json"


def write_manifest(path: Path, pages: list[dict[str, object]], **site: str) -> Path:
    manifest = {
        "site": {
            "title": "Test workshop",
            "description": "Test description",
            "language": "en",
            **site,
        },
        "pages": pages,
    }
    path.write_text(json.dumps(manifest), encoding="utf-8")
    return path


def page(**overrides: object) -> dict[str, object]:
    return {
        "source": "content.md",
        "route": "index.html",
        "title": "Test page",
        "phase": "Orientation",
        "durationMinutes": 15,
        **overrides,
    }


def make_site_root(tmp_path: Path) -> Path:
    root = tmp_path / "repo"
    (root / "web" / "templates").mkdir(parents=True)
    for template in ("base.html", "page.html"):
        (root / "web" / "templates" / template).write_text(
            (ROOT / "web" / "templates" / template).read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    (root / "content.md").write_text("# Content", encoding="utf-8")
    write_manifest(root / "web" / "site-manifest.json", [page()])
    return root


def make_directory_link(link: Path, target: Path, *, junction: bool = False) -> None:
    if junction:
        result = subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(target)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            pytest.skip(f"Windows junction creation is unavailable: {result.stderr}")
        return

    try:
        link.symlink_to(target, target_is_directory=True)
    except OSError as error:
        pytest.skip(f"Directory symlink creation is unavailable: {error}")


def test_manifest_has_unique_ordered_routes_and_existing_sources() -> None:
    manifest = load_manifest(MANIFEST_PATH)
    routes = [entry["route"] for entry in manifest["pages"]]

    assert routes[0] == "index.html"
    assert len(routes) == len(set(routes))
    assert all(route.endswith(".html") for route in routes)
    assert all((ROOT / entry["source"]).is_file() for entry in manifest["pages"])


def test_load_manifest_requires_site_metadata_and_nonempty_pages(tmp_path: Path) -> None:
    (tmp_path / "content.md").write_text("# Content", encoding="utf-8")
    missing_site = tmp_path / "missing-site.json"
    missing_site.write_text(json.dumps({"pages": [page()]}), encoding="utf-8")
    empty_pages = write_manifest(tmp_path / "empty-pages.json", [])

    with pytest.raises(ValueError, match="site"):
        load_manifest(missing_site, root=tmp_path)
    with pytest.raises(ValueError, match="pages"):
        load_manifest(empty_pages, root=tmp_path)


@pytest.mark.parametrize("property_name", ["source", "route", "title", "phase", "durationMinutes"])
def test_load_manifest_requires_every_page_property(tmp_path: Path, property_name: str) -> None:
    (tmp_path / "content.md").write_text("# Content", encoding="utf-8")
    incomplete_page = page()
    del incomplete_page[property_name]
    path = write_manifest(tmp_path / "manifest.json", [incomplete_page])

    with pytest.raises(ValueError, match=property_name):
        load_manifest(path, root=tmp_path)


def test_missing_source_is_rejected(tmp_path: Path) -> None:
    path = write_manifest(
        tmp_path / "manifest.json",
        [page(source="workshop/missing.md")],
    )

    with pytest.raises(FileNotFoundError):
        load_manifest(path, root=tmp_path)


@pytest.mark.parametrize(
    "routes",
    [
        ["index.html", "index.html"],
        ["index.html", "../outside.html"],
        ["index.html", "/absolute.html"],
        ["index.html", "nested/page.txt"],
        ["index.html", r"nested\page.html"],
        ["index.html", "nested/./page.html"],
        ["index.html", "Page.html", "page.html"],
        ["index.html", "percent%2fencoded.html"],
        ["index.html", "folder./page.html"],
        ["home.html"],
    ],
)
def test_duplicate_or_unsafe_routes_are_rejected(tmp_path: Path, routes: list[str]) -> None:
    (tmp_path / "content.md").write_text("# Content", encoding="utf-8")
    pages = [page(route=route, title=f"Page {index}") for index, route in enumerate(routes)]
    path = write_manifest(tmp_path / "manifest.json", pages)

    with pytest.raises(ValueError, match="route"):
        load_manifest(path, root=tmp_path)


@pytest.mark.parametrize(
    "routes",
    [
        ["index.html", "index.html/child.html"],
        ["index.html", "GUIDES/Page.html", "guides/page.html"],
        ["index.html", "assets/page.html"],
    ],
)
def test_route_tree_collisions_and_reserved_assets_namespace_are_rejected(
    tmp_path: Path, routes: list[str],
) -> None:
    (tmp_path / "content.md").write_text("# Content", encoding="utf-8")
    pages = [page(route=route, title=f"Page {index}") for index, route in enumerate(routes)]
    path = write_manifest(tmp_path / "manifest.json", pages)

    with pytest.raises(ValueError, match="route"):
        load_manifest(path, root=tmp_path)


def test_source_traversal_is_rejected_even_when_target_exists(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    root.mkdir()
    (tmp_path / "outside.md").write_text("outside", encoding="utf-8")
    path = write_manifest(
        root / "manifest.json",
        [page(source="../outside.md")],
    )

    with pytest.raises(ValueError, match="source"):
        load_manifest(path, root=root)


@pytest.mark.parametrize("duration", [-1, 1.5, True, "15"])
def test_duration_must_be_a_nonnegative_integer(tmp_path: Path, duration: object) -> None:
    (tmp_path / "content.md").write_text("# Content", encoding="utf-8")
    path = write_manifest(
        tmp_path / "manifest.json",
        [page(durationMinutes=duration)],
    )

    with pytest.raises(ValueError, match="durationMinutes"):
        load_manifest(path, root=tmp_path)


def test_render_markdown_supports_tables_toc_highlighting_and_safe_static_diagrams() -> None:
    rendered = render_markdown(
        "# Heading\n\n"
        "| A | B |\n|---|---|\n| 1 | 2 |\n\n"
        "```python\nprint('<safe>')\n```\n\n"
        "```mermaid\nflowchart LR\n  A[\"<script>alert(1)</script>\"] --> B\n```\n"
    )

    assert '<a class="headerlink"' in rendered
    assert "<table>" in rendered
    assert "highlight" in rendered
    assert '<figure class="architecture-diagram flowchart-diagram">' in rendered
    assert '<svg xmlns="http://www.w3.org/2000/svg"' in rendered
    assert 'role="img"' in rendered
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in rendered
    assert "<script>alert(1)</script>" not in rendered


def test_render_markdown_transforms_evidence_markers_but_not_code() -> None:
    rendered = render_markdown(
        "[!DOC-VERIFIED] [!SUBSCRIPTION-VALIDATED] [!LAB-MEASURED] "
        "[!ASSUMPTION] [!TARGET]\n\n"
        "`[!TARGET]`\n\n"
        "```text\n[!TARGET]\n```\n"
    )

    for label in (
        "DOC-VERIFIED",
        "SUBSCRIPTION-VALIDATED",
        "LAB-MEASURED",
        "ASSUMPTION",
        "TARGET",
    ):
        assert f'data-evidence-label="{label}"' in rendered
    assert rendered.count('data-evidence-label="TARGET"') == 1
    assert rendered.count("[!TARGET]") == 2


def test_render_markdown_escapes_source_authored_html() -> None:
    rendered = render_markdown('<script src="https://cdn.jsdelivr.net/attack.js"></script>')

    assert "<script" not in rendered
    assert "&lt;script" in rendered


def test_render_markdown_does_not_transform_attributes_and_blocks_active_urls() -> None:
    rendered = render_markdown(
        '[safe title](https://example.test "[!TARGET]") '
        "[unsafe](javascript:alert(1))"
    )

    assert 'title="[!TARGET]"' in rendered
    assert 'data-evidence-label="TARGET"' not in rendered
    assert "javascript:" not in rendered


def test_build_emits_title_static_diagram_target_and_navigation(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    html = (tmp_path / "index.html").read_text(encoding="utf-8")

    assert "MCP SQL Query Store Workshop" in html
    assert '<figure class="architecture-diagram flowchart-diagram">' in html
    assert '<svg xmlns="http://www.w3.org/2000/svg"' in html
    assert 'data-evidence-label="TARGET"' in html
    assert 'aria-label="Workshop modules"' in html
    assert html.count("<main") == 1
    assert (tmp_path / "facilitator-guide.html").is_file()


def test_architecture_route_contains_two_build_time_svg_diagrams(tmp_path: Path) -> None:
    build_site(ROOT, tmp_path)
    architecture = (tmp_path / "02-scenario-and-architecture.html").read_text(
        encoding="utf-8"
    )

    assert architecture.count('<figure class="architecture-diagram ') == 2
    assert architecture.count('<svg xmlns="http://www.w3.org/2000/svg"') == 2
    assert '<figure class="architecture-diagram flowchart-diagram">' in architecture
    assert '<figure class="architecture-diagram sequence-diagram">' in architecture
    assert '<pre class="mermaid">' not in architecture


def test_generated_text_files_have_no_trailing_whitespace(tmp_path: Path) -> None:
    manifest = load_manifest(MANIFEST_PATH)
    build_site(ROOT, tmp_path)
    generated_text_files = [tmp_path / entry["route"] for entry in manifest["pages"]]

    for source in (ROOT / "web" / "assets").rglob("*"):
        if not source.is_file():
            continue
        try:
            source.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        generated_text_files.append(tmp_path / "assets" / source.relative_to(ROOT / "web" / "assets"))

    violations = []
    for path in generated_text_files:
        relative_path = path.relative_to(tmp_path)
        for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            if line != line.rstrip(" \t"):
                violations.append(f"{relative_path}:{line_number}")

    assert not violations, "Trailing whitespace in generated text: " + ", ".join(violations)


def test_build_escapes_manifest_values_creates_nested_routes_and_needs_no_assets(tmp_path: Path) -> None:
    root = tmp_path / "repo"
    (root / "web" / "templates").mkdir(parents=True)
    for template in ("base.html", "page.html"):
        (root / "web" / "templates" / template).write_text(
            (ROOT / "web" / "templates" / template).read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    (root / "content.md").write_text("# Safe content", encoding="utf-8")
    write_manifest(
        root / "web" / "site-manifest.json",
        [page(title='<img src=x onerror="alert(1)">'), page(route="guides/page.html", title="Next")],
        title="<script>alert(1)</script>",
    )
    destination = tmp_path / "site"

    build_site(root, destination)
    html = (destination / "index.html").read_text(encoding="utf-8")

    assert (destination / "guides" / "page.html").is_file()
    assert "&lt;script&gt;alert(1)&lt;/script&gt;" in html
    assert "&lt;img src=x onerror=&#34;alert(1)&#34;&gt;" in html
    assert "<script>alert(1)</script>" not in html
    assert not (destination / "assets").exists()


def test_build_removes_stale_destination_content(tmp_path: Path) -> None:
    destination = tmp_path / "site"
    (destination / "assets").mkdir(parents=True)
    (destination / "obsolete.html").write_text("stale", encoding="utf-8")
    (destination / "assets" / "obsolete.js").write_text("stale", encoding="utf-8")

    build_site(ROOT, destination)

    assert not (destination / "obsolete.html").exists()
    assert not (destination / "assets" / "obsolete.js").exists()


@pytest.mark.skipif(os.name != "nt", reason="Windows read-only directory regression")
def test_build_removes_ordinary_read_only_destination(tmp_path: Path) -> None:
    destination = tmp_path / "site"
    destination.mkdir()
    (destination / "obsolete.html").write_text("stale", encoding="utf-8")
    subprocess.run(["attrib", "+R", str(destination)], check=True)

    build_site(ROOT, destination)

    assert not (destination / "obsolete.html").exists()
    assert (destination / "index.html").is_file()


def test_build_rejects_symlink_in_destination_ancestors_without_deleting_target(
    tmp_path: Path,
) -> None:
    external = tmp_path / "external"
    destination_target = external / "site"
    destination_target.mkdir(parents=True)
    keep = destination_target / "keep.txt"
    keep.write_text("DO-NOT-DELETE", encoding="utf-8")
    link = tmp_path / "site-link"
    make_directory_link(link, external)

    with pytest.raises(ValueError, match="destination"):
        build_site(ROOT, link / "site")

    assert keep.read_text(encoding="utf-8") == "DO-NOT-DELETE"


@pytest.mark.skipif(os.name != "nt", reason="Windows junction regression")
def test_build_rejects_junction_in_destination_ancestors_without_deleting_target(
    tmp_path: Path,
) -> None:
    external = tmp_path / "external"
    destination_target = external / "site"
    destination_target.mkdir(parents=True)
    keep = destination_target / "keep.txt"
    keep.write_text("DO-NOT-DELETE", encoding="utf-8")
    junction = tmp_path / "site-junction"
    make_directory_link(junction, external, junction=True)

    with pytest.raises(ValueError, match="destination"):
        build_site(ROOT, junction / "site")

    assert keep.read_text(encoding="utf-8") == "DO-NOT-DELETE"


def test_build_rejects_symlinked_asset_file_without_copying_external_content(
    tmp_path: Path,
) -> None:
    root = make_site_root(tmp_path)
    assets = root / "web" / "assets"
    assets.mkdir()
    external = tmp_path / "secret.txt"
    external.write_text("EXTERNAL", encoding="utf-8")
    try:
        (assets / "linked.txt").symlink_to(external)
    except OSError as error:
        pytest.skip(f"File symlink creation is unavailable: {error}")
    destination = tmp_path / "site"
    destination.mkdir()
    stale = destination / "keep.txt"
    stale.write_text("DO-NOT-DELETE", encoding="utf-8")

    with pytest.raises(ValueError, match="asset"):
        build_site(root, destination)

    assert not (destination / "assets" / "linked.txt").exists()
    assert stale.read_text(encoding="utf-8") == "DO-NOT-DELETE"


@pytest.mark.skipif(os.name != "nt", reason="Windows junction regression")
def test_build_rejects_junctioned_asset_directory_without_copying_external_content(
    tmp_path: Path,
) -> None:
    root = make_site_root(tmp_path)
    assets = root / "web" / "assets"
    assets.mkdir()
    external = tmp_path / "external-assets"
    external.mkdir()
    (external / "keep.txt").write_text("EXTERNAL", encoding="utf-8")
    make_directory_link(assets / "linked", external, junction=True)
    destination = tmp_path / "site"
    destination.mkdir()
    stale = destination / "keep.txt"
    stale.write_text("DO-NOT-DELETE", encoding="utf-8")

    with pytest.raises(ValueError, match="asset"):
        build_site(root, destination)

    assert not (destination / "assets" / "linked" / "keep.txt").exists()
    assert stale.read_text(encoding="utf-8") == "DO-NOT-DELETE"


@pytest.mark.parametrize(
    "relative_destination",
    [
        ".",
        "web",
        "web/assets",
        "web/assets/nested-output",
        "web/templates",
        "web/templates/nested-output",
        "workshop",
        "workshop/nested-output",
        "docs",
        "docs/nested-output",
    ],
)
def test_build_rejects_protected_source_destination_before_deletion(
    tmp_path: Path, relative_destination: str,
) -> None:
    root = tmp_path / "repo"
    (root / "web" / "templates").mkdir(parents=True)
    (root / "web" / "assets").mkdir()
    (root / "workshop").mkdir()
    (root / "docs").mkdir()
    for template in ("base.html", "page.html"):
        (root / "web" / "templates" / template).write_text(
            (ROOT / "web" / "templates" / template).read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    (root / "workshop" / "content.md").write_text("# Workshop", encoding="utf-8")
    (root / "docs" / "guide.md").write_text("# Guide", encoding="utf-8")
    write_manifest(
        root / "web" / "site-manifest.json",
        [
            page(source="workshop/content.md"),
            page(source="docs/guide.md", route="guide.html", title="Guide"),
        ],
    )
    destination = root / relative_destination
    destination.mkdir(parents=True, exist_ok=True)
    marker = destination / "source-marker.txt"
    marker.write_text("DO-NOT-DELETE", encoding="utf-8")

    with pytest.raises(ValueError, match="destination"):
        build_site(root, destination)

    assert marker.read_text(encoding="utf-8") == "DO-NOT-DELETE"


def test_build_rejects_git_destination_before_deletion(tmp_path: Path) -> None:
    root = make_site_root(tmp_path)
    destination = root / ".git"
    destination.mkdir()
    marker = destination / "HEAD"
    marker.write_text("protected metadata", encoding="utf-8")

    with pytest.raises(ValueError, match="destination"):
        build_site(root, destination)

    assert marker.read_text(encoding="utf-8") == "protected metadata"


@pytest.mark.parametrize("relative_destination", ["output", "arbitrary-folder"])
def test_build_rejects_arbitrary_in_repository_destination_before_deletion(
    tmp_path: Path, relative_destination: str,
) -> None:
    root = make_site_root(tmp_path)
    destination = root / relative_destination
    destination.mkdir()
    marker = destination / "keep.txt"
    marker.write_text("DO-NOT-DELETE", encoding="utf-8")

    with pytest.raises(ValueError, match="destination"):
        build_site(root, destination)

    assert marker.read_text(encoding="utf-8") == "DO-NOT-DELETE"


def test_build_allows_ignored_site_directory_inside_repository(tmp_path: Path) -> None:
    root = make_site_root(tmp_path)
    destination = root / "site"
    destination.mkdir()
    (destination / "obsolete.html").write_text("stale", encoding="utf-8")

    build_site(root, destination)

    assert (destination / "index.html").is_file()
    assert not (destination / "obsolete.html").exists()


@pytest.mark.skipif(os.name != "nt", reason="Windows junction regression")
def test_build_rejects_reparse_point_at_permitted_site_destination(
    tmp_path: Path,
) -> None:
    root = make_site_root(tmp_path)
    external = tmp_path / "external-site"
    external.mkdir()
    marker = external / "keep.txt"
    marker.write_text("DO-NOT-DELETE", encoding="utf-8")
    make_directory_link(root / "site", external, junction=True)

    with pytest.raises(ValueError, match="destination"):
        build_site(root, root / "site")

    assert marker.read_text(encoding="utf-8") == "DO-NOT-DELETE"


def test_cli_returns_nonzero_for_invalid_input(tmp_path: Path) -> None:
    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "web" / "build_site.py"),
            "--root",
            str(tmp_path),
            "--output",
            str(tmp_path / "site"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
