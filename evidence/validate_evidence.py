"""Canonical structural and semantic validation for workshop evidence."""

from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
from fractions import Fraction
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError


_DOTNET_DECIMAL_MAX_COEFFICIENT = 79228162514264337593543950335


class EvidenceValidationError(ValueError):
    """Evidence failed validation without retaining document values in its message."""

    def __init__(self, issues: Sequence[str]) -> None:
        self.issues = tuple(issues)
        super().__init__(f"Evidence validation failed with {len(self.issues)} issue(s).")


def _path_text(path: Sequence[Any]) -> str:
    return "$" + "".join(
        f"[{part}]" if isinstance(part, int) else f".{part}" for part in path
    )


def _decimal(value: Any, path: str) -> Decimal:
    if isinstance(value, bool):
        raise EvidenceValidationError((f"{path} must be a finite number.",))
    try:
        result = value if isinstance(value, Decimal) else Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        raise EvidenceValidationError((f"{path} must be a finite number.",)) from None
    if not result.is_finite():
        raise EvidenceValidationError((f"{path} must be a finite number.",))
    parts = result.as_tuple()
    digits = list(parts.digits)
    exponent = parts.exponent
    while digits and digits[-1] == 0 and exponent < 0:
        digits.pop()
        exponent += 1
    coefficient = int("".join(str(digit) for digit in digits) or "0")
    if exponent >= 0:
        coefficient *= 10**exponent
    if -exponent > 28 or coefficient > _DOTNET_DECIMAL_MAX_COEFFICIENT:
        raise EvidenceValidationError(
            (f"{path} must be exactly representable as a .NET decimal value.",)
        )
    return result


def _as_fraction(value: Decimal) -> Fraction:
    parts = value.as_tuple()
    coefficient = int("".join(str(digit) for digit in parts.digits) or "0")
    if parts.sign:
        coefficient = -coefficient
    if parts.exponent >= 0:
        return Fraction(coefficient * 10**parts.exponent)
    return Fraction(coefficient, 10 ** (-parts.exponent))


def _grant_utilization(granted: Decimal, total: Decimal) -> Decimal:
    scaled = _as_fraction(granted) * 100_000_000 / _as_fraction(total)
    magnitude = abs(scaled.numerator)
    quotient, remainder = divmod(magnitude, scaled.denominator)
    if remainder * 2 >= scaled.denominator:
        quotient += 1
    if scaled.numerator < 0:
        quotient = -quotient
    return Decimal(quotient).scaleb(-6)


def _difference_at_least(left: Decimal, right: Decimal, threshold: int) -> bool:
    common_exponent = min(left.as_tuple().exponent, right.as_tuple().exponent, 0)

    def scaled_integer(value: Decimal) -> int:
        parts = value.as_tuple()
        coefficient = int("".join(str(digit) for digit in parts.digits) or "0")
        if parts.sign:
            coefficient = -coefficient
        return coefficient * 10 ** (parts.exponent - common_exponent)

    return (
        scaled_integer(left) - scaled_integer(right)
        >= threshold * 10 ** (-common_exponent)
    )


def _expected_outcome(document: Mapping[str, Any]) -> str:
    termination = document["terminationEvidence"]
    if termination["manualStopRequested"]:
        return "ManualStop"
    if termination["safetyStopTriggered"]:
        return "SafetyStop"

    peaks = document["measuredPeaks"]
    baseline_value = peaks["baseline"]
    optimized_value = peaks["optimized"]
    baseline = (
        None
        if baseline_value is None
        else _decimal(baseline_value, "$.measuredPeaks.baseline")
    )
    optimized = (
        None
        if optimized_value is None
        else _decimal(optimized_value, "$.measuredPeaks.optimized")
    )
    correctness = document["correctness"]

    if baseline is None or not Decimal(75) <= baseline <= Decimal(85):
        return "BaselineTargetNotReached"
    if not correctness["passed"] or optimized is None:
        return "Failed"
    if correctness["materialRegression"] or not correctness["additionalMetricImproved"]:
        return "NoMaterialImprovement"
    if Decimal(35) <= optimized <= Decimal(45):
        return "TargetMet"
    if _difference_at_least(baseline, optimized, 25):
        return "ImprovedOutsideTarget"
    return "NoMaterialImprovement"


def _validate_semantics(document: Mapping[str, Any]) -> list[str]:
    if document["evidenceClassification"] != "LAB-MEASURED":
        return []

    issues: list[str] = []
    phase_values: dict[str, list[Decimal]] = {"Baseline": [], "Optimized": []}
    for index, sample in enumerate(document["samples"]):
        reported = _decimal(
            sample["grantUtilizationPercent"],
            f"$.samples[{index}].grantUtilizationPercent",
        )
        granted = _decimal(sample["grantedKb"], f"$.samples[{index}].grantedKb")
        total = _decimal(sample["totalKb"], f"$.samples[{index}].totalKb")
        if granted > total or reported != _grant_utilization(granted, total):
            issues.append(
                f"$.samples[{index}].grantUtilizationPercent does not match the raw grant metrics."
            )
        phase_values[sample["phase"]].append(
            reported
        )

    for phase, peak_name in (("Baseline", "baseline"), ("Optimized", "optimized")):
        expected_peak = max(phase_values[phase]) if phase_values[phase] else None
        reported_value = document["measuredPeaks"][peak_name]
        reported_peak = (
            None
            if reported_value is None
            else _decimal(reported_value, f"$.measuredPeaks.{peak_name}")
        )
        if reported_peak != expected_peak:
            issues.append(
                f"$.measuredPeaks.{peak_name} must equal the exact maximum for its sample phase."
            )

    if document["outcome"] != _expected_outcome(document):
        issues.append("$.outcome does not match the measured evidence outcome rules.")
    return issues


def validate_evidence(document: Mapping[str, Any], schema: Mapping[str, Any]) -> None:
    """Validate schema structure first, then cross-field evidence semantics."""

    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError:
        raise EvidenceValidationError(("The evidence schema is invalid.",)) from None
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    try:
        structural_errors = sorted(
            validator.iter_errors(document), key=lambda error: tuple(error.absolute_path)
        )
    except (ArithmeticError, TypeError, ValueError):
        raise EvidenceValidationError(("Structural evidence validation failed.",)) from None
    if structural_errors:
        issues = tuple(
            f"Structural validation failed at {_path_text(tuple(error.absolute_path))}."
            for error in structural_errors
        )
        raise EvidenceValidationError(issues)

    semantic_issues = _validate_semantics(document)
    if semantic_issues:
        raise EvidenceValidationError(semantic_issues)


def _load_json(path: Path) -> Any:
    def reject_nonstandard_constant(_: str) -> None:
        raise ValueError("Non-standard numeric constants are not valid JSON.")

    with path.open(encoding="utf-8") as stream:
        return json.load(
            stream,
            parse_float=Decimal,
            parse_constant=reject_nonstandard_constant,
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path(__file__).with_name("evidence-schema.json"),
    )
    parser.add_argument("files", nargs="+", type=Path)
    arguments = parser.parse_args(argv)

    try:
        schema = _load_json(arguments.schema)
    except (OSError, ValueError):
        print("ERROR: evidence schema could not be loaded.")
        return 2

    failed = False
    for path in arguments.files:
        try:
            document = _load_json(path)
            validate_evidence(document, schema)
        except (OSError, ValueError):
            print(f"ERROR: {path}: evidence validation failed.")
            failed = True
        else:
            print(f"PASS: {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())