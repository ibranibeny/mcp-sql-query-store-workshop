from __future__ import annotations

import argparse
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path
import re
from typing import Iterable


REQUIREMENT_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)"
    r">=(?P<minimum>[^,\s]+),<(?P<maximum>[^\s]+)$"
)
VERSION_RE = re.compile(
    r"""
    ^\s*v?
    (?:(?P<epoch>\d+)!)?
    (?P<release>\d+(?:\.\d+)*)
    (?:[-_.]?(?P<prerelease>a|b|c|rc|alpha|beta|pre|preview)
       [-_.]?(?P<prerelease_number>\d+)?)?
    (?:
        -(?P<post_hyphen>\d+)
        |
        [-_.]?(?P<post_name>post|rev|r)[-_.]?(?P<post_number>\d+)?
    )?
    (?:[-_.]?(?P<dev_name>dev)[-_.]?(?P<dev_number>\d+)?)?
    (?:\+(?P<local>[a-z0-9]+(?:[-_.][a-z0-9]+)*))?
    \s*$
    """,
    re.IGNORECASE | re.VERBOSE,
)
CANONICAL_NAME_RE = re.compile(r"[-_.]+")


@dataclass(frozen=True)
class Requirement:
    name: str
    minimum: str
    maximum: str

    @property
    def required(self) -> str:
        return f">={self.minimum},<{self.maximum}"


@dataclass(frozen=True)
class ParsedVersion:
    epoch: int
    release: tuple[int, ...]
    prerelease: tuple[int, int] | None
    post: int | None
    dev: int | None
    local: tuple[tuple[int, str | int], ...] | None

    @property
    def key(self) -> tuple[object, ...]:
        if self.prerelease is None:
            prerelease_key = (0, 0, 0) if self.dev is not None and self.post is None else (2, 0, 0)
        else:
            prerelease_key = (1, self.prerelease[0], self.prerelease[1])
        post_key = (0, 0) if self.post is None else (1, self.post)
        dev_key = (1, 0) if self.dev is None else (0, self.dev)
        local_key = (0,) if self.local is None else (1, self.local)
        return (
            self.epoch,
            self.release,
            prerelease_key,
            post_key,
            dev_key,
            local_key,
        )


def canonicalize_name(name: str) -> str:
    return CANONICAL_NAME_RE.sub("-", name).lower()


def parse_version(
    value: str,
) -> ParsedVersion:
    match = VERSION_RE.fullmatch(value)
    if match is None:
        raise ValueError(f"Invalid PEP 440 version: {value!r}")

    release = tuple(int(part) for part in match.group("release").split("."))
    while len(release) > 1 and release[-1] == 0:
        release = release[:-1]
    prerelease_name = match.group("prerelease")
    post_number = match.group("post_hyphen") or match.group("post_number")
    dev_number = match.group("dev_number")

    if prerelease_name is not None:
        normalized_prerelease = {
            "a": "a",
            "alpha": "a",
            "b": "b",
            "beta": "b",
            "c": "rc",
            "pre": "rc",
            "preview": "rc",
            "rc": "rc",
        }[prerelease_name.lower()]
        prerelease = (
            {"a": 0, "b": 1, "rc": 2}[normalized_prerelease],
            int(match.group("prerelease_number") or 0),
        )
    else:
        prerelease = None

    post = None
    if match.group("post_hyphen") is not None:
        post = int(match.group("post_hyphen"))
    elif match.group("post_name") is not None:
        post = int(post_number or 0)

    dev = None
    if match.group("dev_name") is not None:
        dev = int(dev_number or 0)

    local_text = match.group("local")
    local = None
    if local_text is not None:
        local = tuple(
            (1, int(part)) if part.isdigit() else (0, part.lower())
            for part in re.split(r"[-_.]", local_text)
        )

    return ParsedVersion(
        epoch=int(match.group("epoch") or 0),
        release=release,
        prerelease=prerelease,
        post=post,
        dev=dev,
        local=local,
    )


def compare_versions(left: str, right: str) -> int:
    left_key = parse_version(left).key
    right_key = parse_version(right).key
    return (left_key > right_key) - (left_key < right_key)


def is_prerelease_of_upper_bound(detected: str, maximum: str) -> bool:
    detected_version = parse_version(detected)
    maximum_version = parse_version(maximum)
    same_release = (
        detected_version.epoch == maximum_version.epoch
        and detected_version.release == maximum_version.release
    )
    maximum_is_final = maximum_version.prerelease is None and maximum_version.dev is None
    detected_is_prerelease = (
        detected_version.prerelease is not None or detected_version.dev is not None
    )
    return same_release and maximum_is_final and detected_is_prerelease


def read_requirements(path: Path) -> tuple[list[Requirement], list[str]]:
    requirements: list[Requirement] = []
    invalid: list[str] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        match = REQUIREMENT_RE.fullmatch(line)
        if match is None:
            package_name = re.split(r"[<>=!~\s]", line, maxsplit=1)[0] or "unknown"
            invalid.append(package_name)
            continue
        try:
            parse_version(match.group("minimum"))
            parse_version(match.group("maximum"))
        except ValueError:
            invalid.append(match.group("name"))
            continue
        requirements.append(
            Requirement(
                name=match.group("name"),
                minimum=match.group("minimum"),
                maximum=match.group("maximum"),
            )
        )
    return requirements, invalid


def installed_versions(site_packages: Path | None) -> dict[str, str]:
    distributions: Iterable[metadata.Distribution]
    if site_packages is None:
        distributions = metadata.distributions()
    else:
        distributions = metadata.distributions(path=[str(site_packages)])

    result: dict[str, str] = {}
    for distribution in distributions:
        name = distribution.metadata.get("Name")
        if name:
            result[canonicalize_name(name)] = distribution.version
    return result


def verify(requirements_path: Path, site_packages: Path | None) -> int:
    requirements, invalid = read_requirements(requirements_path)
    if invalid:
        for name in invalid:
            print(
                f"{name} | required: unsupported | detected: not-checked | "
                "status: invalid-requirement"
            )
        return 2

    installed = installed_versions(site_packages)
    all_satisfied = True
    for requirement in requirements:
        detected = installed.get(canonicalize_name(requirement.name))
        if detected is None:
            status = "missing"
            detected_text = "not-installed"
            all_satisfied = False
        else:
            detected_text = detected
            try:
                in_bounds = (
                    compare_versions(detected, requirement.minimum) >= 0
                    and compare_versions(detected, requirement.maximum) < 0
                    and not is_prerelease_of_upper_bound(detected, requirement.maximum)
                )
            except ValueError:
                in_bounds = False
                status = "invalid-version"
            else:
                status = "satisfied" if in_bounds else "out-of-bounds"
            all_satisfied = all_satisfied and in_bounds
        print(
            f"{requirement.name} | required: {requirement.required} | "
            f"detected: {detected_text} | status: {status}"
        )
    return 0 if all_satisfied else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path)
    arguments = parser.parse_args()
    return verify(arguments.requirements, arguments.site_packages)


if __name__ == "__main__":
    raise SystemExit(main())