from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import ValidationError

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "evidence" / "evidence-schema.json"
TARGET_PATH = ROOT / "evidence" / "example-targets.json"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def validator() -> Draft202012Validator:
    schema = load_json(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


@pytest.fixture
def target() -> dict:
    return load_json(TARGET_PATH)


def assert_invalid(validator: Draft202012Validator, instance: dict) -> None:
    with pytest.raises(ValidationError):
        validator.validate(instance)


def test_target_example_is_valid_and_truthfully_unmeasured(
    validator: Draft202012Validator, target: dict
) -> None:
    validator.validate(target)
    assert target["evidenceClassification"] == "TARGET"
    assert target["status"] == "Planned"
    assert target["endUtc"] is None
    assert target["samples"] == []
    assert target["requestSamples"] == []
    assert target["measuredPeaks"] == {"baseline": None, "optimized": None}
    assert target["correctness"] is None
    assert target["outcome"] is None
    assert target["targetBands"] == {
        "baseline": {"minimum": 75, "maximum": 85},
        "optimized": {"minimum": 35, "maximum": 45},
    }
    assert "not an executed benchmark" in target["disclaimer"].lower()


def test_target_example_frozen_hashes_are_reproducible(target: dict) -> None:
    settings = target["frozenSettings"]
    assert json.loads(target["frozenSettingsJson"]) == settings
    assert hashlib.sha256(target["frozenSettingsJson"].encode()).hexdigest() == target[
        "frozenSettingsHash"
    ]
    schedule_json = json.dumps(settings["parameterSchedule"], separators=(",", ":"))
    assert hashlib.sha256(schedule_json.encode()).hexdigest() == settings[
        "parameterScheduleHash"
    ]


def test_target_rejects_measured_fields(
    validator: Draft202012Validator, target: dict
) -> None:
    mutated = copy.deepcopy(target)
    mutated["measuredPeaks"]["baseline"] = 80
    assert_invalid(validator, mutated)

    mutated = copy.deepcopy(target)
    mutated["samples"] = [
        {
            "sequence": 1,
            "timestampUtc": "2026-09-01T10:00:05.0000000Z",
            "phase": "Baseline",
            "grantedKb": 800,
            "totalKb": 1000,
            "grantUtilizationPercent": 80,
            "hostUsedPercent": 70,
            "hostAvailableMB": 12000,
            "processPhysicalLow": False,
            "processVirtualLow": False,
        }
    ]
    assert_invalid(validator, mutated)

    mutated = copy.deepcopy(target)
    mutated["outcome"] = "TargetMet"
    assert_invalid(validator, mutated)


def test_exact_target_bands_are_enforced(
    validator: Draft202012Validator, target: dict
) -> None:
    for phase, edge, value in (
        ("baseline", "minimum", 74),
        ("baseline", "maximum", 86),
        ("optimized", "minimum", 34),
        ("optimized", "maximum", 46),
    ):
        mutated = copy.deepcopy(target)
        mutated["targetBands"][phase][edge] = value
        assert_invalid(validator, mutated)


def test_unknown_properties_are_rejected_at_nested_boundaries(
    validator: Draft202012Validator, target: dict
) -> None:
    for path in (
        (),
        ("environment",),
        ("frozenSettings",),
        ("targetBands", "baseline"),
        ("measuredPeaks",),
    ):
        mutated = copy.deepcopy(target)
        cursor = mutated
        for segment in path:
            cursor = cursor[segment]
        cursor["unexpected"] = True
        assert_invalid(validator, mutated)


def test_bad_utc_and_outcome_values_are_rejected(
    validator: Draft202012Validator, target: dict
) -> None:
    for bad_timestamp in (
        "2026-09-01T10:00:00+02:00",
        "2026-09-01 10:00:00Z",
        "not-a-date",
    ):
        mutated = copy.deepcopy(target)
        mutated["startUtc"] = bad_timestamp
        assert_invalid(validator, mutated)

    mutated = copy.deepcopy(target)
    mutated["outcome"] = "Success"
    assert_invalid(validator, mutated)


def test_lab_measured_requires_samples_end_outcome_and_correctness(
    validator: Draft202012Validator, target: dict
) -> None:
    measured = copy.deepcopy(target)
    measured.update(
        {
            "evidenceClassification": "LAB-MEASURED",
            "disclaimer": "LAB-MEASURED evidence captured from the identified workshop environment.",
            "phase": "Comparison",
            "status": "Completed",
            "endUtc": "2026-09-01T10:01:00.0000000Z",
            "measuredPeaks": {"baseline": 80, "optimized": 40},
            "correctness": {
                "passed": True,
                "materialRegression": False,
                "additionalMetricImproved": True,
                "validationHash": "c" * 64,
            },
            "outcome": "TargetMet",
        }
    )
    assert_invalid(validator, measured)

    measured["samples"] = [
        {
            "sequence": 1,
            "timestampUtc": "2026-09-01T10:00:05.0000000Z",
            "phase": "Baseline",
            "grantedKb": 800,
            "totalKb": 1000,
            "grantUtilizationPercent": 80,
            "hostUsedPercent": 70,
            "hostAvailableMB": 12000,
            "processPhysicalLow": False,
            "processVirtualLow": False,
        }
    ]
    validator.validate(measured)

    measured["status"] = "SafetyStop"
    assert_invalid(validator, measured)


def test_metric_ranges_and_outcome_enum_are_enforced(
    validator: Draft202012Validator, target: dict
) -> None:
    measured = copy.deepcopy(target)
    measured.update(
        {
            "evidenceClassification": "LAB-MEASURED",
            "disclaimer": "LAB-MEASURED evidence captured from the identified workshop environment.",
            "phase": "Comparison",
            "status": "Completed",
            "endUtc": "2026-09-01T10:01:00.0000000Z",
            "samples": [
                {
                    "sequence": 1,
                    "timestampUtc": "2026-09-01T10:00:05.0000000Z",
                    "phase": "Baseline",
                    "grantedKb": 800,
                    "totalKb": 1000,
                    "grantUtilizationPercent": 101,
                    "hostUsedPercent": 70,
                    "hostAvailableMB": 12000,
                    "processPhysicalLow": False,
                    "processVirtualLow": False,
                }
            ],
            "measuredPeaks": {"baseline": 80, "optimized": 40},
            "correctness": {
                "passed": True,
                "materialRegression": False,
                "additionalMetricImproved": True,
                "validationHash": "c" * 64,
            },
            "outcome": "TargetMet",
        }
    )
    assert_invalid(validator, measured)

    measured["samples"][0]["grantUtilizationPercent"] = 80
    measured["outcome"] = "UnknownOutcome"
    assert_invalid(validator, measured)


def test_classification_phase_disclaimer_and_status_outcome_must_agree(
    validator: Draft202012Validator, target: dict
) -> None:
    mutated = copy.deepcopy(target)
    mutated["disclaimer"] = "LAB-MEASURED evidence captured from a workshop."
    assert_invalid(validator, mutated)

    mutated = copy.deepcopy(target)
    mutated["phase"] = "Optimized"
    assert_invalid(validator, mutated)
