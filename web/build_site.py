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
FLOW_NODE_RE = re.compile(
    r'^\s*(?P<id>[A-Za-z][A-Za-z0-9_-]*)(?:\["(?P<quoted>.*?)"\]|\[(?P<plain>.*?)\])?'
    r'(?::::(?P<cls>[A-Za-z][A-Za-z0-9_-]*))?\s*$'
)
FLOW_ARROW_RE = re.compile(r'\s*-->\s*(?:\|"?(.*?)"?\|\s*)?')
SEQUENCE_PARTICIPANT_RE = re.compile(
    r"^\s*(?:actor|participant)\s+(?P<id>[A-Za-z][A-Za-z0-9_-]*)"
    r"(?:\s+as\s+(?P<label>.+?))?\s*$"
)
SEQUENCE_MESSAGE_RE = re.compile(
    r"^\s*(?P<source>[A-Za-z][A-Za-z0-9_-]*?)\s*"
    r"(?P<arrow>-->>|->>|-->|->)\s*(?P<target>[A-Za-z][A-Za-z0-9_-]*)"
    r"\s*:\s*(?P<label>.+?)\s*$"
)


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


def _text_lines(value: str, limit: int = 28) -> list[str]:
    value = re.sub(r"<br\s*/?>", "\n", value, flags=re.IGNORECASE)
    lines: list[str] = []
    for explicit_line in value.splitlines() or [""]:
        words = explicit_line.split()
        current = ""
        for word in words:
            candidate = f"{current} {word}".strip()
            if current and len(candidate) > limit:
                lines.append(current)
                current = word
            else:
                current = candidate
        lines.append(current)
    return lines or [""]


def _svg_text(x: int, y: int, value: str, *, css_class: str) -> str:
    lines = _text_lines(value)
    start_y = y - ((len(lines) - 1) * 8)
    spans = "".join(
        f'<tspan x="{x}" y="{start_y + index * 17}">{html.escape(line)}</tspan>'
        for index, line in enumerate(lines)
    )
    return f'<text class="{css_class}" text-anchor="middle">{spans}</text>'


def _parse_flow_node(specification: str) -> tuple[str, str, str | None]:
    match = FLOW_NODE_RE.match(specification)
    if match is None:
        raise ValueError(f"Unsupported flowchart node: {specification.strip()}")
    identifier = match.group("id")
    label = match.group("quoted") or match.group("plain") or identifier
    return identifier, label, match.group("cls")


def _accessible_text(value: str) -> str:
    value = re.sub(r"<br\s*/?>", " / ", value, flags=re.IGNORECASE)
    value = re.sub(r"<[^>]*>", "", value)
    return " ".join(html.unescape(value).split())


def _topological_flow_layout(
    nodes: dict[str, str], edges: list[tuple[str, str, str]], direction: str,
) -> tuple[dict[str, tuple[int, int]], int, int, int]:
    order = {identifier: index for index, identifier in enumerate(nodes)}
    outgoing = {identifier: [] for identifier in nodes}
    indegree = {identifier: 0 for identifier in nodes}
    for source, target, _ in edges:
        outgoing[source].append(target)
        indegree[target] += 1

    pending = [identifier for identifier in nodes if indegree[identifier] == 0]
    topological_order: list[str] = []
    layers = {identifier: 0 for identifier in nodes}
    while pending:
        pending.sort(key=order.__getitem__)
        source = pending.pop(0)
        topological_order.append(source)
        for target in outgoing[source]:
            layers[target] = max(layers[target], layers[source] + 1)
            indegree[target] -= 1
            if indegree[target] == 0:
                pending.append(target)
    if len(topological_order) != len(nodes):
        raise ValueError("Flowchart cycles are not supported by the static renderer")

    rows: dict[str, int] = {}
    occupied: set[tuple[int, int]] = set()
    next_row = 0
    for source in topological_order:
        if source not in rows:
            while (layers[source], next_row) in occupied:
                next_row += 1
            rows[source] = next_row
            occupied.add((layers[source], next_row))
            next_row += 1
        unplaced_index = 0
        for target in outgoing[source]:
            if target in rows:
                continue
            candidate = rows[source] if unplaced_index == 0 else next_row
            while (layers[target], candidate) in occupied:
                candidate += 1
            rows[target] = candidate
            occupied.add((layers[target], candidate))
            next_row = max(next_row, candidate + 1)
            unplaced_index += 1

    node_width, node_height, margin = 160, 72, 30
    max_layer = max(layers.values())
    max_row = max(rows.values())
    if direction == "LR":
        positions = {
            identifier: (
                margin + node_width // 2 + layers[identifier] * 220,
                margin + node_height // 2 + rows[identifier] * 140,
            )
            for identifier in nodes
        }
        nodes_width = margin * 2 + node_width + max_layer * 220
        nodes_height = margin * 2 + node_height + max_row * 140
    else:
        positions = {
            identifier: (
                margin + node_width // 2 + rows[identifier] * 210,
                margin + node_height // 2 + layers[identifier] * 120,
            )
            for identifier in nodes
        }
        nodes_width = margin * 2 + node_width + max_row * 210
        nodes_height = margin * 2 + node_height + max_layer * 120
    return positions, nodes_width, nodes_height, max_layer


