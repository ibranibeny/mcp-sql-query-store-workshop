from __future__ import annotations

import copy
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import pytest
from jsonschema import Draft202012Validator, FormatChecker

from evidence.validate_evidence import EvidenceValidationError, validate_evidence

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = ROOT / "evidence" / "evidence-schema.json"
TARGET_PATH = ROOT / "evidence" / "example-targets.json"


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def schema() -> dict:
    schema = load_json(SCHEMA_PATH)
    Draft202012Validator.check_schema(schema)
    return schema


@pytest.fixture
def target() -> dict:
    return load_json(TARGET_PATH)


def assert_invalid(schema: dict, instance: dict) -> None:
    with pytest.raises(EvidenceValidationError):
        validate_evidence(instance, schema)


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
    optimized_utilization = {
        "TargetMet": 40,
        "ImprovedOutsideTarget": 51,
        "NoMaterialImprovement": 56,
    }[outcome]
    measured = copy.deepcopy(target)
    trials = [
        measured_trial(index + 1, index // 2 + 1, phase)
        for index, phase in enumerate(
            ("Baseline", "Optimized", "Optimized", "Baseline", "Optimized", "Baseline",
             "Baseline", "Optimized", "Baseline", "Optimized", "Optimized", "Baseline")
        )
    ]
    linkage = [
        {
            "sequence": trial["trialSequence"], "slot": trial["parameterSlot"],
            "phase": trial["phase"], "resultRowCount": trial["resultRowCount"],
            "resultHash": trial["resultHash"], "expectedRowCount": trial["expectedRowCount"],
            "actualRowCount": trial["actualRowCount"], "differenceCount": trial["differenceCount"],
            "correct": trial["correct"],
            "validationBatchId": trial["validationBatchId"],
        }
        for trial in trials
    ]
    validation_hash = hashlib.sha256(
        json.dumps(linkage, separators=(",", ":")).encode()
    ).hexdigest()
    measured.update(
        evidenceClassification="LAB-MEASURED",
        disclaimer="LAB-MEASURED evidence captured from the identified workshop environment.",
        phase="Comparison",
        status="Completed",
        endUtc="2026-09-01T10:01:00.0000000Z",
        samples=[
            measured_sample(1, "Baseline", 80),
            measured_sample(2, "Optimized", optimized_utilization),
        ],
        measuredPeaks={"baseline": 80, "optimized": optimized_utilization},
        correctness={
            "passed": True,
            "materialRegression": False,
            "additionalMetricImproved": True,
            "validationHash": validation_hash,
        },
        trials=trials,
        outcome=outcome,
    )
    return measured


def measured_trial(sequence: int, slot: int, phase: str) -> dict:
    optimized = phase == "Optimized"
    return {
        "trialSequence": sequence,
        "parameterSlot": slot,
        "phase": phase,
        "durationMs": 9 if optimized else 10,
        "cpuMs": 5,
        "logicalReads": 20,
        "grantedKB": 30,
        "usedKB": 25,
        "spillKB": 0,
        "waitMs": 1,
        "resultRowCount": 2,
        "resultHash": "ab" * 32,
        "expectedRowCount": 2,
        "actualRowCount": 2,
        "differenceCount": 0,
        "correct": True,
        "validationBatchId": "11111111-1111-1111-1111-111111111111",
        "startedAtUtc": "2026-09-01T10:00:00.0000000Z",
        "completedAtUtc": "2026-09-01T10:00:01.0000000Z",
    }


def set_validation_hash(document: dict) -> None:
    linkage = [
        {
            "sequence": trial["trialSequence"], "slot": trial["parameterSlot"],
            "phase": trial["phase"], "resultRowCount": trial["resultRowCount"],
            "resultHash": trial["resultHash"], "expectedRowCount": trial["expectedRowCount"],
            "actualRowCount": trial["actualRowCount"], "differenceCount": trial["differenceCount"],
            "correct": trial["correct"],
            "validationBatchId": trial["validationBatchId"],
        }
        for trial in document["trials"]
    ]
    document["correctness"]["validationHash"] = hashlib.sha256(
        json.dumps(linkage, separators=(",", ":")).encode()
    ).hexdigest()


def startup_failure_evidence(target: dict) -> dict:
    failed = copy.deepcopy(target)
    failed.update(
        evidenceClassification="LAB-MEASURED",
        disclaimer="LAB-MEASURED evidence captured from the identified workshop environment.",
        phase="Baseline",
        status="Failed",
        endUtc="2026-09-01T10:00:01.0000000Z",
        samples=[],
        requestSamples=[],
        trials=[],
        measuredPeaks={"baseline": None, "optimized": None},
        correctness=None,
        terminationEvidence={
            "manualStopRequested": False,
            "safetyStopTriggered": False,
            "safetyReasons": [],
            "timeout": False,
            "failure": {
                "code": "WORKSHOP_OPERATION_FAILED",
                "stage": "StartWorker",
                "message": "Operational failure details were redacted.",
                "startupFailure": True,
            },
        },
        outcome="Failed",
    )
    return failed


def test_measured_evidence_requires_exact_complete_paired_twelve_trials(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured["trials"] = [
        measured_trial(index + 1, index // 2 + 1, phase)
        for index, phase in enumerate(
            ("Baseline", "Optimized", "Optimized", "Baseline", "Optimized", "Baseline",
             "Baseline", "Optimized", "Baseline", "Optimized", "Optimized", "Baseline")
        )
    ]
    validate_evidence(measured, schema)

    for mutation in (
        measured["trials"][:-1],
        [dict(trial, correct=False, differenceCount=1) for trial in measured["trials"]],
    ):
        invalid = copy.deepcopy(measured)
        invalid["trials"] = mutation
        assert_invalid(schema, invalid)


def test_target_example_is_valid_and_truthfully_unmeasured(
    schema: dict, target: dict
) -> None:
    validate_evidence(target, schema)
    assert target["evidenceClassification"] == "TARGET"
    assert target["status"] == "Planned"
    assert target["endUtc"] is None
    assert target["samples"] == []
    assert target["requestSamples"] == []
    assert target["trials"] == []
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


def test_root_trials_property_is_required(schema: dict, target: dict) -> None:
    missing_trials = copy.deepcopy(target)
    missing_trials.pop("trials", None)

    assert_invalid(schema, missing_trials)


def test_target_example_frozen_hashes_are_reproducible(target: dict) -> None:
    settings = target["frozenSettings"]
    assert settings["validationBatchHash"] == "d" * 64
    expected_placeholders = {
        "dataHash": "TARGET-CONFIG-DATA-HASH-NOT-MEASURED",
        "indexStatisticsHash": "TARGET-CONFIG-INDEX-STATISTICS-HASH-NOT-MEASURED",
        "procedureHash": "TARGET-CONFIG-PROCEDURE-HASH-NOT-MEASURED",
    }
    for field, label in expected_placeholders.items():
        assert settings[field] == hashlib.sha256(label.encode()).hexdigest()
    assert json.loads(target["frozenSettingsJson"]) == settings
    assert hashlib.sha256(target["frozenSettingsJson"].encode()).hexdigest() == target[
        "frozenSettingsHash"
    ]
    schedule_json = json.dumps(settings["parameterSchedule"], separators=(",", ":"))
    assert hashlib.sha256(schedule_json.encode()).hexdigest() == settings[
        "parameterScheduleHash"
    ]


def test_canonical_validator_rejects_stale_frozen_fingerprints(
    schema: dict, target: dict
) -> None:
    for mutation in ("settings", "settingsJson", "settingsHash", "scheduleHash"):
        changed = copy.deepcopy(target)
        if mutation == "settings":
            changed["frozenSettings"]["workers"] = 3
        elif mutation == "settingsJson":
            changed["frozenSettingsJson"] = "{}"
        elif mutation == "settingsHash":
            changed["frozenSettingsHash"] = "0" * 64
        else:
            changed["frozenSettings"]["parameterScheduleHash"] = "0" * 64
        assert_invalid(schema, changed)


def test_frozen_settings_require_validation_batch_hash(schema: dict, target: dict) -> None:
    missing = copy.deepcopy(target)
    missing["frozenSettings"].pop("validationBatchHash", None)
    missing["frozenSettingsJson"] = json.dumps(
        missing["frozenSettings"], separators=(",", ":"), sort_keys=True
    )
    missing["frozenSettingsHash"] = hashlib.sha256(
        missing["frozenSettingsJson"].encode()
    ).hexdigest()

    assert_invalid(schema, missing)


@pytest.mark.parametrize(
    ("field", "value"),
    (
        ("dataHash", None),
        ("indexStatisticsHash", "A" * 64),
        ("procedureHash", "f" * 63),
    ),
)
def test_frozen_settings_require_valid_database_fingerprints(
    schema: dict, target: dict, field: str, value: str | None
) -> None:
    invalid = copy.deepcopy(target)
    if value is None:
        invalid["frozenSettings"].pop(field, None)
    else:
        invalid["frozenSettings"][field] = value
    invalid["frozenSettingsJson"] = json.dumps(
        invalid["frozenSettings"], separators=(",", ":"), sort_keys=True
    )
    invalid["frozenSettingsHash"] = hashlib.sha256(
        invalid["frozenSettingsJson"].encode()
    ).hexdigest()

    assert_invalid(schema, invalid)


@pytest.mark.parametrize("field", ("dataHash", "indexStatisticsHash", "procedureHash"))
def test_canonical_frozen_hash_changes_with_each_database_fingerprint(
    target: dict, field: str
) -> None:
    settings = copy.deepcopy(target["frozenSettings"])
    original = json.dumps(settings, separators=(",", ":"), sort_keys=True)
    settings[field] = "e" * 64
    changed = json.dumps(settings, separators=(",", ":"), sort_keys=True)

    assert hashlib.sha256(original.encode()).hexdigest() != hashlib.sha256(
        changed.encode()
    ).hexdigest()


def test_target_rejects_measured_fields(
    schema: dict, target: dict
) -> None:
    mutated = copy.deepcopy(target)
    mutated["measuredPeaks"]["baseline"] = 80
    assert_invalid(schema, mutated)

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
    assert_invalid(schema, mutated)

    mutated = copy.deepcopy(target)
    mutated["outcome"] = "TargetMet"
    assert_invalid(schema, mutated)


def test_exact_target_bands_are_enforced(
    schema: dict, target: dict
) -> None:
    for phase, edge, value in (
        ("baseline", "minimum", 74),
        ("baseline", "maximum", 86),
        ("optimized", "minimum", 34),
        ("optimized", "maximum", 46),
    ):
        mutated = copy.deepcopy(target)
        mutated["targetBands"][phase][edge] = value
        assert_invalid(schema, mutated)


def test_unknown_properties_are_rejected_at_nested_boundaries(
    schema: dict, target: dict
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
        assert_invalid(schema, mutated)


def test_bad_utc_and_outcome_values_are_rejected(
    schema: dict, target: dict
) -> None:
    for bad_timestamp in (
        "2026-09-01T10:00:00+02:00",
        "2026-09-01 10:00:00Z",
        "not-a-date",
    ):
        mutated = copy.deepcopy(target)
        mutated["startUtc"] = bad_timestamp
        assert_invalid(schema, mutated)

    mutated = copy.deepcopy(target)
    mutated["outcome"] = "Success"
    assert_invalid(schema, mutated)


def test_lab_measured_requires_samples_end_outcome_and_correctness(
    schema: dict, target: dict
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
    assert_invalid(schema, measured)

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
    assert_invalid(schema, measured)

    canonical = measured_evidence(target)
    measured["samples"].append(measured_sample(2, "Optimized", 40))
    measured["trials"] = canonical["trials"]
    measured["correctness"] = canonical["correctness"]
    validate_evidence(measured, schema)

    measured["status"] = "SafetyStop"
    assert_invalid(schema, measured)


@pytest.mark.parametrize(
    "outcome", ["TargetMet", "ImprovedOutsideTarget", "NoMaterialImprovement"]
)
def test_completed_outcomes_require_both_sample_phases_and_nonnull_peaks(
    schema: dict, target: dict, outcome: str
) -> None:
    measured = measured_evidence(target, outcome=outcome)
    validate_evidence(measured, schema)

    for missing_phase, peak_name in (
        ("Baseline", "baseline"),
        ("Optimized", "optimized"),
    ):
        mutation = copy.deepcopy(measured)
        mutation["samples"] = [
            sample for sample in mutation["samples"] if sample["phase"] != missing_phase
        ]
        assert_invalid(schema, mutation)

        mutation = copy.deepcopy(measured)
        mutation["measuredPeaks"][peak_name] = None
        assert_invalid(schema, mutation)


def test_baseline_target_not_reached_forbids_optimized_claims(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured.update(
        phase="Baseline",
        status="BaselineTargetNotReached",
        samples=[measured_sample(1, "Baseline", 70)],
        measuredPeaks={"baseline": 70, "optimized": None},
        outcome="BaselineTargetNotReached",
    )
    validate_evidence(measured, schema)

    mutation = copy.deepcopy(measured)
    mutation["samples"].append(measured_sample(2, "Optimized", 40))
    assert_invalid(schema, mutation)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"]["optimized"] = 40
    assert_invalid(schema, mutation)

    mutation = copy.deepcopy(measured)
    mutation["samples"] = []
    assert_invalid(schema, mutation)


@pytest.mark.parametrize("outcome", ["SafetyStop", "ManualStop"])
@pytest.mark.parametrize("sample_phase", ["Baseline", "Optimized"])
def test_stop_outcomes_allow_either_phase_but_peaks_must_match_samples(
    schema: dict,
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
    validate_evidence(measured, schema)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"][peak_name] = None
    assert_invalid(schema, mutation)

    mutation = copy.deepcopy(measured)
    mutation["measuredPeaks"][other_peak] = 50
    assert_invalid(schema, mutation)


def test_schema_requires_independent_consistent_termination_evidence(
    schema: dict, target: dict
) -> None:
    assert "terminationEvidence" in target

    contradictory = copy.deepcopy(target)
    contradictory["terminationEvidence"].update(
        manualStopRequested=True,
        safetyStopTriggered=True,
        safetyReasons=["pressure"],
    )
    assert_invalid(schema, contradictory)

    false_target_stop = copy.deepcopy(target)
    false_target_stop["terminationEvidence"]["manualStopRequested"] = True
    assert_invalid(schema, false_target_stop)

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
    set_validation_hash(safety)
    validate_evidence(safety, schema)

    safety["terminationEvidence"]["safetyStopTriggered"] = False
    assert_invalid(schema, safety)

    healthy_timeout = copy.deepcopy(safety)
    healthy_timeout["status"] = "Completed"
    healthy_timeout["outcome"] = "TargetMet"
    healthy_timeout["terminationEvidence"] = {
        "manualStopRequested": False,
        "safetyStopTriggered": False,
        "safetyReasons": [],
        "timeout": True,
    }
    assert_invalid(schema, healthy_timeout)


def test_metric_ranges_and_outcome_enum_are_enforced(
    schema: dict, target: dict
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
    assert_invalid(schema, measured)

    measured["samples"][0]["grantUtilizationPercent"] = 80
    measured["outcome"] = "UnknownOutcome"
    assert_invalid(schema, measured)


@pytest.mark.parametrize(
    "metric",
    (
        "durationMs", "cpuMs", "logicalReads", "grantedKB", "usedKB",
        "spillKB", "waitMs", "resultRowCount", "expectedRowCount",
        "actualRowCount", "differenceCount",
    ),
)
@pytest.mark.parametrize("invalid", (Decimal("9.999"), True, -1, 9223372036854775808))
def test_trial_metrics_require_nonnegative_int64_values(
    schema: dict, target: dict, metric: str, invalid: object
) -> None:
    measured = measured_evidence(target)
    measured["trials"][0][metric] = invalid

    assert_invalid(schema, measured)


@pytest.mark.parametrize(
    "invalid", (True, Decimal("65536.5"), 0, -1, 4294967297)
)
def test_environment_physical_memory_requires_sensible_positive_integer(
    schema: dict, target: dict, invalid: object
) -> None:
    target["environment"]["physicalMemoryMB"] = invalid
    assert_invalid(schema, target)


def test_pre_sample_failure_is_truthful_and_requires_failure_metadata(
    schema: dict, target: dict
) -> None:
    failed = startup_failure_evidence(target)
    validate_evidence(failed, schema)

    for mutation in ("failure", "startup", "samples", "correctness", "trials"):
        invalid = copy.deepcopy(failed)
        if mutation == "failure":
            invalid["terminationEvidence"].pop("failure")
        elif mutation == "startup":
            invalid["terminationEvidence"]["failure"]["startupFailure"] = False
        elif mutation == "samples":
            invalid["samples"] = [measured_sample(1, "Baseline", 80)]
        elif mutation == "correctness":
            invalid["correctness"] = {
                "passed": False,
                "materialRegression": False,
                "additionalMetricImproved": False,
                "validationHash": hashlib.sha256(b"[]").hexdigest(),
            }
        else:
            invalid["trials"] = [measured_trial(1, 1, "Baseline")]
        assert_invalid(schema, invalid)


def test_failure_metadata_rejects_secret_shaped_and_unbounded_messages(
    schema: dict, target: dict
) -> None:
    failed = startup_failure_evidence(target)
    failed["terminationEvidence"]["failure"]["message"] = "Password=canary"
    assert_invalid(schema, failed)

    failed = startup_failure_evidence(target)
    failed["terminationEvidence"]["failure"]["message"] = "x" * 513
    assert_invalid(schema, failed)


def test_classification_phase_disclaimer_and_status_outcome_must_agree(
    schema: dict, target: dict
) -> None:
    mutated = copy.deepcopy(target)
    mutated["disclaimer"] = "LAB-MEASURED evidence captured from a workshop."
    assert_invalid(schema, mutated)

    mutated = copy.deepcopy(target)
    mutated["phase"] = "Optimized"
    assert_invalid(schema, mutated)


def test_semantic_validation_rejects_structurally_valid_mismatched_peaks(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured["measuredPeaks"] = {"baseline": 1, "optimized": 99}

    Draft202012Validator(schema, format_checker=FormatChecker()).validate(measured)
    assert_invalid(schema, measured)


def test_semantic_validation_rejects_outcome_inconsistent_with_samples(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured["samples"][1] = measured_sample(2, "Optimized", 56)
    measured["measuredPeaks"]["optimized"] = 56

    assert_invalid(schema, measured)


def test_semantic_validation_derives_trial_flags_and_validation_hash(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)

    for field, value in (
        ("materialRegression", True),
        ("additionalMetricImproved", False),
        ("validationHash", "0" * 64),
    ):
        mutation = copy.deepcopy(measured)
        mutation["correctness"][field] = value
        assert_invalid(schema, mutation)


def test_outcome_delta_comparison_does_not_round_up_to_twenty_five(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target, outcome="ImprovedOutsideTarget")
    measured["samples"][1]["grantUtilizationPercent"] = Decimal(
        "55.000000000000000000000000001"
    )
    measured["samples"][1]["grantedKb"] = Decimal(
        "550.00000000000000000000000001"
    )
    measured["measuredPeaks"]["optimized"] = Decimal(
        "55.000000000000000000000000001"
    )

    assert_invalid(schema, measured)


def test_semantic_validation_rejects_values_not_exactly_representable_by_dotnet_decimal(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    overprecise = Decimal("80.000000000000000000000000001")
    measured["samples"][0]["grantUtilizationPercent"] = overprecise
    measured["measuredPeaks"]["baseline"] = overprecise

    assert_invalid(schema, measured)


def test_semantic_validation_rejects_utilization_inconsistent_with_raw_grant(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured["samples"][0]["grantedKb"] = 700

    assert_invalid(schema, measured)


def test_partial_failed_trial_accepts_equal_instants_with_different_fractional_precision(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured.update(status="Failed", outcome="Failed")
    measured["correctness"]["passed"] = False
    measured["trials"] = [measured["trials"][0]]
    measured["trials"][0]["startedAtUtc"] = "2026-09-01T10:00:00.1Z"
    measured["trials"][0]["completedAtUtc"] = "2026-09-01T10:00:00.10Z"
    measured["correctness"]["additionalMetricImproved"] = False
    set_validation_hash(measured)

    validate_evidence(measured, schema)


def test_partial_failed_trial_accepts_whole_second_utc_instants(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured.update(status="Failed", outcome="Failed")
    measured["correctness"]["passed"] = False
    measured["trials"] = [measured["trials"][0]]
    measured["trials"][0]["startedAtUtc"] = "2026-09-01T10:00:00Z"
    measured["trials"][0]["completedAtUtc"] = "2026-09-01T10:00:01Z"
    measured["correctness"]["additionalMetricImproved"] = False
    set_validation_hash(measured)

    validate_evidence(measured, schema)


def test_partial_failed_trial_rejects_reversed_fractional_timestamp_interval(
    schema: dict, target: dict
) -> None:
    measured = measured_evidence(target)
    measured.update(status="Failed", outcome="Failed")
    measured["correctness"]["passed"] = False
    measured["trials"] = [measured["trials"][0]]
    measured["trials"][0]["startedAtUtc"] = "2026-09-01T10:00:00.1000001Z"
    measured["trials"][0]["completedAtUtc"] = "2026-09-01T10:00:00.1000000Z"
    measured["correctness"]["additionalMetricImproved"] = False
    set_validation_hash(measured)

    assert_invalid(schema, measured)


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity"])
def test_cli_rejects_nonstandard_nonfinite_json_numbers_without_echoing_them(
    target: dict, tmp_path: Path, constant: str
) -> None:
    evidence_path = tmp_path / "nonfinite.json"
    text = json.dumps(target).replace('"hostAvailableMB": 12000', f'"hostAvailableMB": {constant}')
    if text == json.dumps(target):
        measured = measured_evidence(target)
        measured["requestSamples"] = [
            {
                "sampleSequence": 1,
                "sessionId": 51,
                "requestId": 0,
                "requestedMemoryKB": 1,
                "grantedMemoryKB": 1,
                "requiredMemoryKB": 1,
                "idealMemoryKB": 1,
                "usedMemoryKB": 1,
                "maxUsedMemoryKB": 1,
                "waitOrder": None,
                "waitTimeMs": 1,
                "queryId": None,
                "planId": None,
            }
        ]
        text = json.dumps(measured).replace('"waitMs": 1', f'"waitMs": {constant}')
    evidence_path.write_text(text, encoding="utf-8")

    result = subprocess.run(
        [sys.executable, str(ROOT / "evidence" / "validate_evidence.py"), str(evidence_path)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert constant not in result.stdout + result.stderr


def test_cli_sanitizes_invalid_schema_errors(tmp_path: Path) -> None:
    canary = "private-schema-canary"
    schema_path = tmp_path / "invalid-schema.json"
    schema_path.write_text(
        json.dumps({"type": canary}),
        encoding="utf-8",
    )
    evidence_path = tmp_path / "evidence.json"
    evidence_path.write_text("{}", encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "evidence" / "validate_evidence.py"),
            "--schema",
            str(schema_path),
            str(evidence_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert canary not in result.stdout + result.stderr
    assert "Traceback" not in result.stdout + result.stderr


def test_cli_failure_is_nonzero_and_does_not_echo_document_values(
    schema: dict, target: dict, tmp_path: Path
) -> None:
    measured = measured_evidence(target)
    canary = "private-canary-value"
    measured["environment"]["sqlVersion"] = canary
    measured["measuredPeaks"]["baseline"] = 1
    evidence_path = tmp_path / "invalid-evidence.json"
    evidence_path.write_text(json.dumps(measured), encoding="utf-8")

    result = subprocess.run(
        [
            sys.executable,
            str(ROOT / "evidence" / "validate_evidence.py"),
            "--schema",
            str(SCHEMA_PATH),
            str(evidence_path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode != 0
    assert canary not in result.stdout + result.stderr
