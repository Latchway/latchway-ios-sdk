#!/usr/bin/env python3

from __future__ import annotations

import copy
import datetime as dt
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name("device-evidence.py")
SCHEMA_PATH = SCRIPT.parent.parent / "Conformance" / "physical-device-evidence.schema.json"
SPEC = importlib.util.spec_from_file_location("device_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
device_evidence = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(device_evidence)


BASE_NOW = dt.datetime.now(dt.timezone.utc)


def now(offset_seconds: int = 0) -> str:
    value = BASE_NOW + dt.timedelta(seconds=offset_seconds)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def profile() -> dict:
    expected = {
        "application_identifier": "dev.latchway.conformance",
        "latchway_application_id": "app_00000000000000000000000000",
        "latchway_environment": "production",
        "identity_provider": "firebase",
        "app_version": "1.0.0",
        "build_number": "42",
        "team_id": "A1B2C3D4E5",
        "signing_certificate_sha256": "1" * 64,
        "app_attest_environment": "production",
        "source_commit": "2" * 40,
        "core_commit": "7" * 40,
        "contract_bundle_sha256": "3" * 64,
        "gateway_image_digest": "sha256:" + "4" * 64,
        "gateway_configuration_sha256": "5" * 64,
        "gateway_origin": "https://gateway.example.com",
        "gateway_environment": "production",
        "gateway_deployment_key_id": "gateway-key-1",
        "gateway_deployment_statement_sha256": "a" * 64,
        "gateway_deployment_public_key_sha256": "c" * 64,
        "error_mapping_feature": "missing_feature",
        "host_bundle_identifier": "dev.latchway.conformance",
        "widget_bundle_identifier": "dev.latchway.conformance.widget",
        "share_bundle_identifier": "dev.latchway.conformance.share",
        "action_bundle_identifier": "dev.latchway.conformance.action",
        "host_definition_id": "host_app",
        "widget_definition_id": "home_widget",
        "share_definition_id": "share_sheet",
        "action_definition_id": "background_action",
        "host_binary_sha256": "6" * 64,
        "widget_binary_sha256": "9" * 64,
        "share_binary_sha256": "a" * 64,
        "action_binary_sha256": "b" * 64,
    }
    return {
        "schema_version": device_evidence.PROFILE_VERSION,
        "platform": "ios_app_attest",
        "repository": "Latchway/latchway-ios-sdk",
        "source": {
            "commit": expected["source_commit"],
            "core_commit": expected["core_commit"],
            "worktree_clean": True,
            "sdk_version": "0.1.0",
            "contract_version": "1.0.0",
            "contract_bundle_sha256": expected["contract_bundle_sha256"],
            "gateway_image_digest": expected["gateway_image_digest"],
            "gateway_configuration_sha256": expected["gateway_configuration_sha256"],
            "gateway_origin": expected["gateway_origin"],
            "gateway_deployment_key_id": expected["gateway_deployment_key_id"],
            "gateway_deployment_statement_sha256": expected["gateway_deployment_statement_sha256"],
            "gateway_deployment_public_key_sha256": expected["gateway_deployment_public_key_sha256"],
        },
        "toolchain": {
            "runner_os": "macOS 26.0",
            "runner_arch": "arm64",
            "compiler": "Apple Swift 6.2",
            "build_tool": "Xcode 26.0",
            "collector_version": "2",
        },
        "expected_pins": expected,
        "application_binary_sha256": "6" * 64,
        "application_bundle_tree_sha256": "d" * 64,
        "device_inventory_sha256": "8" * 64,
    }


def observation() -> dict:
    expected = profile()["expected_pins"]
    tests = []
    for name in sorted(
        device_evidence.PLATFORM_POLICY["ios_app_attest"]["tests"]
        - device_evidence.IOS_COMPONENT_TESTS
    ):
        entry = {"id": name, "status": "passed", "duration_ms": 1}
        if name == "dpop_replay_rejected":
            entry.update(http_status=401, error_code="dpop_replayed", request_id="request-replay-1234")
        elif name == "tampered_dpop_rejected":
            entry.update(http_status=401, error_code="dpop_invalid", request_id="request-tamper-1234")
        elif name == "canonical_error_mapping":
            entry.update(http_status=404, error_code="feature_not_found", request_id="request-mapping-1234", mapped_error_type="swift_latchway_problem")
        elif name == "installation_revocation":
            entry.update(http_status=403, error_code="installation_revoked", request_id="request-revoked-1234")
        elif name == "protocol_version_rejection":
            entry.update(http_status=426, error_code="protocol_version_unsupported", request_id="request-protocol-1234", protocol_version_sent=0)
        elif name == "session_refresh_rotation":
            entry.update(
                credential_before_sha256="a" * 64,
                credential_after_sha256="b" * 64,
                installation_before_sha256="c" * 64,
                installation_after_sha256="c" * 64,
            )
        tests.append(entry)
    return {
        "schema_version": device_evidence.OBSERVATION_VERSION,
        "platform": "ios_app_attest",
        "run": {
            "id": "test-run-12345678",
            "mode": "release",
            "started_at": now(-2),
            "completed_at": now(-1),
        },
        "gateway_version": "1.0.0",
        "application": {
            "identifier": expected["application_identifier"],
            "version": expected["app_version"],
            "build": expected["build_number"],
            "build_mode": "release",
            "distribution": "ad_hoc",
            "debuggable": False,
            "signing_certificate_sha256": expected["signing_certificate_sha256"],
            "team_id": expected["team_id"],
            "app_attest_environment": "production",
        },
        "device": {
            "physical": True,
            "simulator": False,
            "emulator": False,
            "testing": False,
            "debugger_attached": False,
            "model": "iPhone17,1",
            "os_name": "iOS",
            "os_version": "26.0",
            "os_build": "23A123",
            "security_level": "secure_enclave",
        },
        "provider": {
            "name": "app_attest",
            "environment": "production",
            "trust_level": "app_verified",
            "request_hash_bound": True,
            "app_recognition": "not_applicable",
            "account_licensing": "not_applicable",
        },
        "observed_pins": {
            name: value
            for name, value in expected.items()
            if name not in {
                "host_bundle_identifier", "widget_bundle_identifier",
                "share_bundle_identifier", "action_bundle_identifier",
                "host_definition_id", "widget_definition_id",
                "share_definition_id", "action_definition_id",
                "host_binary_sha256", "widget_binary_sha256",
                "share_binary_sha256", "action_binary_sha256",
            }
        },
        "tests": tests,
        "redaction": {
            "identity_token_recorded": False,
            "session_token_recorded": False,
            "refresh_token_recorded": False,
            "dpop_proof_recorded": False,
            "attestation_evidence_recorded": False,
            "private_key_recorded": False,
            "provider_credential_recorded": False,
        },
    }


def component_observation() -> dict:
    expected = profile()["expected_pins"]
    identity_values = {
        "host": ("main_app", "c", "0", "4"),
        "widget": ("widget", "d", "1", "5"),
        "share": ("share_extension", "e", "2", "6"),
        "action": ("action_extension", "f", "3", "7"),
    }
    identities = []
    for role, (kind, principal, key, session) in identity_values.items():
        identities.append({
            "role": role,
            "kind": kind,
            "definition_id": expected[f"{role}_definition_id"],
            "bundle_identifier": expected[f"{role}_bundle_identifier"],
            "binary_sha256": expected[f"{role}_binary_sha256"],
            "attestation_mode": "root_app_attest" if role == "host" else "delegated_only",
            "principal_id_sha256": principal * 64,
            "dpop_key_id_sha256": key * 64,
            "session_id_sha256": session * 64,
        })
    tests = [
        {"id": name, "status": "passed", "duration_ms": 1}
        for name in sorted(device_evidence.IOS_COMPONENT_TESTS)
    ]
    for role in ("widget", "share", "action"):
        delegated = next(
            item for item in tests if item["id"] == f"{role}_delegated_request"
        )
        delegated.update(
            http_status=200,
            request_id=f"request-{role}-1234",
        )
    denial = next(item for item in tests if item["id"] == "component_sibling_denied")
    denial.update(
        http_status=401,
        error_code="component_key_invalid",
        request_id="request-sibling-1234",
    )
    keychain_denial = next(
        item for item in tests if item["id"] == "component_keychain_sibling_denied"
    )
    keychain_denial.update(
        os_status=-34018,
        os_status_name="errSecMissingEntitlement",
    )
    refresh_race = next(
        item for item in tests if item["id"] == "component_refresh_race"
    )
    refresh_race.update(
        concurrent_request_count=2,
        credential_before_sha256="8" * 64,
        credential_after_sha256="a" * 64,
    )
    return {
        "schema_version": device_evidence.IOS_COMPONENT_OBSERVATION_VERSION,
        "platform": "ios_app_attest",
        "run_id": "test-run-12345678",
        "started_at": now(-2),
        "completed_at": now(-1),
        "runtime": {
            "identities": identities,
            "widget_delegated_execution": {
                "role": "widget",
                "definition_id": expected["widget_definition_id"],
                "component_id_sha256": "d" * 64,
                "dpop_key_id_sha256": "1" * 64,
                "session_id_sha256": "5" * 64,
                "trust_source": "delegated_from_attested_root",
                "http_status": 200,
                "request_id": "request-widget-1234",
            },
            "share_delegated_execution": {
                "role": "share",
                "definition_id": expected["share_definition_id"],
                "component_id_sha256": "e" * 64,
                "dpop_key_id_sha256": "2" * 64,
                "session_id_sha256": "6" * 64,
                "trust_source": "delegated_from_attested_root",
                "http_status": 200,
                "request_id": "request-share-1234",
            },
            "delegated_execution": {
                "role": "action",
                "definition_id": expected["action_definition_id"],
                "component_id_sha256": "f" * 64,
                "dpop_key_id_sha256": "3" * 64,
                "session_id_sha256": "7" * 64,
                "trust_source": "delegated_from_attested_root",
                "http_status": 200,
                "request_id": "request-action-1234",
            },
            "sibling_denial": {
                "requesting_role": "action",
                "credential_role": "share",
                "credential_session_id_sha256": "6" * 64,
                "http_status": 401,
                "error_code": "component_key_invalid",
                "request_id": "request-sibling-1234",
            },
            "keychain_sibling_denial": {
                "requesting_role": "action",
                "target_role": "share",
                "target_key_id_sha256": "2" * 64,
                "operation": "SecItemCopyMatching",
                "os_status": -34018,
                "os_status_name": "errSecMissingEntitlement",
                "key_material_returned": False,
            },
            "component_refresh_race": {
                "role": "action",
                "component_id_sha256": "f" * 64,
                "dpop_key_id_sha256": "3" * 64,
                "session_id_before_sha256": "8" * 64,
                "old_credential_sha256": "8" * 64,
                "requests_started_concurrently": True,
                "overlap_observed": True,
                "requests": [
                    {
                        "request_id": "request-refresh-race-a",
                        "http_status": 200,
                        "access_credential_sha256": "9" * 64,
                        "refresh_credential_sha256": "a" * 64,
                        "session_id_sha256": "7" * 64,
                    },
                    {
                        "request_id": "request-refresh-race-b",
                        "http_status": 200,
                        "access_credential_sha256": "9" * 64,
                        "refresh_credential_sha256": "a" * 64,
                        "session_id_sha256": "7" * 64,
                    },
                ],
                "session_id_after_sha256": "7" * 64,
                "results_identical": True,
            },
            "lifecycle": {
                "host_process_running_during_action_request": False,
                "background_execution_observed": True,
                "host_termination_observed": True,
                "user_presence_prompt_observed": False,
            },
        },
        "tests": tests,
    }


class DeviceEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def evidence(self) -> tuple[dict, dict]:
        current_profile = profile()
        result = device_evidence.build_evidence(
            observation(), current_profile, self.schema, component_observation()
        )
        return result, current_profile

    def test_valid_release_evidence_passes(self) -> None:
        evidence, current_profile = self.evidence()
        self.assertTrue(evidence["release_eligible"])
        self.assertEqual(
            evidence["artifacts"]["application_bundle_tree_sha256"], "d" * 64
        )
        self.assertEqual(device_evidence.verify(
            evidence, current_profile, self.schema, component_observation()
        ), [])

    def test_ios_bundle_tree_hash_is_required_and_bound_to_final_evidence(self) -> None:
        missing_profile = profile()
        del missing_profile["application_bundle_tree_sha256"]
        self.assertIn(
            "profile: missing properties: application_bundle_tree_sha256",
            device_evidence.validate_profile(missing_profile),
        )

        invalid_profile = profile()
        invalid_profile["application_bundle_tree_sha256"] = "E" * 64
        self.assertIn(
            "profile.application_bundle_tree_sha256: expected lowercase SHA-256",
            device_evidence.validate_profile(invalid_profile),
        )

        evidence, current_profile = self.evidence()
        del evidence["artifacts"]["application_bundle_tree_sha256"]
        self.assertIn(
            "whole application bundle tree is not bound to the protected profile",
            device_evidence.verify(
                evidence, current_profile, self.schema, component_observation()
            ),
        )

        evidence, current_profile = self.evidence()
        evidence["artifacts"]["application_bundle_tree_sha256"] = "e" * 64
        self.assertIn(
            "whole application bundle tree is not bound to the protected profile",
            device_evidence.verify(
                evidence, current_profile, self.schema, component_observation()
            ),
        )

    def test_json_loader_rejects_ambiguous_nonfinite_and_symlinked_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            duplicate = root / "duplicate.json"
            nonfinite = root / "nonfinite.json"
            target = root / "target.json"
            link = root / "link.json"
            duplicate.write_text('{"platform":"ios","platform":"android"}', encoding="utf-8")
            nonfinite.write_text('{"duration_ms":NaN}', encoding="utf-8")
            target.write_text('{"valid":true}', encoding="utf-8")
            link.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "duplicate JSON object member"):
                device_evidence.load_json(duplicate)
            with self.assertRaisesRegex(ValueError, "non-finite JSON number"):
                device_evidence.load_json(nonfinite)
            with self.assertRaisesRegex(ValueError, "missing JSON file"):
                device_evidence.load_json(link)

    def test_schema_rejects_unexpected_field(self) -> None:
        evidence, _ = self.evidence()
        evidence["raw_evidence"] = "forbidden"
        self.assertTrue(device_evidence.schema_errors(evidence, self.schema))

    def test_simulator_and_debug_build_fail_closed(self) -> None:
        current = observation()
        current["device"]["physical"] = False
        current["device"]["simulator"] = True
        current["application"]["debuggable"] = True
        result = device_evidence.build_evidence(
            current, profile(), self.schema, component_observation()
        )
        self.assertFalse(result["release_eligible"])

    def test_development_attestation_fails_closed(self) -> None:
        current = observation()
        current["application"]["app_attest_environment"] = "development"
        current["provider"]["environment"] = "development"
        result = device_evidence.build_evidence(
            current, profile(), self.schema, component_observation()
        )
        self.assertFalse(result["release_eligible"])

    def test_app_attest_requires_exact_app_verified_trust(self) -> None:
        current = observation()
        current["provider"]["trust_level"] = "strong_device_verified"
        result = device_evidence.build_evidence(
            current, profile(), self.schema, component_observation()
        )
        self.assertFalse(result["release_eligible"])

    def test_pin_mismatch_fails_closed(self) -> None:
        current = observation()
        current["observed_pins"]["team_id"] = "ZZZZZZZZZZ"
        result = device_evidence.build_evidence(
            current, profile(), self.schema, component_observation()
        )
        self.assertFalse(result["release_eligible"])

    def test_component_pins_are_derived_from_observer_and_conflicts_fail_closed(self) -> None:
        current_profile = profile()
        result = device_evidence.build_evidence(
            observation(), current_profile, self.schema, component_observation()
        )
        by_name = {pin["name"]: pin for pin in result["pins"]}
        for role in ("host", "widget", "share", "action"):
            for suffix in ("bundle_identifier", "definition_id", "binary_sha256"):
                name = f"{role}_{suffix}"
                self.assertEqual(
                    current_profile["expected_pins"][name],
                    by_name[name]["observed"],
                )
                self.assertTrue(by_name[name]["matched"])
        self.assertTrue(result["release_eligible"])

        conflicting = observation()
        conflicting["observed_pins"]["action_bundle_identifier"] = "dev.latchway.other"
        conflict_errors = device_evidence.ios_component_observed_pin_errors(
            conflicting["observed_pins"], component_observation()["runtime"]
        )
        self.assertTrue(conflict_errors)
        self.assertFalse(device_evidence.build_evidence(
            conflicting, current_profile, self.schema, component_observation()
        )["release_eligible"])

    def test_tenant_and_identity_provider_pin_mismatches_fail_closed(self) -> None:
        replacements = {
            "latchway_application_id": "app_11111111111111111111111111",
            "latchway_environment": "staging",
            "identity_provider": "oidc",
        }
        for pin, replacement in replacements.items():
            with self.subTest(pin=pin):
                current = observation()
                current["observed_pins"][pin] = replacement
                result = device_evidence.build_evidence(
                    current, profile(), self.schema, component_observation()
                )
                self.assertFalse(result["release_eligible"])

    def test_negative_cases_require_exact_protocol_results(self) -> None:
        current = observation()
        replay = next(item for item in current["tests"] if item["id"] == "dpop_replay_rejected")
        replay["error_code"] = "dpop_invalid"
        result = device_evidence.build_evidence(
            current, profile(), self.schema, component_observation()
        )
        self.assertFalse(result["release_eligible"])

    def test_refresh_error_mapping_revocation_and_protocol_require_concrete_results(self) -> None:
        cases = (
            ("canonical_error_mapping", "mapped_error_type", "kotlin_latchway_exception"),
            ("session_refresh_rotation", "credential_after_sha256", "a" * 64),
            ("installation_revocation", "error_code", "session_revoked"),
            ("protocol_version_rejection", "protocol_version_sent", 1),
        )
        for test_id, field, value in cases:
            with self.subTest(test_id=test_id, field=field):
                current = observation()
                record = next(item for item in current["tests"] if item["id"] == test_id)
                record[field] = value
                result = device_evidence.build_evidence(
                    current, profile(), self.schema, component_observation()
                )
                self.assertFalse(result["release_eligible"])

    def test_component_candidate_identity_and_independent_ids_fail_closed(self) -> None:
        mutations = (
            lambda value: value["runtime"]["identities"][3].__setitem__(
                "bundle_identifier", "dev.latchway.conformance.other"
            ),
            lambda value: value["runtime"]["identities"][3].__setitem__(
                "attestation_mode", "root_app_attest"
            ),
            lambda value: value["runtime"]["identities"][3].__setitem__(
                "dpop_key_id_sha256",
                value["runtime"]["identities"][0]["dpop_key_id_sha256"],
            ),
            lambda value: value["runtime"]["identities"][3].__setitem__(
                "session_id_sha256",
                value["runtime"]["identities"][1]["session_id_sha256"],
            ),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                component = component_observation()
                mutate(component)
                result = device_evidence.build_evidence(
                    observation(), profile(), self.schema, component
                )
                self.assertFalse(result["release_eligible"])

    def test_v1_component_observation_fails_closed(self) -> None:
        component = component_observation()
        component["schema_version"] = "latchway.ios-component-observation.v1"
        errors = device_evidence.validate_component_observation(
            component,
            platform="ios_app_attest",
            run_id="test-run-12345678",
            run_started=now(-2),
            run_completed=now(-1),
        )
        self.assertIn("component observation.schema_version: unsupported value", errors)
        self.assertFalse(device_evidence.build_evidence(
            observation(), profile(), self.schema, component
        )["release_eligible"])

    def test_all_delegated_executions_and_sibling_denial_fail_closed(self) -> None:
        mutations = (
            ("widget_delegated_execution", "http_status", 401),
            ("widget_delegated_execution", "session_id_sha256", "6" * 64),
            ("share_delegated_execution", "trust_source", "delegated_identity_only"),
            ("share_delegated_execution", "component_id_sha256", "f" * 64),
            ("delegated_execution", "trust_source", "delegated_identity_only"),
            ("delegated_execution", "http_status", 401),
            ("delegated_execution", "session_id_sha256", "6" * 64),
            ("sibling_denial", "credential_session_id_sha256", "7" * 64),
            ("sibling_denial", "error_code", "dpop_invalid"),
        )
        for section, field, value in mutations:
            with self.subTest(section=section, field=field):
                component = component_observation()
                component["runtime"][section][field] = value
                result = device_evidence.build_evidence(
                    observation(), profile(), self.schema, component
                )
                self.assertFalse(result["release_eligible"])

        component = component_observation()
        del component["runtime"]["widget_delegated_execution"]
        self.assertFalse(device_evidence.build_evidence(
            observation(), profile(), self.schema, component
        )["release_eligible"])

        component = component_observation()
        component["runtime"]["share_delegated_execution"]["request_id"] = (
            component["runtime"]["widget_delegated_execution"]["request_id"]
        )
        self.assertFalse(device_evidence.build_evidence(
            observation(), profile(), self.schema, component
        )["release_eligible"])

    def test_concrete_keychain_sibling_denial_fails_closed(self) -> None:
        mutations = (
            ("os_status", -25300),
            ("os_status_name", "errSecItemNotFound"),
            ("target_key_id_sha256", "3" * 64),
            ("operation", "SecItemDelete"),
            ("key_material_returned", True),
        )
        for field, value in mutations:
            with self.subTest(field=field):
                component = component_observation()
                component["runtime"]["keychain_sibling_denial"][field] = value
                self.assertFalse(device_evidence.build_evidence(
                    observation(), profile(), self.schema, component
                )["release_eligible"])

        component = component_observation()
        keychain_test = next(
            item
            for item in component["tests"]
            if item["id"] == "component_keychain_sibling_denied"
        )
        keychain_test["os_status"] = -25300
        self.assertFalse(device_evidence.build_evidence(
            observation(), profile(), self.schema, component
        )["release_eligible"])

    def test_component_refresh_race_fails_closed(self) -> None:
        mutations = (
            lambda value: value["runtime"]["component_refresh_race"].__setitem__(
                "requests_started_concurrently", False
            ),
            lambda value: value["runtime"]["component_refresh_race"].__setitem__(
                "overlap_observed", False
            ),
            lambda value: value["runtime"]["component_refresh_race"]["requests"][1].__setitem__(
                "request_id", "request-refresh-race-a"
            ),
            lambda value: value["runtime"]["component_refresh_race"]["requests"][1].__setitem__(
                "access_credential_sha256", "b" * 64
            ),
            lambda value: value["runtime"]["component_refresh_race"]["requests"][0].__setitem__(
                "refresh_credential_sha256", "8" * 64
            ),
            lambda value: value["runtime"]["component_refresh_race"].__setitem__(
                "session_id_before_sha256", "7" * 64
            ),
            lambda value: value["runtime"]["component_refresh_race"]["requests"].pop(),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                component = component_observation()
                mutate(component)
                self.assertFalse(device_evidence.build_evidence(
                    observation(), profile(), self.schema, component
                )["release_eligible"])

        component = component_observation()
        race_test = next(
            item for item in component["tests"] if item["id"] == "component_refresh_race"
        )
        race_test["concurrent_request_count"] = 1
        self.assertFalse(device_evidence.build_evidence(
            observation(), profile(), self.schema, component
        )["release_eligible"])

    def test_no_host_background_termination_and_no_presence_claims_fail_closed(self) -> None:
        invalid = {
            "host_process_running_during_action_request": True,
            "background_execution_observed": False,
            "host_termination_observed": False,
            "user_presence_prompt_observed": True,
        }
        for field, value in invalid.items():
            with self.subTest(field=field):
                component = component_observation()
                component["runtime"]["lifecycle"][field] = value
                result = device_evidence.build_evidence(
                    observation(), profile(), self.schema, component
                )
                self.assertFalse(result["release_eligible"])

    def test_verify_requires_exact_component_observation_bytes(self) -> None:
        evidence, current_profile = self.evidence()
        self.assertIn(
            "component observation is required for iOS release evidence",
            device_evidence.verify(evidence, current_profile, self.schema),
        )
        changed = component_observation()
        changed["runtime"]["lifecycle"]["background_execution_observed"] = False
        self.assertTrue(device_evidence.verify(
            evidence, current_profile, self.schema, changed
        ))

    def test_secret_shaped_values_are_rejected(self) -> None:
        current = observation()
        current["gateway_version"] = "DPoP abcdefghijklmnopqrstuvwxyz0123456789"
        self.assertTrue(device_evidence.secret_scan(current))

    def test_cli_writes_json_junit_and_validation_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            profile_path = root / "profile.json"
            observation_path = root / "observation.json"
            component_observation_path = root / "component-observation.json"
            evidence_path = root / "evidence.json"
            junit_path = root / "junit.xml"
            summary_path = root / "summary.json"
            profile_path.write_text(json.dumps(profile()), encoding="utf-8")
            observation_path.write_text(json.dumps(observation()), encoding="utf-8")
            component_observation_path.write_text(
                json.dumps(component_observation()), encoding="utf-8"
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "finalize",
                    "--schema", str(SCHEMA_PATH),
                    "--profile", str(profile_path),
                    "--observation", str(observation_path),
                    "--component-observation", str(component_observation_path),
                    "--evidence", str(evidence_path),
                    "--junit", str(junit_path),
                    "--summary", str(summary_path),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertTrue(json.loads(summary_path.read_text())["valid"])
            self.assertIn("testsuite", junit_path.read_text())


if __name__ == "__main__":
    unittest.main()