def _flow_route_points(
    source: tuple[int, int],
    target: tuple[int, int],
    *,
    horizontal: bool,
    long_route_lane: int | None,
) -> list[tuple[int, int]]:
    source_x, source_y = source
    target_x, target_y = target
    if horizontal:
        start, end = (source_x + 80, source_y), (target_x - 80, target_y)
        if long_route_lane is not None:
            return [start, (start[0], long_route_lane), (end[0], long_route_lane), end]
        if start[1] == end[1]:
            return [start, end]
        middle_x = (start[0] + end[0]) // 2
        return [start, (middle_x, start[1]), (middle_x, end[1]), end]

    start, end = (source_x, source_y + 36), (target_x, target_y - 36)
    if long_route_lane is not None:
        return [start, (long_route_lane, start[1]), (long_route_lane, end[1]), end]
    if start[0] == end[0]:
        return [start, end]
    middle_y = (start[1] + end[1]) // 2
    return [start, (start[0], middle_y), (end[0], middle_y), end]


def _flow_accessibility(
    nodes: dict[str, str], edges: list[tuple[str, str, str]], direction: str,
) -> tuple[str, str]:
    labels = {identifier: _accessible_text(label) for identifier, label in nodes.items()}
    edge_summary = "; ".join(
        f"{labels[source]} to {labels[target]}"
        + (f" ({_accessible_text(edge_label)})" if edge_label else "")
        for source, target, edge_label in edges
    )
    title = f"{direction} architecture flowchart: " + ", ".join(labels.values())
    description = "Nodes: " + ", ".join(labels.values()) + ". Edges: " + edge_summary + "."
    return title, description


def _render_flowchart(diagram: str) -> str:
    lines = [line for line in diagram.splitlines() if line.strip()]
    direction = lines[0].split(maxsplit=1)[1].strip().upper()
    if direction not in {"LR", "TD"}:
        raise ValueError(f"Unsupported flowchart direction: {direction}")

    nodes: dict[str, str] = {}
    node_classes: dict[str, str] = {}
    edges: list[tuple[str, str, str]] = []
    for line in lines[1:]:
        parts = FLOW_ARROW_RE.split(line.strip())
        if len(parts) < 3:
            continue
        source_id, source_label, source_class = _parse_flow_node(parts[0])
        nodes.setdefault(source_id, source_label)
        if source_class:
            node_classes.setdefault(source_id, source_class)
        for index in range(1, len(parts), 2):
            edge_label = (parts[index] or "").strip('"')
            target_id, target_label, target_class = _parse_flow_node(parts[index + 1])
            nodes.setdefault(target_id, target_label)
            if target_class:
                node_classes.setdefault(target_id, target_class)
            edges.append((source_id, target_id, edge_label))
            source_id = target_id

    identifiers = list(nodes)
    if not identifiers:
        raise ValueError("Flowchart contains no nodes")
    horizontal = direction == "LR"
    positions, width, height, _ = _topological_flow_layout(nodes, edges, direction)
    layer_coordinate = {
        identifier: positions[identifier][0 if horizontal else 1]
        for identifier in identifiers
    }
    long_edges = [
        (source, target)
        for source, target, _ in edges
        if abs(layer_coordinate[target] - layer_coordinate[source])
        > (220 if horizontal else 120)
    ]
    if long_edges:
        if horizontal:
            lane_base = height + 10
            height += 40 + (len(long_edges) - 1) * 28
        else:
            lane_base = width + 10
            width += 40 + (len(long_edges) - 1) * 28
    else:
        lane_base = 0
    marker_id = f"flow-arrow-{hashlib.sha256(diagram.encode('utf-8')).hexdigest()[:10]}"
    title, description = _flow_accessibility(nodes, edges, direction)
    parts = [
        '<figure class="architecture-diagram flowchart-diagram">',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-labelledby="{marker_id}-title {marker_id}-desc">',
        f'<title id="{marker_id}-title">{html.escape(title)}</title>',
        f'<desc id="{marker_id}-desc">{html.escape(description)}</desc>',
        f'<defs><marker id="{marker_id}" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto"><path class="diagram-arrowhead" d="M0,0 L0,6 L9,3 z"></path></marker></defs>',
    ]
    long_edge_index = 0
    for source, target, edge_label in edges:
        is_long = (source, target) in long_edges
        lane = lane_base + long_edge_index * 28 if is_long else None
        route = _flow_route_points(
            positions[source], positions[target], horizontal=horizontal, long_route_lane=lane
        )
        if is_long:
            long_edge_index += 1
        path = " ".join(
            f'{"M" if index == 0 else "L"} {x} {y}'
            for index, (x, y) in enumerate(route)
        )
        parts.append(
            f'<path class="diagram-edge" data-source="{html.escape(source, quote=True)}" '
            f'data-target="{html.escape(target, quote=True)}" d="{path}" fill="none" '
            f'marker-end="url(#{marker_id})"></path>'
        )
        if edge_label:
            longest_start, longest_end = max(
                zip(route, route[1:]),
                key=lambda segment: abs(segment[1][0] - segment[0][0]) + abs(segment[1][1] - segment[0][1]),
            )
            label_x = (longest_start[0] + longest_end[0]) // 2
            label_y = (longest_start[1] + longest_end[1]) // 2 - 10
            parts.append(_svg_text(label_x, label_y, edge_label, css_class="diagram-edge-label"))
    for identifier, label in nodes.items():
        x, y = positions[identifier]
        category = node_classes.get(identifier)
        node_class = "diagram-node"
        if category:
            node_class += f" diagram-node--{category}"
        parts.append(
            f'<rect class="{node_class}" data-node-id="{html.escape(identifier, quote=True)}" '
            f'x="{x - 80}" y="{y - 36}" width="160" height="72" rx="8"></rect>'
        )
        parts.append(_svg_text(x, y + 5, label, css_class="diagram-node-label"))
    parts.extend(("</svg>", f'<details><summary>Diagram source</summary><pre>{html.escape(diagram)}</pre></details>', "</figure>"))
    return "".join(parts)


