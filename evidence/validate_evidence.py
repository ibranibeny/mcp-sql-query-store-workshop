"""Canonical structural and semantic validation for workshop evidence."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from fractions import Fraction
import hashlib
import json
from pathlib import Path
from typing import Any, Mapping, Sequence

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError


_DOTNET_DECIMAL_MAX_COEFFICIENT = 79228162514264337593543950335
_UTC_INSTANT_FORMAT = "%Y-%m-%dT%H:%M:%S"
_UTC_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)


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


def _utc_ticks(value: str, path: str) -> int:
    """Parse a schema-valid RFC3339 UTC instant into exact 100 ns ticks."""

    timestamp, separator, suffix = value.partition(".")
    fraction = suffix[:-1] if separator else ""
    if not separator:
        timestamp = timestamp[:-1]
    try:
        parsed = datetime.strptime(timestamp, _UTC_INSTANT_FORMAT).replace(
            tzinfo=timezone.utc
        )
    except (TypeError, ValueError):
        raise EvidenceValidationError((f"{path} must be an RFC3339 UTC instant.",)) from None
    seconds = int((parsed - _UTC_EPOCH).total_seconds())
    ticks = int(fraction.ljust(7, "0")) if fraction else 0
    return seconds * 10_000_000 + ticks


def _expected_outcome(document: Mapping[str, Any]) -> str:
    termination = document["terminationEvidence"]
    if termination["manualStopRequested"]:
        return "ManualStop"
    if termination["safetyStopTriggered"]:
        return "SafetyStop"
    if document["status"] == "Failed":
        return "Failed"

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


def _trial_assessment(trials: Sequence[Mapping[str, Any]]) -> tuple[bool, bool]:
    baseline = [trial for trial in trials if trial["phase"] == "Baseline"]
    optimized = [trial for trial in trials if trial["phase"] == "Optimized"]
    material_regression = False
    additional_improvement = False
    for metric in ("durationMs", "cpuMs", "logicalReads", "spillKB", "waitMs"):
        baseline_average = sum(
            (_decimal(trial[metric], f"$.trials.{metric}") for trial in baseline),
            Decimal(0),
        ) / len(baseline)
        optimized_average = sum(
            (_decimal(trial[metric], f"$.trials.{metric}") for trial in optimized),
            Decimal(0),
        ) / len(optimized)
        if baseline_average > 0 and optimized_average <= baseline_average * Decimal("0.90"):
            additional_improvement = True
        if (baseline_average == 0 and optimized_average > 0) or (
            baseline_average > 0
            and optimized_average > baseline_average * Decimal("1.10")
        ):
            material_regression = True
    return material_regression, additional_improvement


def _validation_hash(trials: Sequence[Mapping[str, Any]]) -> str:
    linkage = [
        {
            "sequence": trial["trialSequence"],
            "slot": trial["parameterSlot"],
            "phase": trial["phase"],
            "resultRowCount": trial["resultRowCount"],
            "resultHash": trial["resultHash"].lower(),
            "expectedRowCount": trial["expectedRowCount"],
            "actualRowCount": trial["actualRowCount"],
            "differenceCount": trial["differenceCount"],
            "correct": trial["correct"],
            "validationBatchId": trial["validationBatchId"],
        }
        for trial in trials
    ]
    canonical = json.dumps(linkage, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _validate_semantics(document: Mapping[str, Any]) -> list[str]:
    issues: list[str] = []
    settings = document["frozenSettings"]
    canonical_settings = json.dumps(
        settings, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    )
    try:
        serialized_settings = json.loads(document["frozenSettingsJson"])
    except (json.JSONDecodeError, TypeError):
        serialized_settings = None
    if serialized_settings != settings or document["frozenSettingsJson"] != canonical_settings:
        issues.append("$.frozenSettingsJson must be the canonical frozenSettings serialization.")
    if document["frozenSettingsHash"] != hashlib.sha256(
        canonical_settings.encode("utf-8")
    ).hexdigest():
        issues.append("$.frozenSettingsHash must match the canonical frozen settings.")
    schedule_json = json.dumps(
        settings["parameterSchedule"], ensure_ascii=False, separators=(",", ":")
    )
    if settings["parameterScheduleHash"] != hashlib.sha256(
        schedule_json.encode("utf-8")
    ).hexdigest():
        issues.append("$.frozenSettings.parameterScheduleHash must match the schedule.")
    if document["evidenceClassification"] != "LAB-MEASURED":
        return issues

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

    trials = document.get("trials", [])
    completed_comparison = (
        document["phase"] == "Comparison" and document["status"] == "Completed"
    )
    if completed_comparison and len(trials) != 12:
        issues.append("$.trials must contain exactly twelve completed comparison trials.")
    for index, trial in enumerate(trials):
        started = _utc_ticks(trial["startedAtUtc"], f"$.trials[{index}].startedAtUtc")
        completed = _utc_ticks(
            trial["completedAtUtc"], f"$.trials[{index}].completedAtUtc"
        )
        if completed < started:
            issues.append(f"$.trials[{index}] has an invalid timestamp interval.")
    if document["correctness"]["validationHash"] != _validation_hash(trials):
        issues.append("$.correctness.validationHash must match canonical trial linkage.")
    if len(trials) != 12:
        if document["correctness"]["passed"]:
            issues.append("$.correctness.passed must be false for an incomplete comparison.")
        if document["correctness"]["materialRegression"]:
            issues.append("$.correctness.materialRegression must be false for an incomplete comparison.")
        if document["correctness"]["additionalMetricImproved"]:
            issues.append("$.correctness.additionalMetricImproved must be false for an incomplete comparison.")
    if len(trials) == 12:
        trial_linkage_valid = True
        expected_phases = (
            "Baseline", "Optimized", "Optimized", "Baseline",
            "Optimized", "Baseline", "Baseline", "Optimized",
            "Baseline", "Optimized", "Optimized", "Baseline",
        )
        batch_ids = {trial["validationBatchId"] for trial in trials}
        if len(batch_ids) != 1:
            issues.append("$.trials must use one validation batch identifier.")
            trial_linkage_valid = False
        for index, trial in enumerate(trials):
            if trial["trialSequence"] != index + 1:
                issues.append("$.trials trialSequence values must be contiguous from one through twelve.")
                trial_linkage_valid = False
                break
            if trial["parameterSlot"] != index // 2 + 1:
                issues.append("$.trials parameterSlot values must form six adjacent A/B pairs.")
                trial_linkage_valid = False
                break
            if trial["phase"] != expected_phases[index]:
                issues.append("$.trials phase order must be ABBA BAAB ABBA.")
                trial_linkage_valid = False
                break
        for slot in range(1, 7):
            pair = [trial for trial in trials if trial["parameterSlot"] == slot]
            baseline = [trial for trial in pair if trial["phase"] == "Baseline"]
            optimized = [trial for trial in pair if trial["phase"] == "Optimized"]
            if len(pair) != 2 or len(baseline) != 1 or len(optimized) != 1:
                issues.append(f"$.trials parameter slot {slot} must contain one A and one B trial.")
                trial_linkage_valid = False
                continue
            expected_count = baseline[0]["resultRowCount"]
            actual_count = optimized[0]["resultRowCount"]
            correct = (
                expected_count == actual_count
                and baseline[0]["resultHash"] == optimized[0]["resultHash"]
            )
            for trial in pair:
                if (
                    trial["expectedRowCount"] != expected_count
                    or trial["actualRowCount"] != actual_count
                    or trial["expectedRowCount"] != trial["actualRowCount"]
                    or trial["differenceCount"] != 0
                    or not trial["correct"]
                ):
                    correct = False
            if not correct:
                trial_linkage_valid = False
                issues.append(f"$.trials parameter slot {slot} correctness linkage is invalid.")
        all_trials_correct = trial_linkage_valid and all(trial["correct"] for trial in trials)
        if document["correctness"]["passed"] is not all_trials_correct:
            issues.append("$.correctness.passed must equal aggregate trial correctness.")
        material_regression, additional_improvement = _trial_assessment(trials)
        if document["correctness"]["materialRegression"] is not material_regression:
            issues.append("$.correctness.materialRegression must be derived from trial metrics.")
        if document["correctness"]["additionalMetricImproved"] is not additional_improvement:
            issues.append("$.correctness.additionalMetricImproved must be derived from trial metrics.")

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