from __future__ import annotations

import argparse
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path
import re
from typing import Iterable


REQUIREMENT_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)"
    r">=(?P<minimum>\d+(?:\.\d+)*),<(?P<maximum>\d+(?:\.\d+)*)$"
)
VERSION_RE = re.compile(
    r"^v?(?P<release>\d+(?:\.\d+)*)"
    r"(?:(?P<prerelease>a|b|rc)(?P<prerelease_number>\d+))?"
    r"(?:\.post(?P<post>\d+))?(?:\.dev(?P<dev>\d+))?(?:\+[-A-Za-z0-9.]+)?$",
    re.IGNORECASE,
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


def canonicalize_name(name: str) -> str:
    return CANONICAL_NAME_RE.sub("-", name).lower()


def parse_version(
    value: str,
) -> tuple[tuple[int, ...], tuple[int, int], tuple[int, int], tuple[int, int]]:
    match = VERSION_RE.fullmatch(value)
    if match is None:
        raise ValueError(value)

    release = tuple(int(part) for part in match.group("release").split("."))
    prerelease_name = match.group("prerelease")
    post_number = match.group("post")
    dev_number = match.group("dev")

    if prerelease_name is not None:
        prerelease = (
            {"a": 0, "b": 1, "rc": 2}[prerelease_name.lower()],
            int(match.group("prerelease_number")),
        )
    elif dev_number is not None and post_number is None:
        prerelease = (-1, 0)
    else:
        prerelease = (3, 0)

    post = (-1, 0) if post_number is None else (0, int(post_number))
    dev = (1, 0) if dev_number is None else (0, int(dev_number))
    return release, prerelease, post, dev


def compare_versions(left: str, right: str) -> int:
    left_release, left_prerelease, left_post, left_dev = parse_version(left)
    right_release, right_prerelease, right_post, right_dev = parse_version(right)
    width = max(len(left_release), len(right_release))
    left_key = (
        left_release + (0,) * (width - len(left_release)),
        left_prerelease,
        left_post,
        left_dev,
    )
    right_key = (
        right_release + (0,) * (width - len(right_release)),
        right_prerelease,
        right_post,
        right_dev,
    )
    return (left_key > right_key) - (left_key < right_key)


def is_prerelease_of_upper_bound(detected: str, maximum: str) -> bool:
    detected_release, detected_prerelease, _, detected_dev = parse_version(detected)
    maximum_release, maximum_prerelease, _, _ = parse_version(maximum)
    width = max(len(detected_release), len(maximum_release))
    same_release = (
        detected_release + (0,) * (width - len(detected_release))
        == maximum_release + (0,) * (width - len(maximum_release))
    )
    maximum_is_final = maximum_prerelease == (3, 0)
    detected_is_prerelease = detected_prerelease != (3, 0) or detected_dev != (1, 0)
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