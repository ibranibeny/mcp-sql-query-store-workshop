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


def measured_sample(sequence: int, phase: str, utilization: int) -> dict:
    return {
        "sequence": sequence,
        "timestampUtc": f"2026-09-01T10:00:{sequence * 5:02d}.0000000Z",
        "phase": phase,
        "grantedKb": utilization * 10,
        "totalKb": 1000,
        "grantUtilizationPercent": utilization,
        "hostUsedPercent": 70,
        "hostAvailableMB": 12000,
        "processPhysicalLow": False,
        "processVirtualLow": False,
    }


def measured_evidence(target: dict, *, outcome: str = "TargetMet") -> dict:
    measured = copy.deepcopy(target)
    measured.update(
        evidenceClassification="LAB-MEASURED",
        disclaimer="LAB-MEASURED evidence captured from the identified workshop environment.",
        phase="Comparison",
        status="Completed",
        endUtc="2026-09-01T10:01:00.0000000Z",
        samples=[
            measured_sample(1, "Baseline", 80),
            measured_sample(2, "Optimized", 40),
        ],
        measuredPeaks={"baseline": 80, "optimized": 40},
        correctness={
            "passed": True,
            "materialRegression": False,
            "additionalMetricImproved": True,
            "validationHash": "c" * 64,
        },
        outcome=outcome,
    )
    return measured


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
    assert target["terminationEvidence"] == {
        "manualStopRequested": False,
        "safetyStopTriggered": False,
        "safetyReasons": [],
        "timeout": False,
    }
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
    assert_invalid(validator, measured)

    measured["samples"].append(measured_sample(2, "Optimized", 40))
    validator.validate(measured)

    measured["status"] = "SafetyStop"
    assert_invalid(validator, measured)


@pytest.mark.parametrize(
    "outcome", ["TargetMet", "ImprovedOutsideTarget", "NoMaterialImprovement"]
)
def test_completed_outcomes_require_both_sample_phases_and_nonnull_peaks(
    validator: Draft202012Validator, target: dict, outcome: str
) -> None:
    measured = measured_evidence(target, outcome=outcome)
    validator.validate(measured)

    for missing_phase, peak_name in (
        ("Baseline", "baseline"),
        ("Optimized", "optimized"),
    ):
        mutation = copy.deepcopy(measured)
        mutation["samples"] = [
            sample for sample in mutation["samples"] if sample["phase"] != missing_phase
        ]
        assert_invalid(validator, mutation)

        mutation = copy.deepcopy(measured)
        mutation["measuredPeaks"][peak_name] = None
        assert_invalid(validator, mutation)


def test_baseline_target_not_reached_forbids_optimized_claims(
    validator: Draft202012Validator, target: dict
) -> None:
    measured = measured_evidence(target)
    measured.update(
        phase="Baseline",
        status="BaselineTargetNotReached",
        samples=[measured_sample(1, "Baseline", 70)],
        measuredPeaks={"baseline": 70, "optimized": None},
        outcome="BaselineTargetNotReached",
    )
    validator.validate(measured)

    mutation = copy.deepcopy(measured)
    mutation["samples"].append(measured_sample(2, "Optimized", 40))
    assert_invalid(validator, mutation)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"]["optimized"] = 40
    assert_invalid(validator, mutation)

    mutation = copy.deepcopy(measured)
    mutation["samples"] = []
    assert_invalid(validator, mutation)


@pytest.mark.parametrize("outcome", ["SafetyStop", "ManualStop"])
@pytest.mark.parametrize("sample_phase", ["Baseline", "Optimized"])
def test_stop_outcomes_allow_either_phase_but_peaks_must_match_samples(
    validator: Draft202012Validator,
    target: dict,
    outcome: str,
    sample_phase: str,
) -> None:
    measured = measured_evidence(target)
    peak_name = sample_phase.lower()
    other_peak = "optimized" if peak_name == "baseline" else "baseline"
    measured.update(
        phase=sample_phase,
        status=outcome,
        samples=[measured_sample(1, sample_phase, 80 if sample_phase == "Baseline" else 40)],
        measuredPeaks={
            "baseline": 80 if sample_phase == "Baseline" else None,
            "optimized": 40 if sample_phase == "Optimized" else None,
        },
        terminationEvidence={
            "manualStopRequested": outcome == "ManualStop",
            "safetyStopTriggered": outcome == "SafetyStop",
            "safetyReasons": ["pressure"] if outcome == "SafetyStop" else [],
            "timeout": False,
        },
        outcome=outcome,
    )
    validator.validate(measured)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"][peak_name] = None
    assert_invalid(validator, mutation)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"][other_peak] = 50
    assert_invalid(validator, mutation)


def test_schema_requires_independent_consistent_termination_evidence(
    validator: Draft202012Validator, target: dict
) -> None:
    assert "terminationEvidence" in target

    contradictory = copy.deepcopy(target)
    contradictory["terminationEvidence"].update(
        manualStopRequested=True,
        safetyStopTriggered=True,
        safetyReasons=["pressure"],
    )
    assert_invalid(validator, contradictory)

    false_target_stop = copy.deepcopy(target)
    false_target_stop["terminationEvidence"]["manualStopRequested"] = True
    assert_invalid(validator, false_target_stop)

    safety = copy.deepcopy(target)
    safety.update(
        evidenceClassification="LAB-MEASURED",
        disclaimer="LAB-MEASURED evidence captured from the identified workshop environment.",
        phase="Baseline",
        status="SafetyStop",
        endUtc="2026-09-01T10:01:00.0000000Z",
        samples=[
            {
                "sequence": 1,
                "timestampUtc": "2026-09-01T10:00:05.0000000Z",
                "phase": "Baseline",
                "grantedKb": 800,
                "totalKb": 1000,
                "grantUtilizationPercent": 80,
                "hostUsedPercent": 88,
                "hostAvailableMB": 12000,
                "processPhysicalLow": False,
                "processVirtualLow": False,
            }
        ],
        measuredPeaks={"baseline": 80, "optimized": None},
        correctness={
            "passed": False,
            "materialRegression": False,
            "additionalMetricImproved": False,
            "validationHash": "c" * 64,
        },
        terminationEvidence={
            "manualStopRequested": False,
            "safetyStopTriggered": True,
            "safetyReasons": ["Host memory utilization exceeded 87.5 percent."],
            "timeout": False,
        },
        outcome="SafetyStop",
    )
    validator.validate(safety)

    safety["terminationEvidence"]["safetyStopTriggered"] = False
    assert_invalid(validator, safety)

    healthy_timeout = copy.deepcopy(safety)
    healthy_timeout["status"] = "Completed"
    healthy_timeout["outcome"] = "TargetMet"
    healthy_timeout["terminationEvidence"] = {
        "manualStopRequested": False,
        "safetyStopTriggered": False,
        "safetyReasons": [],
        "timeout": True,
    }
    assert_invalid(validator, healthy_timeout)


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