def _render_sequence(diagram: str) -> str:
    participants: dict[str, str] = {}
    messages: list[tuple[str, str, str, bool]] = []
    autonumber = False
    for line in diagram.splitlines()[1:]:
        if line.strip() == "autonumber":
            autonumber = True
            continue
        participant = SEQUENCE_PARTICIPANT_RE.match(line)
        if participant:
            identifier = participant.group("id")
            participants[identifier] = participant.group("label") or identifier
            continue
        message = SEQUENCE_MESSAGE_RE.match(line)
        if message:
            source = message.group("source")
            target = message.group("target")
            participants.setdefault(source, source)
            participants.setdefault(target, target)
            messages.append(
                (source, target, message.group("label"), message.group("arrow").startswith("--"))
            )

    if not participants:
        raise ValueError("Sequence diagram contains no participants")
    step = 190
    participant_half_width = 70
    horizontal_margin = 30
    first_position = horizontal_margin + participant_half_width
    positions = {
        identifier: first_position + step * index
        for index, identifier in enumerate(participants)
    }
    width = max(
        260,
        max(positions.values()) + participant_half_width + horizontal_margin,
    )
    height = 130 + 48 * len(messages)
    marker_id = f"sequence-arrow-{hashlib.sha256(diagram.encode('utf-8')).hexdigest()[:10]}"
    participant_labels = {
        identifier: _accessible_text(label) for identifier, label in participants.items()
    }
    title = "Architecture sequence: " + ", ".join(participant_labels.values())
    description = "Participants: " + ", ".join(participant_labels.values()) + ". Messages: " + "; ".join(
        f"{participant_labels[source]} to {participant_labels[target]}: {_accessible_text(label)}"
        for source, target, label, _ in messages
    ) + "."
    parts = [
        '<figure class="architecture-diagram sequence-diagram">',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" role="img" aria-labelledby="{marker_id}-title {marker_id}-desc">',
        f'<title id="{marker_id}-title">{html.escape(title)}</title>',
        f'<desc id="{marker_id}-desc">{html.escape(description)}</desc>',
        f'<defs><marker id="{marker_id}" markerWidth="10" markerHeight="10" refX="9" refY="3" orient="auto"><path class="diagram-arrowhead" d="M0,0 L0,6 L9,3 z"></path></marker></defs>',
    ]
    for identifier, label in participants.items():
        x = positions[identifier]
        parts.append(f'<rect class="diagram-node" x="{x - 70}" y="15" width="140" height="42" rx="8"></rect>')
        parts.append(_svg_text(x, 41, label, css_class="diagram-node-label"))
        parts.append(f'<line class="diagram-lifeline" x1="{x}" y1="57" x2="{x}" y2="{height - 20}"></line>')
    for index, (source, target, label, dashed) in enumerate(messages, start=1):
        y = 82 + (index - 1) * 48
        display_label = f"{index}. {label}" if autonumber else label
        dash = ' stroke-dasharray="6 4"' if dashed else ""
        parts.append(
            f'<line class="diagram-edge" x1="{positions[source]}" y1="{y}" x2="{positions[target]}" y2="{y}"{dash} marker-end="url(#{marker_id})"></line>'
        )
        parts.append(_svg_text((positions[source] + positions[target]) // 2, y - 8, display_label, css_class="diagram-edge-label"))
    parts.extend(("</svg>", f'<details><summary>Diagram source</summary><pre>{html.escape(diagram)}</pre></details>', "</figure>"))
    return "".join(parts)


def _render_mermaid_static_svg(diagram: str) -> str:
    first_line = diagram.splitlines()[0].strip() if diagram.strip() else ""
    if first_line.startswith("flowchart "):
        return _render_flowchart(diagram)
    if first_line == "sequenceDiagram":
        return _render_sequence(diagram)
    raise ValueError(f"Unsupported Mermaid diagram type: {first_line}")


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
        mermaid_blocks.append(_render_mermaid_static_svg(diagram))
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
