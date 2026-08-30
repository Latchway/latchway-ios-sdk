#!/usr/bin/env python3
"""Fail-closed inspection and safe metadata emission for the signed iOS proof host."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
from typing import Any

from physical_app_bundle_tree import (
    BundleTreeError,
    app_bundle_tree_digest,
    assert_no_case_or_nfc_collisions,
)


SHA256 = re.compile(r"^[0-9a-f]{64}$")
BUNDLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{2,254}$")
DEFINITION_ID = re.compile(r"^[a-z][a-z0-9_-]{0,62}$")
PROFILE_UUID = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
FORBIDDEN_INFO_KEY = re.compile(
    r"(?i)(identity.?token|device.?grant|access.?token|refresh.?token|secret|private.?key|credential)"
)


class CandidateError(RuntimeError):
    pass


def required(name: str, pattern: re.Pattern[str] | None = None) -> str:
    value = os.environ.get(name, "")
    if not value or "\x00" in value or "\r" in value or "\n" in value:
        raise CandidateError(f"required safe environment value is missing: {name}")
    if pattern is not None and pattern.fullmatch(value) is None:
        raise CandidateError(f"environment value is invalid: {name}")
    return value


def run(*arguments: str) -> bytes:
    result = subprocess.run(arguments, check=False, capture_output=True)
    if result.returncode != 0:
        raise CandidateError(f"candidate inspection command failed: {arguments[0]}")
    return result.stdout


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_plist(path: pathlib.Path) -> dict[str, Any]:
    if not path.is_file() or path.is_symlink():
        raise CandidateError(f"required candidate plist is missing or unsafe: {path.name}")
    value = plistlib.loads(path.read_bytes())
    if not isinstance(value, dict):
        raise CandidateError(f"candidate plist is not a dictionary: {path.name}")
    return value


def signed_entitlements(bundle: pathlib.Path) -> dict[str, Any]:
    value = plistlib.loads(run("codesign", "-d", "--entitlements", ":-", str(bundle)))
    if not isinstance(value, dict):
        raise CandidateError("signed entitlements are not a dictionary")
    return value


def embedded_profile(bundle: pathlib.Path) -> dict[str, Any]:
    profile_path = bundle / "embedded.mobileprovision"
    if not profile_path.is_file() or profile_path.is_symlink():
        raise CandidateError("an embedded provisioning profile is missing or unsafe")
    decoded = subprocess.run(
        ("security", "cms", "-D", "-i", str(profile_path)),
        check=False,
        capture_output=True,
    )
    if decoded.returncode != 0:
        # Recent Apple profiles can fail Security.framework CMS decoding on
        # some pinned macOS/Xcode images. OpenSSL still verifies the CMS
        # signature while -noverify deliberately skips only trust-chain lookup.
        decoded = subprocess.run(
            (
                "openssl", "smime", "-verify", "-inform", "der", "-noverify",
                "-in", str(profile_path),
            ),
            check=False,
            capture_output=True,
        )
    if decoded.returncode != 0:
        raise CandidateError("embedded provisioning profile CMS verification failed")
    value = plistlib.loads(decoded.stdout)
    if not isinstance(value, dict):
        raise CandidateError("embedded provisioning profile is invalid")
    return value


def signing_certificate(bundle: pathlib.Path, directory: pathlib.Path) -> tuple[str, bytes]:
    prefix = directory / f"certificate-{bundle.name}-"
    run("codesign", "-d", "--extract-certificates", str(prefix), str(bundle))
    leaf = pathlib.Path(f"{prefix}0")
    if not leaf.is_file() or leaf.is_symlink():
        raise CandidateError("codesign did not extract a safe leaf certificate")
    data = leaf.read_bytes()
    return hashlib.sha256(data).hexdigest(), data


def validated_profile_expiration(profile: dict[str, Any], role: str) -> dt.datetime:
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        raise CandidateError(f"{role} provisioning profile expiration is missing")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        raise CandidateError(f"{role} provisioning profile is expired")
    return expiration


def profile_group_authorizes(profile_group: str, signed_group: str) -> bool:
    if not profile_group or not signed_group:
        return False
    if profile_group == signed_group:
        return True
    wildcard_prefix = profile_group[:-1] if profile_group.endswith("*") else ""
    return bool(wildcard_prefix) and signed_group.startswith(wildcard_prefix)


def require_candidate_identity(
    bundle: pathlib.Path,
    *,
    role: str,
    bundle_id: str,
    extension_point: str | None,
    expected_groups: set[str],
    app_attest: bool,
    expected_profile_uuid: str,
    team_id: str,
    app_id_prefix: str,
    version: str,
    build: str,
    certificate_sha256: str,
    temporary: pathlib.Path,
    expected_info: dict[str, str],
    expects_app_attest_info: bool,
) -> dict[str, Any]:
    if not bundle.is_dir() or bundle.is_symlink():
        raise CandidateError(f"{role} bundle is missing or unsafe")
    run("codesign", "--verify", "--strict", str(bundle))
    info = load_plist(bundle / "Info.plist")
    if any(info.get(key) != value for key, value in expected_info.items()):
        raise CandidateError(f"{role} embedded Latchway configuration does not match")
    info_attest = info.get("LatchwayAppAttestEnvironment")
    if expects_app_attest_info and info_attest != "production":
        raise CandidateError(f"{role} App Attest runtime configuration is not production")
    if not expects_app_attest_info and info_attest is not None:
        raise CandidateError(f"{role} delegated-only runtime contains App Attest configuration")
    if any(FORBIDDEN_INFO_KEY.search(str(key)) for key in info):
        raise CandidateError(f"{role} Info.plist contains a forbidden credential-shaped key")
    if info.get("CFBundleIdentifier") != bundle_id:
        raise CandidateError(f"{role} bundle identifier does not match")
    if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build:
        raise CandidateError(f"{role} version/build does not match the host candidate")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name or "/" in executable_name:
        raise CandidateError(f"{role} executable name is invalid")
    executable = bundle / executable_name
    if not executable.is_file() or executable.is_symlink():
        raise CandidateError(f"{role} executable is missing or unsafe")
    if extension_point is not None:
        extension = info.get("NSExtension")
        if not isinstance(extension, dict) or extension.get("NSExtensionPointIdentifier") != extension_point:
            raise CandidateError(f"{role} extension point does not match")
        if role in {"share", "action"} and not extension.get("NSExtensionPrincipalClass"):
            raise CandidateError(f"{role} extension principal class is missing")

    entitlements = signed_entitlements(bundle)
    if entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise CandidateError(f"{role} Team ID does not match")
    if entitlements.get("application-identifier") != f"{app_id_prefix}.{bundle_id}":
        raise CandidateError(f"{role} application identifier does not match")
    if entitlements.get("get-task-allow") not in {None, False}:
        raise CandidateError(f"{role} candidate is debuggable")
    groups = entitlements.get("keychain-access-groups")
    if not isinstance(groups, list) or len(groups) != len(set(groups)) or set(groups) != expected_groups:
        raise CandidateError(f"{role} Keychain groups do not prove the required isolation")
    attest_value = entitlements.get("com.apple.developer.devicecheck.appattest-environment")
    if app_attest and attest_value != "production":
        raise CandidateError(f"{role} requires its own production App Attest entitlement")
    if not app_attest and attest_value is not None:
        raise CandidateError(f"{role} must remain delegated-only without App Attest entitlement")

    actual_certificate_sha256, certificate = signing_certificate(bundle, temporary)
    if actual_certificate_sha256 != certificate_sha256:
        raise CandidateError(f"{role} signing certificate does not match the external pin")

    profile_path = bundle / "embedded.mobileprovision"
    profile = embedded_profile(bundle)
    profile_uuid = profile.get("UUID")
    if profile_uuid != expected_profile_uuid:
        raise CandidateError(f"{role} provisioning profile UUID does not match the external pin")
    validated_profile_expiration(profile, role)
    if profile.get("ProvisionsAllDevices") is True or not profile.get("ProvisionedDevices"):
        raise CandidateError(f"{role} profile is not an installable ad hoc profile")
    profile_teams = profile.get("TeamIdentifier")
    if (
        not isinstance(profile_teams, list)
        or not all(isinstance(value, str) for value in profile_teams)
        or set(profile_teams) != {team_id}
    ):
        raise CandidateError(f"{role} profile Team ID does not match")
    profile_prefixes = profile.get("ApplicationIdentifierPrefix")
    if (
        not isinstance(profile_prefixes, list)
        or not all(isinstance(value, str) for value in profile_prefixes)
        or app_id_prefix not in profile_prefixes
    ):
        raise CandidateError(f"{role} profile App ID prefix does not match")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        raise CandidateError(f"{role} profile entitlements are missing")
    if profile_entitlements.get("application-identifier") != f"{app_id_prefix}.{bundle_id}":
        raise CandidateError(f"{role} profile application identifier does not match")
    if profile_entitlements.get("com.apple.developer.team-identifier") != team_id:
        raise CandidateError(f"{role} profile entitlement Team ID does not match")
    profile_groups = profile_entitlements.get("keychain-access-groups")
    if (
        not isinstance(profile_groups, list)
        or not profile_groups
        or not all(isinstance(group, str) and group for group in profile_groups)
        or len(profile_groups) != len(set(profile_groups))
        or any(
            not any(profile_group_authorizes(profile_group, signed_group) for profile_group in profile_groups)
            for signed_group in expected_groups
        )
    ):
        raise CandidateError(f"{role} profile does not authorize the signed Keychain groups")
    if profile_entitlements.get("get-task-allow") is not False:
        raise CandidateError(f"{role} profile permits debugging")
    if app_attest and profile_entitlements.get(
        "com.apple.developer.devicecheck.appattest-environment"
    ) != "production":
        raise CandidateError(f"{role} profile does not authorize production App Attest")
    profile_certificates = profile.get("DeveloperCertificates")
    if not isinstance(profile_certificates, list) or certificate not in profile_certificates:
        raise CandidateError(f"{role} profile does not authorize the signing certificate")

    return {
        "binary_sha256": sha256(executable),
        "bundle_identifier": bundle_id,
        "entitlements_sha256": hashlib.sha256(
            plistlib.dumps(entitlements, fmt=plistlib.FMT_BINARY, sort_keys=True)
        ).hexdigest(),
        "executable": executable_name,
        "profile_sha256": sha256(profile_path),
        "profile_uuid": profile_uuid,
        "signing_certificate_sha256": actual_certificate_sha256,
    }


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} SIGNED_APP OUTPUT_JSON", file=sys.stderr)
        return 64
    raw_app = pathlib.Path(sys.argv[1])
    raw_output = pathlib.Path(sys.argv[2])
    if raw_app.is_symlink() or raw_output.is_symlink():
        raise CandidateError("candidate paths must not be symbolic links")
    app = raw_app.resolve()
    output = raw_output.resolve()
    if app.suffix != ".app":
        raise CandidateError("signed candidate path must end in .app")
    if output.exists() or not output.parent.is_dir() or output.parent.is_symlink():
        raise CandidateError("metadata output must not already exist and its parent must exist")
    if output == app or app in output.parents:
        raise CandidateError("metadata output must remain outside the signed application")
    staged_app_path = required("LATCHWAY_IOS_STAGED_APP_PATH")
    staged_app = pathlib.Path(staged_app_path)
    if (
        not staged_app.is_absolute()
        or staged_app.name != "AppAttestConformance.app"
        or ".." in staged_app.parts
    ):
        raise CandidateError("protected staged application path is not canonical")

    team_id = required("LATCHWAY_IOS_TEAM_ID", re.compile(r"^[A-Z0-9]{10}$"))
    app_id_prefix = required("LATCHWAY_IOS_APP_ID_PREFIX", re.compile(r"^[A-Z0-9]{10}$"))
    expected_certificate = required("LATCHWAY_IOS_EXPECTED_SIGNING_CERTIFICATE_SHA256", SHA256)
    version = required("LATCHWAY_IOS_APP_VERSION", re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$"))
    build = required("LATCHWAY_IOS_BUILD_NUMBER", re.compile(r"^[0-9]{1,18}$"))
    source_commit = required("LATCHWAY_SOURCE_COMMIT", re.compile(r"^[0-9a-f]{40}$"))
    source_tree = required("LATCHWAY_SOURCE_TREE", re.compile(r"^[0-9a-f]{40,64}$"))
    xcode_identity = required("LATCHWAY_XCODE_IDENTITY")
    if required("LATCHWAY_IOS_DISTRIBUTION") != "ad_hoc":
        raise CandidateError("this side-loadable physical-device producer requires ad_hoc distribution")
    try:
        bundle_tree = app_bundle_tree_digest(app)
    except BundleTreeError as error:
        raise CandidateError(str(error)) from error

    identifiers = {
        "host": required("LATCHWAY_IOS_BUNDLE_ID", BUNDLE_ID),
        "widget": required("LATCHWAY_IOS_WIDGET_BUNDLE_ID", BUNDLE_ID),
        "share": required("LATCHWAY_IOS_SHARE_BUNDLE_ID", BUNDLE_ID),
        "action": required("LATCHWAY_IOS_ACTION_BUNDLE_ID", BUNDLE_ID),
    }
    definitions = {
        "host": required("LATCHWAY_HOST_COMPONENT_DEFINITION_ID", DEFINITION_ID),
        "widget": required("LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID", DEFINITION_ID),
        "share": required("LATCHWAY_SHARE_COMPONENT_DEFINITION_ID", DEFINITION_ID),
        "action": required("LATCHWAY_ACTION_COMPONENT_DEFINITION_ID", DEFINITION_ID),
    }
    if len(set(identifiers.values())) != 4 or len(set(definitions.values())) != 4:
        raise CandidateError("component bundle and definition identifiers must be distinct")

    profile_uuids = {
        role: required(f"LATCHWAY_IOS_{role.upper()}_PROVISIONING_PROFILE_UUID", PROFILE_UUID)
        for role in identifiers
    }
    access_groups = {role: f"{app_id_prefix}.{bundle_id}" for role, bundle_id in identifiers.items()}
    plugins = app / "PlugIns"
    if not plugins.is_dir() or plugins.is_symlink():
        raise CandidateError("candidate PlugIns directory is missing or unsafe")
    extension_bundles = [item for item in plugins.glob("*.appex") if item.is_dir() and not item.is_symlink()]
    if len(extension_bundles) != 3:
        raise CandidateError("candidate must embed exactly one Widget, Share, and Action extension")
    by_identifier: dict[str, pathlib.Path] = {}
    for bundle in extension_bundles:
        identifier = load_plist(bundle / "Info.plist").get("CFBundleIdentifier")
        if not isinstance(identifier, str) or identifier in by_identifier:
            raise CandidateError("embedded extension identifiers are invalid or duplicated")
        by_identifier[identifier] = bundle
    if set(by_identifier) != {identifiers["widget"], identifiers["share"], identifiers["action"]}:
        raise CandidateError("embedded extension set does not match the external pins")

    application_id = required(
        "LATCHWAY_APPLICATION_ID", re.compile(r"^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$")
    )
    environment = required("LATCHWAY_ENVIRONMENT", DEFINITION_ID)
    identity_provider = required("LATCHWAY_IDENTITY_PROVIDER", DEFINITION_ID)
    gateway_origin = required(
        "LATCHWAY_GATEWAY_ORIGIN",
        re.compile(r"^https://[^/?#\s]+(?:/[A-Za-z0-9_~.-]+)*$"),
    )
    expected_info = {
        "LatchwayActionBundleID": identifiers["action"],
        "LatchwayActionComponentDefinitionID": definitions["action"],
        "LatchwayActionFeature": required("LATCHWAY_ACTION_FEATURE", DEFINITION_ID),
        "LatchwayActionKeychainAccessGroup": access_groups["action"],
        "LatchwayApplicationID": application_id,
        "LatchwayEnvironment": environment,
        "LatchwayIdentityProvider": identity_provider,
        "LatchwayGatewayURL": gateway_origin,
        "LatchwayHostComponentDefinitionID": definitions["host"],
        "LatchwayShareBundleID": identifiers["share"],
        "LatchwayShareComponentDefinitionID": definitions["share"],
        "LatchwayShareFeature": required("LATCHWAY_SHARE_FEATURE", DEFINITION_ID),
        "LatchwayShareKeychainAccessGroup": access_groups["share"],
        "LatchwayWidgetBundleID": identifiers["widget"],
        "LatchwayWidgetComponentDefinitionID": definitions["widget"],
        "LatchwayWidgetFeature": required("LATCHWAY_WIDGET_FEATURE", DEFINITION_ID),
        "LatchwayWidgetKeychainAccessGroup": access_groups["widget"],
    }
    host_info = load_plist(app / "Info.plist")
    if any(host_info.get(key) != value for key, value in expected_info.items()):
        raise CandidateError("embedded non-secret component/gateway configuration does not match")
    if any(FORBIDDEN_INFO_KEY.search(str(key)) for key in host_info):
        raise CandidateError("host Info.plist contains a forbidden credential-shaped key")

    with tempfile.TemporaryDirectory(prefix="latchway-ios-candidate-inspection.") as temporary_name:
        temporary = pathlib.Path(temporary_name)
        artifacts = {
            "host": require_candidate_identity(
                app,
                role="host",
                bundle_id=identifiers["host"],
                extension_point=None,
                expected_groups=set(access_groups.values()),
                app_attest=True,
                expected_profile_uuid=profile_uuids["host"],
                team_id=team_id,
                app_id_prefix=app_id_prefix,
                version=version,
                build=build,
                certificate_sha256=expected_certificate,
                temporary=temporary,
                expected_info=expected_info,
                expects_app_attest_info=True,
            ),
            "widget": require_candidate_identity(
                by_identifier[identifiers["widget"]],
                role="widget",
                bundle_id=identifiers["widget"],
                extension_point="com.apple.widgetkit-extension",
                expected_groups={access_groups["widget"]},
                app_attest=False,
                expected_profile_uuid=profile_uuids["widget"],
                team_id=team_id,
                app_id_prefix=app_id_prefix,
                version=version,
                build=build,
                certificate_sha256=expected_certificate,
                temporary=temporary,
                expected_info=expected_info,
                expects_app_attest_info=False,
            ),
            "share": require_candidate_identity(
                by_identifier[identifiers["share"]],
                role="share",
                bundle_id=identifiers["share"],
                extension_point="com.apple.share-services",
                expected_groups={access_groups["share"]},
                app_attest=False,
                expected_profile_uuid=profile_uuids["share"],
                team_id=team_id,
                app_id_prefix=app_id_prefix,
                version=version,
                build=build,
                certificate_sha256=expected_certificate,
                temporary=temporary,
                expected_info=expected_info,
                expects_app_attest_info=False,
            ),
            "action": require_candidate_identity(
                by_identifier[identifiers["action"]],
                role="action",
                bundle_id=identifiers["action"],
                extension_point="com.apple.ui-services",
                expected_groups={access_groups["action"]},
                app_attest=False,
                expected_profile_uuid=profile_uuids["action"],
                team_id=team_id,
                app_id_prefix=app_id_prefix,
                version=version,
                build=build,
                certificate_sha256=expected_certificate,
                temporary=temporary,
                expected_info=expected_info,
                expects_app_attest_info=False,
            ),
        }

    protected_inputs = {
        "LATCHWAY_ACTION_COMPONENT_DEFINITION_ID": definitions["action"],
        "LATCHWAY_APPLICATION_ID": application_id,
        "LATCHWAY_BASE_URL": gateway_origin,
        "LATCHWAY_ENVIRONMENT": environment,
        "LATCHWAY_IDENTITY_PROVIDER": identity_provider,
        "LATCHWAY_GATEWAY_ORIGIN": gateway_origin,
        "LATCHWAY_HOST_COMPONENT_DEFINITION_ID": definitions["host"],
        "LATCHWAY_IOS_ACTION_BINARY_SHA256": artifacts["action"]["binary_sha256"],
        "LATCHWAY_IOS_ACTION_BUNDLE_ID": identifiers["action"],
        "LATCHWAY_IOS_APP_BINARY_SHA256": artifacts["host"]["binary_sha256"],
        "LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256": bundle_tree.sha256,
        "LATCHWAY_IOS_APP_BUNDLE_PATH": staged_app_path,
        "LATCHWAY_IOS_APP_VERSION": version,
        "LATCHWAY_IOS_APP_ID_PREFIX": app_id_prefix,
        "LATCHWAY_IOS_BUILD_NUMBER": build,
        "LATCHWAY_IOS_BUNDLE_ID": identifiers["host"],
        "LATCHWAY_IOS_DISTRIBUTION": "ad_hoc",
        "LATCHWAY_IOS_INSTALL_MODE": "install",
        "LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID": profile_uuids["host"],
        "LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_UUID": profile_uuids["widget"],
        "LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_UUID": profile_uuids["share"],
        "LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID": profile_uuids["action"],
        "LATCHWAY_IOS_SHARE_BINARY_SHA256": artifacts["share"]["binary_sha256"],
        "LATCHWAY_IOS_SHARE_BUNDLE_ID": identifiers["share"],
        "LATCHWAY_IOS_SIGNING_CERTIFICATE_SHA256": expected_certificate,
        "LATCHWAY_IOS_TEAM_ID": team_id,
        "LATCHWAY_IOS_WIDGET_BINARY_SHA256": artifacts["widget"]["binary_sha256"],
        "LATCHWAY_IOS_WIDGET_BUNDLE_ID": identifiers["widget"],
        "LATCHWAY_SHARE_COMPONENT_DEFINITION_ID": definitions["share"],
        "LATCHWAY_SOURCE_COMMIT": source_commit,
        "LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID": definitions["widget"],
        "LATCHWAY_XCODE_IDENTITY": xcode_identity,
    }
    manifest = {
        "schema_version": "latchway.ios-app-attest-candidate.v1",
        "release_eligible_build": True,
        "source": {"commit": source_commit, "tree": source_tree, "worktree_clean": True},
        "build": {
            "app_attest_environment": "production",
            "configuration": "Release",
            "distribution": "ad_hoc",
            "xcode_identity": xcode_identity,
        },
        "configuration": {
            "application_id": application_id,
            "environment": environment,
            "identity_provider": identity_provider,
        },
        "artifacts": artifacts,
        "app_bundle_tree": bundle_tree.as_dict(),
        "protected_inputs": protected_inputs,
    }
    encoded = json.dumps(manifest, allow_nan=False, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    if FORBIDDEN_INFO_KEY.search(encoded):
        # Only key names in the allowlisted hash fields may resemble a signing
        # credential. Runtime identity/session tokens are never accepted here.
        if any(term in encoded.lower() for term in ("identity_token", "device_grant", "access_token", "refresh_token", "private_key")):
            raise CandidateError("candidate metadata contains forbidden credential material")
    output.write_text(encoded, encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CandidateError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
