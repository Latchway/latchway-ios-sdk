#!/usr/bin/env python3
"""Finalize and verify redacted physical-device conformance evidence.

The implementation deliberately uses only the Python standard library so a
release runner never downloads an unpinned schema validator.  It evaluates the
JSON-Schema keywords used by the checked-in schema and then applies the
release-only semantic policy that JSON Schema cannot express succinctly.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from typing import Any


SCHEMA_VERSION = "latchway.physical-device-evidence.v2"
PROFILE_VERSION = "latchway.physical-device-profile.v2"
OBSERVATION_VERSION = "latchway.physical-device-observation.v1"
IOS_COMPONENT_OBSERVATION_VERSION = "latchway.ios-component-observation.v1"

IOS_COMPONENT_ROLE_POLICY = {
    "host": ("main_app", "host_bundle_identifier", "host_definition_id", "host_binary_sha256"),
    "widget": ("widget", "widget_bundle_identifier", "widget_definition_id", "widget_binary_sha256"),
    "share": ("share_extension", "share_bundle_identifier", "share_definition_id", "share_binary_sha256"),
    "action": ("action_extension", "action_bundle_identifier", "action_definition_id", "action_binary_sha256"),
}

IOS_COMPONENT_TESTS = {
    "component_candidate_identities",
    "action_direct_attestation_step_up",
    "component_key_isolation",
    "component_session_isolation",
    "component_sibling_denied",
    "component_no_host_process",
    "component_background_execution",
    "component_host_termination",
    "component_no_user_presence",
}

PLATFORM_POLICY = {
    "ios_app_attest": {
        "repository": "Latchway/latchway-ios-sdk",
        "provider": "app_attest",
        "security": {"secure_enclave"},
        "distribution": {"ad_hoc", "testflight", "app_store"},
        "pins": {
            "application_identifier",
            "app_version",
            "build_number",
            "team_id",
            "signing_certificate_sha256",
            "app_attest_environment",
            "source_commit",
            "core_commit",
            "contract_bundle_sha256",
            "gateway_image_digest",
            "gateway_configuration_sha256",
            "gateway_origin",
            "gateway_environment",
            "gateway_deployment_key_id",
            "gateway_deployment_statement_sha256",
            "gateway_deployment_public_key_sha256",
            "error_mapping_feature",
            "host_bundle_identifier",
            "widget_bundle_identifier",
            "share_bundle_identifier",
            "action_bundle_identifier",
            "host_definition_id",
            "widget_definition_id",
            "share_definition_id",
            "action_definition_id",
            "host_binary_sha256",
            "widget_binary_sha256",
            "share_binary_sha256",
            "action_binary_sha256",
        },
        "tests": {
            "physical_device",
            "identifier_pins",
            "app_attest_supported",
            "secure_enclave_key",
            "app_attest_registration",
            "session_created",
            "dpop_authorized_request",
            "dpop_replay_rejected",
            "tampered_dpop_rejected",
            "streamed_request",
            "quota",
            "app_attest_assertion",
            "canonical_error_mapping",
            "session_refresh_rotation",
            "installation_revocation",
            "protocol_version_rejection",
        } | IOS_COMPONENT_TESTS,
    },
    "android_play_integrity": {
        "repository": "Latchway/latchway-android",
        "provider": "play_integrity",
        "security": {"strongbox", "tee", "unknown_secure_hardware"},
        "distribution": {"play_internal", "play_closed", "play_open", "play_production"},
        "pins": {
            "application_identifier",
            "app_version",
            "build_number",
            "signing_certificate_sha256",
            "cloud_project_number",
            "installer_package",
            "play_track",
            "require_licensed",
            "source_commit",
            "core_commit",
            "contract_bundle_sha256",
            "gateway_image_digest",
            "gateway_configuration_sha256",
            "gateway_origin",
            "gateway_environment",
            "gateway_deployment_key_id",
            "gateway_deployment_statement_sha256",
            "gateway_deployment_public_key_sha256",
            "error_mapping_feature",
        },
        "tests": {
            "physical_device",
            "identifier_pins",
            "play_install_source",
            "play_integrity_standard_request",
            "hardware_backed_key",
            "session_created",
            "dpop_authorized_request",
            "dpop_replay_rejected",
            "tampered_dpop_rejected",
            "streamed_request",
            "quota",
            "canonical_error_mapping",
            "session_refresh_rotation",
            "installation_revocation",
            "protocol_version_rejection",
        },
    },
    "react_native_ios_app_attest": {
        "repository": "Latchway/latchway-react-native-sdk",
        "provider": "app_attest",
        "security": {"secure_enclave"},
        "distribution": {"ad_hoc", "testflight", "app_store"},
        "pins": {
            "application_identifier",
            "app_version",
            "build_number",
            "team_id",
            "signing_certificate_sha256",
            "javascript_bundle_sha256",
            "app_attest_environment",
            "native_sdk_version",
            "native_evidence_sha256",
            "source_commit",
            "core_commit",
            "contract_bundle_sha256",
            "gateway_image_digest",
            "gateway_configuration_sha256",
            "gateway_origin",
            "gateway_environment",
            "gateway_deployment_key_id",
            "gateway_deployment_statement_sha256",
            "gateway_deployment_public_key_sha256",
            "error_mapping_feature",
        },
        "tests": {
            "physical_device",
            "identifier_pins",
            "native_evidence_linked",
            "react_native_bridge",
            "app_attest_session",
            "secure_enclave_key",
            "dpop_authorized_request",
            "dpop_replay_rejected",
            "tampered_dpop_rejected",
            "streamed_request",
            "quota",
            "canonical_error_mapping",
            "session_refresh_rotation",
            "installation_revocation",
            "protocol_version_rejection",
        },
    },
    "react_native_android_play_integrity": {
        "repository": "Latchway/latchway-react-native-sdk",
        "provider": "play_integrity",
        "security": {"strongbox", "tee", "unknown_secure_hardware"},
        "distribution": {"play_internal", "play_closed", "play_open", "play_production"},
        "pins": {
            "application_identifier",
            "app_version",
            "build_number",
            "signing_certificate_sha256",
            "cloud_project_number",
            "installer_package",
            "play_track",
            "require_licensed",
            "native_sdk_version",
            "native_evidence_sha256",
            "source_commit",
            "core_commit",
            "contract_bundle_sha256",
            "gateway_image_digest",
            "gateway_configuration_sha256",
            "gateway_origin",
            "gateway_environment",
            "gateway_deployment_key_id",
            "gateway_deployment_statement_sha256",
            "gateway_deployment_public_key_sha256",
            "error_mapping_feature",
        },
        "tests": {
            "physical_device",
            "identifier_pins",
            "native_evidence_linked",
            "react_native_bridge",
            "play_integrity_session",
            "hardware_backed_key",
            "dpop_authorized_request",
            "dpop_replay_rejected",
            "tampered_dpop_rejected",
            "streamed_request",
            "quota",
            "canonical_error_mapping",
            "session_refresh_rotation",
            "installation_revocation",
            "protocol_version_rejection",
        },
    },
}

SECRET_PATTERNS = (
    re.compile(r"(?:Bearer|DPoP)\s+[A-Za-z0-9._~-]{16,}", re.IGNORECASE),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"\b(?:lwa|lws|sk)-[A-Za-z0-9_-]{16,}\b", re.IGNORECASE),
)


def reject_duplicate_members(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object member: {key}")
        value[key] = item
    return value


def reject_nonfinite_number(value: str) -> Any:
    raise ValueError(f"non-finite JSON number: {value}")


def load_json(path: pathlib.Path) -> Any:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing JSON file: {path}")
    size = path.stat().st_size
    if size == 0:
        raise ValueError(f"empty JSON file: {path}")
    if size > 1_048_576:
        raise ValueError(f"JSON file exceeds 1 MiB: {path}")
    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicate_members,
            parse_constant=reject_nonfinite_number,
        )
    except (OSError, UnicodeError, ValueError) as error:
        raise ValueError(f"invalid UTF-8 JSON in {path}: {error}") from error


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_sha256(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(encoded).hexdigest()


def parse_date_time(value: str) -> dt.datetime:
    if not value.endswith("Z"):
        raise ValueError("date-time must use UTC Z notation")
    parsed = dt.datetime.fromisoformat(value[:-1] + "+00:00")
    if parsed.tzinfo is None:
        raise ValueError("date-time must contain a timezone")
    return parsed


def json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def schema_errors(value: Any, schema: dict[str, Any], path: str = "$") -> list[str]:
    errors: list[str] = []
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: is not an allowed value")

    expected_type = schema.get("type")
    if expected_type is not None and not json_type_matches(value, expected_type):
        return errors + [f"{path}: expected {expected_type}"]

    if isinstance(value, dict):
        required = schema.get("required", [])
        for name in required:
            if name not in value:
                errors.append(f"{path}: missing required property {name!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for name in value:
                if name not in properties:
                    errors.append(f"{path}: unexpected property {name!r}")
        for name, child in value.items():
            if name in properties:
                errors.extend(schema_errors(child, properties[name], f"{path}.{name}"))

    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: contains too few items")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            errors.append(f"{path}: contains too many items")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, child in enumerate(value):
                errors.extend(schema_errors(child, item_schema, f"{path}[{index}]"))

    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{path}: string is too short")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: string is too long")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            errors.append(f"{path}: does not match the required pattern")
        if schema.get("format") == "date-time":
            try:
                parse_date_time(value)
            except (TypeError, ValueError):
                errors.append(f"{path}: is not an RFC 3339 UTC date-time")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: is below the minimum")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: exceeds the maximum")
    return errors


def validate_profile(profile: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(profile, dict):
        return ["profile: expected object"]
    allowed = {
        "schema_version", "platform", "repository", "source", "toolchain",
        "expected_pins", "application_binary_sha256", "device_inventory_sha256",
    }
    extras = sorted(set(profile) - allowed)
    if extras:
        errors.append(f"profile: unexpected properties: {', '.join(extras)}")
    required = allowed
    missing = sorted(required - set(profile))
    if missing:
        errors.append(f"profile: missing properties: {', '.join(missing)}")
        return errors
    if profile["schema_version"] != PROFILE_VERSION:
        errors.append("profile.schema_version: unsupported value")
    platform = profile.get("platform")
    policy = PLATFORM_POLICY.get(platform)
    if policy is None:
        errors.append("profile.platform: unsupported value")
        return errors
    if profile.get("repository") != policy["repository"]:
        errors.append("profile.repository: does not match platform owner")
    source = profile.get("source")
    if not isinstance(source, dict):
        errors.append("profile.source: expected object")
    else:
        required_source = {
            "commit", "core_commit", "worktree_clean", "sdk_version", "contract_version",
            "contract_bundle_sha256", "gateway_image_digest",
            "gateway_configuration_sha256", "gateway_origin",
            "gateway_deployment_key_id", "gateway_deployment_statement_sha256",
            "gateway_deployment_public_key_sha256",
        }
        if set(source) != required_source:
            errors.append("profile.source: fields must exactly match the profile contract")
        if re.fullmatch(r"[0-9a-f]{40}", str(source.get("commit", ""))) is None:
            errors.append("profile.source.commit: expected full lowercase commit")
        if re.fullmatch(r"[0-9a-f]{40}", str(source.get("core_commit", ""))) is None:
            errors.append("profile.source.core_commit: expected full lowercase commit")
        if source.get("worktree_clean") is not True:
            errors.append("profile.source.worktree_clean: release proof requires a clean source tree")
        for name in (
            "contract_bundle_sha256", "gateway_configuration_sha256",
            "gateway_deployment_statement_sha256", "gateway_deployment_public_key_sha256",
        ):
            if re.fullmatch(r"[0-9a-f]{64}", str(source.get(name, ""))) is None:
                errors.append(f"profile.source.{name}: expected lowercase SHA-256")
        if re.fullmatch(r"sha256:[0-9a-f]{64}", str(source.get("gateway_image_digest", ""))) is None:
            errors.append("profile.source.gateway_image_digest: expected immutable OCI digest")
        if (
            not isinstance(source.get("gateway_origin"), str)
            or len(source["gateway_origin"]) > 512
            or re.fullmatch(r"https://[a-z0-9][A-Za-z0-9.-]*(?::[1-9][0-9]{0,4})?(?:/[A-Za-z0-9_~.-]+)*", source["gateway_origin"]) is None
        ):
            errors.append("profile.source.gateway_origin: expected bounded canonical HTTPS origin")
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}", str(source.get("gateway_deployment_key_id", ""))) is None:
            errors.append("profile.source.gateway_deployment_key_id: expected bounded key identifier")
    toolchain = profile.get("toolchain")
    required_toolchain = {"runner_os", "runner_arch", "compiler", "build_tool", "collector_version"}
    if not isinstance(toolchain, dict) or set(toolchain) != required_toolchain:
        errors.append("profile.toolchain: fields must exactly match the profile contract")
    elif toolchain.get("collector_version") != "2":
        errors.append("profile.toolchain.collector_version: unsupported value")
    pins = profile.get("expected_pins")
    if not isinstance(pins, dict) or set(pins) != policy["pins"]:
        errors.append("profile.expected_pins: names must exactly match platform policy")
    elif any(not isinstance(item, str) or not item or len(item) > 512 for item in pins.values()):
        errors.append("profile.expected_pins: every value must be a bounded non-empty string")
    binary_hash = profile.get("application_binary_sha256")
    if re.fullmatch(r"[0-9a-f]{64}", str(binary_hash)) is None:
        errors.append("profile.application_binary_sha256: expected lowercase SHA-256")
    inventory_hash = profile.get("device_inventory_sha256")
    if re.fullmatch(r"[0-9a-f]{64}", str(inventory_hash)) is None:
        errors.append("profile.device_inventory_sha256: expected lowercase SHA-256")
    return errors


def validate_observation(observation: Any, platform: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(observation, dict):
        return ["observation: expected object"]
    required = {
        "schema_version", "platform", "run", "gateway_version", "application",
        "device", "provider", "observed_pins", "tests", "redaction",
    }
    if set(observation) != required:
        errors.append("observation: fields must exactly match the observation contract")
        return errors
    if observation["schema_version"] != OBSERVATION_VERSION:
        errors.append("observation.schema_version: unsupported value")
    if observation["platform"] != platform:
        errors.append("observation.platform: does not match profile")
    if not isinstance(observation.get("observed_pins"), dict):
        errors.append("observation.observed_pins: expected object")
    return errors


def validate_component_observation(
    observation: Any,
    *,
    platform: str,
    run_id: str,
    run_started: str,
    run_completed: str | None = None,
) -> list[str]:
    errors: list[str] = []
    if not isinstance(observation, dict):
        return ["component observation: expected object"]
    required = {
        "schema_version", "platform", "run_id", "started_at", "completed_at",
        "runtime", "tests",
    }
    if set(observation) != required:
        errors.append("component observation: fields must exactly match the observation contract")
        return errors
    if observation.get("schema_version") != IOS_COMPONENT_OBSERVATION_VERSION:
        errors.append("component observation.schema_version: unsupported value")
    if platform != "ios_app_attest" or observation.get("platform") != platform:
        errors.append("component observation.platform: direct Action proof requires ios_app_attest")
    if observation.get("run_id") != run_id:
        errors.append("component observation.run_id: does not match the physical-device run")
    try:
        physical_started = parse_date_time(run_started)
        component_started = parse_date_time(observation["started_at"])
        component_completed = parse_date_time(observation["completed_at"])
        if component_started < physical_started or component_completed < component_started:
            errors.append("component observation: time interval is outside the physical-device run")
        if component_completed - component_started > dt.timedelta(hours=2):
            errors.append("component observation: exceeded the two-hour evidence window")
        if run_completed is not None and component_completed > parse_date_time(run_completed):
            errors.append("component observation: completed after finalized physical-device run")
    except (KeyError, TypeError, ValueError):
        errors.append("component observation: invalid UTC time interval")

    tests = observation.get("tests")
    if not isinstance(tests, list):
        errors.append("component observation.tests: expected array")
    else:
        by_id = {
            item.get("id"): item
            for item in tests
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
        if len(by_id) != len(tests) or set(by_id) != IOS_COMPONENT_TESTS:
            errors.append("component observation.tests: must contain the exact direct-component test set")
        elif any(item.get("status") != "passed" for item in by_id.values()):
            errors.append("component observation.tests: every observed component test must pass")
        denial = by_id.get("component_sibling_denied", {})
        if (
            denial.get("http_status") != 401
            or denial.get("error_code") != "component_key_invalid"
            or re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}",
                str(denial.get("request_id", "")),
            ) is None
        ):
            errors.append("component observation.tests: sibling denial is not a concrete canonical rejection")
    return errors


def ios_component_runtime_errors(runtime: Any, profile: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if not isinstance(runtime, dict):
        return ["component_runtime: expected object"]
    expected_pins = profile.get("expected_pins", {})
    identities = runtime.get("identities")
    if not isinstance(identities, list) or len(identities) != 4:
        return ["component_runtime.identities: exactly four component identities are required"]
    by_role: dict[str, dict[str, Any]] = {}
    for identity in identities:
        if (
            not isinstance(identity, dict)
            or not isinstance(identity.get("role"), str)
            or identity["role"] in by_role
        ):
            errors.append("component_runtime.identities: roles must be unique objects")
            continue
        by_role[identity["role"]] = identity
    if set(by_role) != set(IOS_COMPONENT_ROLE_POLICY):
        errors.append("component_runtime.identities: host, widget, share, and action are required")
        return errors

    hash_fields = (
        "binary_sha256", "principal_id_sha256", "dpop_key_id_sha256", "session_id_sha256",
    )
    for role, (kind, bundle_pin, definition_pin, binary_pin) in IOS_COMPONENT_ROLE_POLICY.items():
        identity = by_role[role]
        if (
            identity.get("kind") != kind
            or identity.get("bundle_identifier") != expected_pins.get(bundle_pin)
            or identity.get("definition_id") != expected_pins.get(definition_pin)
            or identity.get("binary_sha256") != expected_pins.get(binary_pin)
        ):
            errors.append(f"component_runtime.identities: {role} is not bound to the protected candidate")
        if any(re.fullmatch(r"[0-9a-f]{64}", str(identity.get(field, ""))) is None for field in hash_fields):
            errors.append(f"component_runtime.identities: {role} contains an invalid redacted identifier")

    for field in ("principal_id_sha256", "dpop_key_id_sha256", "session_id_sha256"):
        values = [identity.get(field) for identity in identities]
        if len(set(values)) != 4:
            errors.append(f"component_runtime.identities: {field} values are not independent")

    action = by_role["action"]
    step_up = runtime.get("direct_step_up")
    if not isinstance(step_up, dict):
        errors.append("component_runtime.direct_step_up: expected object")
    else:
        if (
            step_up.get("role") != "action"
            or step_up.get("definition_id") != action.get("definition_id")
            or step_up.get("component_id_sha256") != action.get("principal_id_sha256")
            or step_up.get("dpop_key_id_sha256") != action.get("dpop_key_id_sha256")
            or step_up.get("session_after_sha256") != action.get("session_id_sha256")
            or step_up.get("session_before_sha256") == step_up.get("session_after_sha256")
            or step_up.get("trust_source_before")
            not in {"delegated_from_attested_root", "delegated_identity_only"}
            or step_up.get("trust_source_after") != "delegated_direct_attested"
            or step_up.get("binding_version") != 2
            or step_up.get("request_hash_bound") is not True
        ):
            errors.append("component_runtime.direct_step_up: does not prove the Action component transition")
        app_attest_key = step_up.get("app_attest_key_id_sha256")
        if (
            re.fullmatch(r"[0-9a-f]{64}", str(app_attest_key or "")) is None
            or app_attest_key in {item.get("dpop_key_id_sha256") for item in identities}
        ):
            errors.append("component_runtime.direct_step_up: App Attest key identity is invalid or reused")

    denial = runtime.get("sibling_denial")
    if not isinstance(denial, dict):
        errors.append("component_runtime.sibling_denial: expected object")
    else:
        sibling = by_role.get(str(denial.get("credential_role")), {})
        if (
            denial.get("requesting_role") != "action"
            or denial.get("credential_role") not in {"widget", "share"}
            or denial.get("credential_session_id_sha256") != sibling.get("session_id_sha256")
            or denial.get("credential_session_id_sha256") == action.get("session_id_sha256")
            or denial.get("http_status") != 401
            or denial.get("error_code") != "component_key_invalid"
            or re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._:-]{7,127}",
                str(denial.get("request_id", "")),
            ) is None
        ):
            errors.append("component_runtime.sibling_denial: sibling credential misuse was not denied")

    lifecycle = runtime.get("lifecycle")
    if lifecycle != {
        "host_process_running_during_step_up": False,
        "background_execution_observed": True,
        "host_termination_observed": True,
        "user_presence_prompt_observed": False,
    }:
        errors.append("component_runtime.lifecycle: no-host/background/termination/no-presence proof is incomplete")
    return errors


def secret_scan(value: Any, path: str = "$") -> list[str]:
    errors: list[str] = []
    if isinstance(value, dict):
        forbidden_names = {
            "authorization", "identity_token", "access_token", "session_token",
            "refresh_token", "dpop", "dpop_proof", "attestation_object",
            "assertion_object", "integrity_token", "private_key", "provider_credential",
        }
        for name, child in value.items():
            if name.lower() in forbidden_names:
                errors.append(f"{path}: forbidden sensitive field {name!r}")
            errors.extend(secret_scan(child, f"{path}.{name}"))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            errors.extend(secret_scan(child, f"{path}[{index}]"))
    elif isinstance(value, str):
        for pattern in SECRET_PATTERNS:
            if pattern.search(value):
                errors.append(f"{path}: resembles credential material")
                break
    return errors


def semantic_errors(evidence: dict[str, Any], profile: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    platform = evidence.get("platform")
    policy = PLATFORM_POLICY.get(platform)
    if policy is None:
        return ["platform policy is unavailable"]
    if platform != profile.get("platform"):
        errors.append("platform does not match protected profile")
    source = evidence.get("source", {})
    if source.get("repository") != policy["repository"]:
        errors.append("source repository does not match platform")
    expected_source = profile.get("source", {})
    for name, expected in expected_source.items():
        if source.get(name) != expected:
            errors.append(f"source.{name} does not match protected profile")
    if source.get("worktree_clean") is not True:
        errors.append("source worktree was not clean")

    try:
        started = parse_date_time(evidence["run"]["started_at"])
        completed = parse_date_time(evidence["run"]["completed_at"])
        generated = parse_date_time(evidence["generated_at"])
        if completed < started:
            errors.append("run completed before it started")
        if completed - started > dt.timedelta(hours=2):
            errors.append("physical-device run exceeded the two-hour evidence window")
        if generated < completed or generated - completed > dt.timedelta(hours=1):
            errors.append("evidence was not finalized promptly after the device run")
    except (KeyError, TypeError, ValueError):
        pass

    application = evidence.get("application", {})
    if application.get("build_mode") != "release" or application.get("debuggable") is not False:
        errors.append("debug or non-release application cannot be release evidence")
    if application.get("distribution") not in policy["distribution"]:
        errors.append("application distribution channel is not release eligible")
    if platform.endswith("ios_app_attest"):
        if application.get("app_attest_environment") != "production":
            errors.append("App Attest release evidence requires the production entitlement")
        if not isinstance(application.get("team_id"), str):
            errors.append("Apple team ID is absent")
        if platform == "ios_app_attest":
            expected_pins = profile.get("expected_pins", {})
            if (
                application.get("identifier") != expected_pins.get("host_bundle_identifier")
                or profile.get("application_binary_sha256") != expected_pins.get("host_binary_sha256")
            ):
                errors.append("host application identity is not bound to the component candidate")
            errors.extend(ios_component_runtime_errors(evidence.get("component_runtime"), profile))
    else:
        if application.get("installer_package") != "com.android.vending":
            errors.append("Play Integrity release evidence must be Play installed")
        if not isinstance(application.get("cloud_project_number"), str):
            errors.append("Play Integrity cloud project is absent")
    if platform.startswith("react_native_"):
        if application.get("new_architecture") is not True:
            errors.append("React Native release evidence requires the New Architecture")
        if not isinstance(application.get("native_evidence_sha256"), str):
            errors.append("linked native physical evidence hash is absent")

    device = evidence.get("device", {})
    if device.get("physical") is not True:
        errors.append("device did not report physical hardware")
    for name in ("simulator", "emulator", "testing", "debugger_attached"):
        if device.get(name) is not False:
            errors.append(f"device.{name} must be false for release evidence")
    if device.get("security_level") not in policy["security"]:
        errors.append("device key storage is not an accepted hardware-backed level")

    provider = evidence.get("provider", {})
    if provider.get("name") != policy["provider"]:
        errors.append("attestation provider does not match platform")
    if provider.get("environment") != "production":
        errors.append("debug/development attestation cannot be release evidence")
    if provider.get("request_hash_bound") is not True:
        errors.append("attestation was not bound to the server challenge")
    if platform.endswith("android_play_integrity"):
        if provider.get("app_recognition") != "PLAY_RECOGNIZED":
            errors.append("Play app-recognition verdict is not PLAY_RECOGNIZED")
        if provider.get("account_licensing") != "LICENSED":
            errors.append("Play account-licensing verdict is not LICENSED")
    else:
        if provider.get("app_recognition") != "not_applicable" or provider.get("account_licensing") != "not_applicable":
            errors.append("Apple evidence contains an impossible Play verdict")

    expected_pins = profile.get("expected_pins", {})
    if platform.endswith("android_play_integrity") and expected_pins.get("require_licensed") != "true":
        errors.append("Play release evidence requires the protected licensed-account policy")
    pins = evidence.get("pins", [])
    pin_names = [pin.get("name") for pin in pins if isinstance(pin, dict)]
    if len(pin_names) != len(set(pin_names)):
        errors.append("pin names are not unique")
    if set(pin_names) != policy["pins"]:
        errors.append("evidence pin names do not exactly match platform policy")
    for pin in pins:
        if not isinstance(pin, dict):
            continue
        name = pin.get("name")
        if pin.get("expected") != expected_pins.get(name):
            errors.append(f"pin {name!r} expected value does not match protected profile")
        if pin.get("observed") != pin.get("expected") or pin.get("matched") is not True:
            errors.append(f"pin {name!r} did not match")

    tests = evidence.get("tests", [])
    test_names = [test.get("id") for test in tests if isinstance(test, dict)]
    if len(test_names) != len(set(test_names)):
        errors.append("test IDs are not unique")
    missing_tests = sorted(policy["tests"] - set(test_names))
    if missing_tests:
        errors.append(f"required tests are absent: {', '.join(missing_tests)}")
    for test in tests:
        if isinstance(test, dict) and test.get("status") != "passed":
            errors.append(f"test {test.get('id')!r} did not pass")
    tests_by_name = {test.get("id"): test for test in tests if isinstance(test, dict)}
    negative_expectations = {
        "dpop_replay_rejected": (401, "dpop_replayed"),
        "tampered_dpop_rejected": (401, "dpop_invalid"),
        "canonical_error_mapping": (404, "feature_not_found"),
        "installation_revocation": (403, "installation_revoked"),
        "protocol_version_rejection": (426, "protocol_version_unsupported"),
        "component_sibling_denied": (401, "component_key_invalid"),
    }
    for name, (status, code) in negative_expectations.items():
        test = tests_by_name.get(name, {})
        if test.get("http_status") != status or test.get("error_code") != code:
            errors.append(f"{name} did not record canonical HTTP {status} {code}")
        if not isinstance(test.get("request_id"), str):
            errors.append(f"{name} did not retain a redacted request ID")

    mapped_error_types = {
        "ios_app_attest": "swift_latchway_problem",
        "android_play_integrity": "kotlin_latchway_exception",
        "react_native_ios_app_attest": "react_native_latchway_error",
        "react_native_android_play_integrity": "react_native_latchway_error",
    }
    mapping = tests_by_name.get("canonical_error_mapping", {})
    if mapping.get("mapped_error_type") != mapped_error_types[platform]:
        errors.append("canonical_error_mapping did not record the platform SDK's typed error")

    protocol = tests_by_name.get("protocol_version_rejection", {})
    if protocol.get("protocol_version_sent") != 0:
        errors.append("protocol_version_rejection did not record the rejected version")

    rotation = tests_by_name.get("session_refresh_rotation", {})
    before_credential = rotation.get("credential_before_sha256")
    after_credential = rotation.get("credential_after_sha256")
    before_installation = rotation.get("installation_before_sha256")
    after_installation = rotation.get("installation_after_sha256")
    hashes = (before_credential, after_credential, before_installation, after_installation)
    if any(re.fullmatch(r"[0-9a-f]{64}", str(value)) is None for value in hashes):
        errors.append("session_refresh_rotation did not retain four redacted SHA-256 observations")
    elif before_credential == after_credential or before_installation != after_installation:
        errors.append("session_refresh_rotation did not rotate credentials for the same installation")

    redaction = evidence.get("redaction", {})
    if not isinstance(redaction, dict) or any(value is not False for value in redaction.values()):
        errors.append("redaction declaration reports retained secret material")
    errors.extend(secret_scan(evidence))

    artifacts = evidence.get("artifacts", {})
    if artifacts.get("profile_sha256") != canonical_sha256(profile):
        errors.append("profile hash does not match protected profile")
    if platform == "ios_app_attest" and re.fullmatch(
        r"[0-9a-f]{64}", str(artifacts.get("component_observation_sha256", ""))
    ) is None:
        errors.append("component observation hash is absent")
    return errors


def build_evidence(
    observation: dict[str, Any],
    profile: dict[str, Any],
    schema: dict[str, Any],
    component_observation: dict[str, Any] | None = None,
    component_observation_sha256: str | None = None,
) -> dict[str, Any]:
    combined = copy.deepcopy(observation)
    if component_observation is not None:
        combined["component_runtime"] = copy.deepcopy(component_observation["runtime"])
        combined["tests"] = list(combined["tests"]) + copy.deepcopy(component_observation["tests"])
        if parse_date_time(component_observation["completed_at"]) > parse_date_time(
            combined["run"]["completed_at"]
        ):
            combined["run"]["completed_at"] = component_observation["completed_at"]

    observed_pins = combined["observed_pins"]
    expected_pins = profile["expected_pins"]
    pins = [
        {
            "name": name,
            "expected": expected,
            "observed": str(observed_pins.get(name, "")),
            "matched": observed_pins.get(name) == expected,
        }
        for name, expected in sorted(expected_pins.items())
    ]
    evidence = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "release_eligible": False,
        "platform": profile["platform"],
        "run": combined["run"],
        "source": {
            "repository": profile["repository"],
            **profile["source"],
            "gateway_version": combined["gateway_version"],
        },
        "toolchain": profile["toolchain"],
        "application": combined["application"],
        "device": combined["device"],
        "provider": combined["provider"],
        "pins": pins,
        "tests": combined["tests"],
        "redaction": combined["redaction"],
        "artifacts": {
            "observation_sha256": canonical_sha256(observation),
            "application_binary_sha256": profile["application_binary_sha256"],
            "device_inventory_sha256": profile["device_inventory_sha256"],
            "profile_sha256": canonical_sha256(profile),
            "schema_sha256": canonical_sha256(schema),
        },
    }
    if component_observation is not None:
        evidence["component_runtime"] = combined["component_runtime"]
        evidence["artifacts"]["component_observation_sha256"] = (
            component_observation_sha256 or canonical_sha256(component_observation)
        )
    evidence["release_eligible"] = not (
        schema_errors(evidence, schema) + semantic_errors(evidence, profile)
    )
    return evidence


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_junit(path: pathlib.Path, evidence: dict[str, Any] | None, errors: list[str]) -> None:
    test_entries = evidence.get("tests", []) if isinstance(evidence, dict) else []
    count = 1 + len(test_entries)
    failures = len(errors) + sum(1 for entry in test_entries if entry.get("status") != "passed")
    suite = ET.Element("testsuite", {
        "name": "physical-device-evidence",
        "tests": str(count),
        "failures": str(failures),
        "errors": "0",
    })
    policy_case = ET.SubElement(suite, "testcase", {"name": "evidence-policy"})
    if errors:
        failure = ET.SubElement(policy_case, "failure", {"message": "evidence rejected"})
        failure.text = "\n".join(errors)
    for entry in test_entries:
        case = ET.SubElement(suite, "testcase", {
            "name": str(entry.get("id", "unknown")),
            "time": f"{int(entry.get('duration_ms', 0)) / 1000:.3f}",
        })
        if entry.get("status") != "passed":
            failure = ET.SubElement(case, "failure", {"message": f"status={entry.get('status', 'missing')}"})
            failure.text = "Physical-device check did not pass; no secret detail is retained."
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def verify(
    evidence: dict[str, Any],
    profile: dict[str, Any],
    schema: dict[str, Any],
    component_observation: dict[str, Any] | None = None,
    component_observation_sha256: str | None = None,
) -> list[str]:
    errors = schema_errors(evidence, schema)
    errors.extend(semantic_errors(evidence, profile))
    if evidence.get("release_eligible") is not True:
        errors.append("release_eligible is not true")
    artifacts = evidence.get("artifacts", {})
    if artifacts.get("schema_sha256") != canonical_sha256(schema):
        errors.append("schema hash does not match checked-in schema")
    if evidence.get("platform") == "ios_app_attest":
        if component_observation is None:
            errors.append("component observation is required for iOS release evidence")
        else:
            errors.extend(validate_component_observation(
                component_observation,
                platform="ios_app_attest",
                run_id=str(evidence.get("run", {}).get("id", "")),
                run_started=str(evidence.get("run", {}).get("started_at", "")),
                run_completed=str(evidence.get("run", {}).get("completed_at", "")),
            ))
            if component_observation.get("runtime") != evidence.get("component_runtime"):
                errors.append("component observation runtime does not match finalized evidence")
            component_tests = component_observation.get("tests", [])
            evidence_component_tests = [
                item for item in evidence.get("tests", [])
                if isinstance(item, dict) and item.get("id") in IOS_COMPONENT_TESTS
            ]
            if component_tests != evidence_component_tests:
                errors.append("component observation tests do not match finalized evidence")
            expected_component_hash = (
                component_observation_sha256 or canonical_sha256(component_observation)
            )
            if artifacts.get("component_observation_sha256") != expected_component_hash:
                errors.append("component observation hash does not match finalized evidence")
    return sorted(set(errors))


def write_summary(path: pathlib.Path, evidence_path: pathlib.Path, evidence: dict[str, Any] | None, errors: list[str]) -> None:
    summary = {
        "schema_version": "latchway.physical-device-validation.v1",
        "valid": not errors,
        "evidence_sha256": sha256_file(evidence_path) if evidence_path.is_file() else None,
        "platform": evidence.get("platform") if isinstance(evidence, dict) else None,
        "source_commit": evidence.get("source", {}).get("commit") if isinstance(evidence, dict) else None,
        "run_id": evidence.get("run", {}).get("id") if isinstance(evidence, dict) else None,
        "errors": errors,
    }
    write_json(path, summary)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("finalize", "verify"))
    parser.add_argument("--schema", type=pathlib.Path, required=True)
    parser.add_argument("--profile", type=pathlib.Path, required=True)
    parser.add_argument("--evidence", type=pathlib.Path, required=True)
    parser.add_argument("--observation", type=pathlib.Path)
    parser.add_argument("--component-observation", type=pathlib.Path)
    parser.add_argument("--junit", type=pathlib.Path, required=True)
    parser.add_argument("--summary", type=pathlib.Path, required=True)
    args = parser.parse_args()

    evidence: dict[str, Any] | None = None
    errors: list[str] = []
    try:
        schema = load_json(args.schema)
        profile = load_json(args.profile)
        errors.extend(validate_profile(profile))
        component_observation: dict[str, Any] | None = None
        component_observation_sha256: str | None = None
        if args.component_observation is not None:
            component_observation = load_json(args.component_observation)
            component_observation_sha256 = sha256_file(args.component_observation)
            errors.extend(secret_scan(component_observation))
        if args.command == "finalize":
            if args.observation is None:
                errors.append("finalize requires --observation")
            else:
                observation = load_json(args.observation)
                errors.extend(validate_observation(observation, profile.get("platform", "")))
                errors.extend(secret_scan(observation))
                if profile.get("platform") == "ios_app_attest":
                    if component_observation is None:
                        errors.append("finalize requires --component-observation for ios_app_attest")
                    else:
                        errors.extend(validate_component_observation(
                            component_observation,
                            platform="ios_app_attest",
                            run_id=str(observation.get("run", {}).get("id", "")),
                            run_started=str(observation.get("run", {}).get("started_at", "")),
                        ))
                        errors.extend(ios_component_runtime_errors(
                            component_observation.get("runtime"), profile
                        ))
                if not errors:
                    evidence = build_evidence(
                        observation,
                        profile,
                        schema,
                        component_observation,
                        component_observation_sha256,
                    )
                    write_json(args.evidence, evidence)
                    errors.extend(verify(
                        evidence,
                        profile,
                        schema,
                        component_observation,
                        component_observation_sha256,
                    ))
        else:
            evidence = load_json(args.evidence)
            errors.extend(verify(
                evidence,
                profile,
                schema,
                component_observation,
                component_observation_sha256,
            ))
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors.append(str(error))

    errors = sorted(set(errors))
    write_junit(args.junit, evidence, errors)
    write_summary(args.summary, args.evidence, evidence, errors)
    if errors:
        for error in errors:
            print(f"device evidence rejected: {error}", file=sys.stderr)
        return 1
    print(f"physical-device evidence accepted: {args.evidence}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
