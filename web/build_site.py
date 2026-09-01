from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import stat
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import urlsplit

import markdown
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape
from markupsafe import Markup

EVIDENCE_RE = re.compile(
    r"\[!(DOC-VERIFIED|SUBSCRIPTION-VALIDATED|LAB-MEASURED|ASSUMPTION|TARGET)\]"
)
MERMAID_FENCE_RE = re.compile(
    r"^```mermaid[ \t]*\r?\n(?P<diagram>.*?)^```[ \t]*$",
    re.MULTILINE | re.DOTALL,
)
SCREENSHOT_RE = re.compile(
    r"!\[(?P<alt>[^\]]+)\]\(docs/images/(?P<name>[A-Za-z0-9._-]+\.png)\)"
)
TRAILING_WHITESPACE_RE = re.compile(r"[ \t]+(?=\r?$)", re.MULTILINE)
REQUIRED_SITE_PROPERTIES = ("title", "description", "language")
REQUIRED_PAGE_PROPERTIES = ("source", "route", "title", "phase", "durationMinutes")
ALLOWED_URL_SCHEMES = {"", "http", "https", "mailto"}


def _require_nonempty_string(value: Any, property_name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{property_name} must be a nonempty string")
    return value


def _resolve_source(root: Path, source_value: Any) -> Path:
    source = _require_nonempty_string(source_value, "source")
    relative = Path(source)
    if relative.is_absolute():
        raise ValueError(f"Invalid source outside repository root: {source}")

    resolved_root = root.resolve()
    resolved_source = (resolved_root / relative).resolve()
    try:
        resolved_source.relative_to(resolved_root)
    except ValueError as error:
        raise ValueError(f"Invalid source outside repository root: {source}") from error

    if not resolved_source.is_file():
        raise FileNotFoundError(resolved_source)
    return resolved_source


def _validate_route(route_value: Any) -> str:
    route = _require_nonempty_string(route_value, "route")
    path = PurePosixPath(route)
    if (
        "\\" in route
        or "%" in route
        or path.is_absolute()
        or path.as_posix() != route
        or path.suffix.lower() != ".html"
        or any(part in {"", ".", ".."} for part in path.parts)
        or any(part.rstrip(" .") != part for part in path.parts)
        or ":" in route
        or "?" in route
        or "#" in route
    ):
        raise ValueError(f"Invalid route: {route}")
    return route


def _is_link_or_reparse_point(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False
    attributes = getattr(metadata, "st_file_attributes", 0)
    reparse_attribute = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return stat.S_ISLNK(metadata.st_mode) or bool(attributes & reparse_attribute)


def _reject_linked_path_components(path: Path, description: str) -> Path:
    absolute = Path(os.path.abspath(path))
    for component in reversed((absolute, *absolute.parents)):
        if _is_link_or_reparse_point(component):
            raise ValueError(f"{description} must not use a symbolic link or reparse point: {component}")
    return absolute


def _validate_asset_path(path: Path, canonical_root: Path) -> None:
    if _is_link_or_reparse_point(path):
        raise ValueError(f"Asset source must not use a symbolic link or reparse point: {path}")
    try:
        path.resolve(strict=True).relative_to(canonical_root)
    except (FileNotFoundError, ValueError) as error:
        raise ValueError(f"Asset source escapes the assets root: {path}") from error


def _validate_asset_tree(assets: Path) -> Path:
    if _is_link_or_reparse_point(assets):
        raise ValueError(f"Asset source must not use a symbolic link or reparse point: {assets}")
    canonical_root = assets.resolve(strict=True)
    _validate_asset_path(assets, canonical_root)
    pending = [assets]
    while pending:
        directory = pending.pop()
        for entry in os.scandir(directory):
            path = Path(entry.path)
            _validate_asset_path(path, canonical_root)
            if entry.is_dir(follow_symlinks=False):
                pending.append(path)
    return canonical_root


def _copy_asset_tree(source: Path, destination: Path, canonical_root: Path) -> None:
    _validate_asset_path(source, canonical_root)
    destination.mkdir()
    for entry in os.scandir(source):
        source_path = Path(entry.path)
        destination_path = destination / entry.name
        _validate_asset_path(source_path, canonical_root)
        if entry.is_dir(follow_symlinks=False):
            _copy_asset_tree(source_path, destination_path, canonical_root)
        elif entry.is_file(follow_symlinks=False):
            shutil.copy2(source_path, destination_path, follow_symlinks=False)
        else:
            raise ValueError(f"Unsupported asset source entry: {source_path}")


def _remove_destination(path: Path) -> None:
    def remove_read_only(
        operation: Any, failed_path: str | bytes | os.PathLike[str], error: OSError,
    ) -> None:
        if not isinstance(error, PermissionError):
            raise error
        os.chmod(failed_path, stat.S_IWRITE)
        operation(failed_path)

    shutil.rmtree(path, onexc=remove_read_only)


def load_manifest(path: Path, root: Path | None = None) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("Manifest must be a JSON object")

    site = manifest.get("site")
    if not isinstance(site, dict):
        raise ValueError("Manifest site metadata is required")
    for property_name in REQUIRED_SITE_PROPERTIES:
        _require_nonempty_string(site.get(property_name), f"site.{property_name}")

    pages = manifest.get("pages")
    if not isinstance(pages, list) or not pages:
        raise ValueError("Manifest pages must be a nonempty array")

    repository_root = (root or path.parents[1]).resolve()
    routes: set[tuple[str, ...]] = set()
    for index, page in enumerate(pages):
        if not isinstance(page, dict):
            raise ValueError(f"pages[{index}] must be an object")
        for property_name in REQUIRED_PAGE_PROPERTIES:
            if property_name not in page:
                raise ValueError(f"pages[{index}].{property_name} is required")

        _resolve_source(repository_root, page["source"])
        route = _validate_route(page["route"])
        route_key = tuple(part.casefold() for part in PurePosixPath(route).parts)
        if route_key[0] == "assets":
            raise ValueError(f"Invalid route in reserved assets namespace: {route}")
        if route_key in routes:
            raise ValueError(f"Duplicate route: {route}")
        if any(
            route_key[: len(existing)] == existing
            or existing[: len(route_key)] == route_key
            for existing in routes
        ):
            raise ValueError(f"Invalid route tree collision: {route}")
        routes.add(route_key)

        _require_nonempty_string(page["title"], f"pages[{index}].title")
        _require_nonempty_string(page["phase"], f"pages[{index}].phase")
        duration = page["durationMinutes"]
        if isinstance(duration, bool) or not isinstance(duration, int) or duration < 0:
            raise ValueError(
                f"pages[{index}].durationMinutes must be a nonnegative integer"
            )

    if pages[0]["route"] != "index.html":
        raise ValueError("The first route must be index.html")
    return manifest


class _SafeRenderedHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=False)
        self.parts: list[str] = []
        self.code_depth = 0

    def _append_start_tag(
        self, tag: str, attrs: list[tuple[str, str | None]], *, closed: bool
    ) -> None:
        self.parts.append(f"<{tag}")
        for name, value in attrs:
            if value is None:
                self.parts.append(f" {name}")
                continue
            if name.lower() in {"href", "src"}:
                scheme = urlsplit(value.strip()).scheme.lower()
                if scheme not in ALLOWED_URL_SCHEMES:
                    value = "#blocked-url"
            self.parts.append(f' {name}="{html.escape(value, quote=True)}"')
        self.parts.append(" />" if closed else ">")

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._append_start_tag(tag, attrs, closed=False)
        if tag.lower() in {"code", "pre"}:
            self.code_depth += 1

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._append_start_tag(tag, attrs, closed=True)

    def handle_endtag(self, tag: str) -> None:
        self.parts.append(f"</{tag}>")
        if tag.lower() in {"code", "pre"}:
            self.code_depth = max(0, self.code_depth - 1)

    def handle_data(self, data: str) -> None:
        if self.code_depth:
            self.parts.append(data)
            return

        def replace_marker(match: re.Match[str]) -> str:
            label = match.group(1)
            return (
                f'<span class="evidence-label" data-evidence-label="{label}">'
                f"{label}</span>"
            )

        self.parts.append(EVIDENCE_RE.sub(replace_marker, data))

    def handle_entityref(self, name: str) -> None:
        self.parts.append(f"&{name};")

    def handle_charref(self, name: str) -> None:
        self.parts.append(f"&#{name};")

    def handle_comment(self, data: str) -> None:
        self.parts.append(f"<!--{data}-->")


def _sanitize_rendered_html(rendered: str) -> str:
    parser = _SafeRenderedHTMLParser()
    parser.feed(rendered)
    parser.close()
    return "".join(parser.parts)


def render_markdown(
    text: str,
    screenshot_root: Path | None = None,
    verified_screenshots: set[str] | None = None,
) -> str:
    mermaid_blocks: list[str] = []
    screenshot_blocks: list[str] = []

    def reserve_screenshot(match: re.Match[str]) -> str:
        name = match.group("name")
        alt = match.group("alt")
        token = f"MCPWORKSHOPSCREENSHOT{len(screenshot_blocks)}TOKEN"
        image = screenshot_root / name if screenshot_root is not None else None
        if (
            image is not None
            and image.is_file()
            and verified_screenshots is not None
            and name in verified_screenshots
        ):
            block = (
                '<figure class="verified-screenshot">'
                f'<img src="docs/images/{html.escape(name, quote=True)}" '
                f'alt="{html.escape(alt, quote=True)}" loading="lazy">'
                f'<figcaption>{html.escape(alt)}</figcaption></figure>'
            )
        else:
            block = (
                '<aside class="screenshot-pending" role="note" '
                f'data-screenshot-file="{html.escape(name, quote=True)}">'
                '<strong>Screenshot pending verified milestone</strong>'
                f'<span>{html.escape(alt)} · {html.escape(name)}</span></aside>'
            )
        screenshot_blocks.append(block)
        return f"\n\n{token}\n\n"

    def reserve_mermaid(match: re.Match[str]) -> str:
        token = f"MCPWORKSHOPMERMAID{len(mermaid_blocks)}TOKEN"
        diagram = match.group("diagram").rstrip("\r\n")
        mermaid_blocks.append(
            f'<pre class="mermaid">{html.escape(diagram, quote=False)}</pre>'
        )
        return f"\n\n{token}\n\n"

    prepared = SCREENSHOT_RE.sub(reserve_screenshot, text)
    prepared = MERMAID_FENCE_RE.sub(reserve_mermaid, prepared)
    converter = markdown.Markdown(
        extensions=["tables", "toc", "pymdownx.superfences", "pymdownx.highlight"],
        extension_configs={
            "toc": {"permalink": True, "permalink_title": "Permanent link"},
            "pymdownx.highlight": {"anchor_linenums": True},
        },
        output_format="html5",
    )
    converter.preprocessors.deregister("html_block")
    converter.inlinePatterns.deregister("html")
    rendered = converter.convert(prepared)
    for index, block in enumerate(mermaid_blocks):
        token = f"MCPWORKSHOPMERMAID{index}TOKEN"
        rendered = rendered.replace(f"<p>{token}</p>", block)
    for index, block in enumerate(screenshot_blocks):
        token = f"MCPWORKSHOPSCREENSHOT{index}TOKEN"
        rendered = rendered.replace(f"<p>{token}</p>", block)
    return _sanitize_rendered_html(rendered)


def _relative_href(current_route: str, target_route: str) -> str:
    current_directory = str(PurePosixPath(current_route).parent)
    return os.path.relpath(target_route, start=current_directory).replace("\\", "/")


def _normalize_generated_text(text: str) -> str:
    return TRAILING_WHITESPACE_RE.sub("", text)


def _verified_screenshot_names(root: Path) -> set[str]:
    screenshot_root = root / "docs" / "images"
    manifest_path = screenshot_root / "screenshot-manifest.json"
    if not manifest_path.is_file():
        return set()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verified: set[str] = set()
    for entry in manifest.get("screenshots", []):
        if not isinstance(entry, dict):
            continue
        name = entry.get("file")
        classification = entry.get("classification")
        expected_hash = entry.get("sha256")
        if not isinstance(name, str) or not isinstance(classification, str):
            continue
        image = screenshot_root / name
        if not classification.endswith("Verified") or not image.is_file():
            continue
        actual_hash = hashlib.sha256(image.read_bytes()).hexdigest()
        if isinstance(expected_hash, str) and actual_hash == expected_hash.lower():
            verified.add(name)
    return verified


def build_site(root: Path, destination: Path) -> None:
    root = root.resolve()
    destination = _reject_linked_path_components(
        destination, "Site destination"
    ).resolve(strict=False)
    if destination == root or root.is_relative_to(destination):
        raise ValueError("Site destination must not contain the repository root")
    if destination.is_relative_to(root) and destination != root / "site":
        raise ValueError("Site destination inside the repository must be root/site")
    manifest_path = root / "web" / "site-manifest.json"
    manifest = load_manifest(manifest_path, root=root)
    content_sources = [
        (root / page["source"]).resolve() for page in manifest["pages"]
    ]
    protected_paths = {
        (root / "web").resolve(),
        manifest_path.resolve(),
        (root / "web" / "templates").resolve(),
        *content_sources,
        *(source.parent for source in content_sources if source.parent != root),
    }
    assets = root / "web" / "assets"
    canonical_assets = None
    if os.path.lexists(assets):
        canonical_assets = _validate_asset_tree(assets)
        protected_paths.add(canonical_assets)
    if any(
        protected == destination
        or protected.is_relative_to(destination)
        or destination.is_relative_to(protected)
        for protected in protected_paths
    ):
        raise ValueError("Site destination must not contain source files")
    environment = Environment(
        loader=FileSystemLoader(root / "web" / "templates"),
        undefined=StrictUndefined,
        autoescape=select_autoescape(enabled_extensions=("html", "xml"), default=True),
    )
    page_template = environment.get_template("page.html")

    if destination.exists():
        if not destination.is_dir():
            raise ValueError("Site destination must be a directory")
        _remove_destination(destination)
    destination.mkdir(parents=True)
    if canonical_assets is not None:
        _copy_asset_tree(assets, destination / "assets", canonical_assets)
    screenshot_root = root / "docs" / "images"
    verified_screenshots = _verified_screenshot_names(root)
    if screenshot_root.is_dir():
        screenshot_destination = destination / "docs" / "images"
        for image in screenshot_root.glob("*.png"):
            if (
                image.name in verified_screenshots
                and image.is_file()
                and not _is_link_or_reparse_point(image)
            ):
                screenshot_destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(image, screenshot_destination / image.name)

    pages = manifest["pages"]
    for index, page in enumerate(pages):
        route = page["route"]
        navigation = [
            {**entry, "href": _relative_href(route, entry["route"])}
            for entry in pages
        ]
        previous = navigation[index - 1] if index else None
        next_page = navigation[index + 1] if index + 1 < len(navigation) else None
        source_text = (root / page["source"]).read_text(encoding="utf-8")
        output = page_template.render(
            site=manifest["site"],
            page=page,
            pages=navigation,
            content=Markup(
                render_markdown(
                    source_text,
                    screenshot_root,
                    verified_screenshots=verified_screenshots,
                )
            ),
            previous=previous,
            next=next_page,
            asset_prefix=_relative_href(route, "assets/").rstrip("/"),
        )
        output_path = destination / route
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(_normalize_generated_text(output), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the MCP SQL workshop site")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=Path("site"))
    args = parser.parse_args()
    build_site(args.root.resolve(), args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
