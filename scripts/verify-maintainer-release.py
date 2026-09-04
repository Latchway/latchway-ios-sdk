#!/usr/bin/env python3
"""Verify an explicit single-maintainer v1 publication request.

This is an additive publication path, not a substitute for the strict
cross-repository promotion verifier.  It binds a manual dispatch to the exact
main commit and checked-in release locks, and emits an honest maintainer-intent
record whose deferred assurance is explicit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
PROFILE = "single_maintainer_v1"
VERSION = "1.0.0"
TAG = "v1.0.0"
CONFIRMATION = "publish-v1.0.0-with-deferred-assurance"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
MAXIMUM_JSON_BYTES = 1024 * 1024
MAXIMUM_JSON_SAFE_INTEGER = 9_007_199_254_740_991
REPOSITORIES = {
    "javascript": ("latchway-js", "Latchway/latchway-js"),
    "ios": ("latchway-ios-sdk", "Latchway/latchway-ios-sdk"),
    "react_native": (
        "latchway-react-native-sdk",
        "Latchway/latchway-react-native-sdk",
    ),
}
DEFERRED_EVIDENCE = [
    "independent_human_review",
    "live_sdk_conformance",
    "physical_devices",
    "apple_distribution_and_extensions",
    "play_integrity_and_android_device",
    "firebase_app_check",
    "turnstile",
    "live_provider",
    "cloud_deployments",
    "operational_resilience",
    "public_registries.documentation_production_verified",
    "mintlify_production",
]
FORBIDDEN_CLAIMS = [
    "release_qualified",
    "fully_evidence_gated",
    "independently_reviewed",
]


class Rejected(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def git(*arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(ROOT), *arguments], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        raise Rejected("maintainer_release_git_invalid") from None
    return result.stdout.strip()


def strict_json(path: Path) -> dict[str, Any]:
    try:
        metadata = path.lstat()
        if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAXIMUM_JSON_BYTES:
            raise Rejected("maintainer_release_metadata_invalid")
        def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
            value: dict[str, Any] = {}
            for key, item in pairs:
                if key in value:
                    raise Rejected("maintainer_release_metadata_duplicate_key")
                value[key] = item
            return value
        def integer(source: str) -> int:
            value = int(source)
            if abs(value) > MAXIMUM_JSON_SAFE_INTEGER:
                raise Rejected("maintainer_release_metadata_invalid")
            return value
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=object_pairs,
            parse_int=integer, parse_constant=lambda _value: (_ for _ in ()).throw(Rejected("maintainer_release_metadata_invalid")))
    except Rejected:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        raise Rejected("maintainer_release_metadata_invalid") from None
    if not isinstance(value, dict):
        raise Rejected("maintainer_release_metadata_invalid")
    return value


def contract_lock() -> dict[str, str]:
    path = ROOT / "contract.lock"
    try:
        metadata = path.lstat()
        if path.is_symlink() or not stat.S_ISREG(metadata.st_mode):
            raise Rejected("maintainer_release_contract_lock_invalid")
        values: dict[str, str] = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.fullmatch(r"([a-z0-9_]+):\s*(?:\"([^\"]*)\"|([^\s]+))", line)
            if match is None or match.group(1) in values:
                raise Rejected("maintainer_release_contract_lock_invalid")
            values[match.group(1)] = match.group(2) or match.group(3)
    except Rejected:
        raise
    except (OSError, UnicodeDecodeError):
        raise Rejected("maintainer_release_contract_lock_invalid") from None
    required = {"contract_version", "wire_protocol", "core_release", "core_commit", "bundle_sha256", "minimum_server_version", "maximum_tested_server_version"}
    if set(values) != required or values["contract_version"] != VERSION or values["wire_protocol"] != "2" or values["core_release"] != TAG or COMMIT.fullmatch(values["core_commit"]) is None or SHA256.fullmatch(values["bundle_sha256"]) is None:
        raise Rejected("maintainer_release_contract_lock_invalid")
    return values


def require_package(path: Path, name: str) -> None:
    package = strict_json(path)
    if package.get("name") != name or package.get("version") != VERSION:
        raise Rejected("maintainer_release_local_version_invalid")


def repository_coordinates(repository_id: str) -> dict[str, str]:
    if repository_id == "javascript":
        require_package(ROOT / "package.json", "@latchway/client")
        require_package(ROOT / "packages/openai/package.json", "@latchway/openai")
        require_package(ROOT / "packages/vercel-ai/package.json", "@latchway/vercel-ai")
        require_package(ROOT / "packages/langchain/package.json", "@latchway/langchain")
        return {}
    if repository_id == "ios":
        try:
            swift = (ROOT / "Sources/Latchway/LatchwayVersion.swift").read_text(encoding="utf-8")
            podspec = (ROOT / "Latchway.podspec").read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            raise Rejected("maintainer_release_local_version_invalid") from None
        if re.search(r'\bsdk\s*=\s*"1\.0\.0"', swift) is None or re.search(r"\b(?:s|spec)\.version\s*=\s*['\"]1\.0\.0['\"]", podspec) is None:
            raise Rejected("maintainer_release_local_version_invalid")
        return {}
    require_package(ROOT / "package.json", "@latchway/react-native")
    lock = strict_json(ROOT / "release-compatibility.json")
    try:
        contract, javascript, ios, android, react_native = lock["contract"], lock["javascript"], lock["ios"], lock["android"], lock["react_native"]
        expected = {"core_commit": contract["core_commit"], "contract_version": contract["version"], "javascript_commit": javascript["source_commit"], "javascript_version": javascript["version"], "ios_commit": ios["source_commit"], "ios_version": ios["version"], "android_commit": android["source_commit"], "android_version": android["version"], "react_native_version": react_native["version"]}
    except (KeyError, TypeError):
        raise Rejected("maintainer_release_compatibility_lock_invalid") from None
    if contract.get("repository") != "https://github.com/Latchway/latchway.git" or javascript.get("package") != "@latchway/client" or javascript.get("repository") != "https://github.com/Latchway/latchway-js.git" or ios.get("pod") != "Latchway/AppAttest" or ios.get("repository") != "https://github.com/Latchway/latchway-ios-sdk.git" or android.get("group") != "dev.latchway" or android.get("repository") != "https://github.com/Latchway/latchway-android.git" or react_native.get("package") != "@latchway/react-native" or expected["contract_version"] != VERSION or expected["react_native_version"] != VERSION or any(COMMIT.fullmatch(expected[key]) is None for key in ("core_commit", "javascript_commit", "ios_commit", "android_commit")) or any(expected[key] != VERSION for key in ("javascript_version", "ios_version", "android_version")):
        raise Rejected("maintainer_release_compatibility_lock_invalid")
    return expected


def positive_run_number(value: str) -> int:
    if not re.fullmatch(r"[1-9][0-9]{0,15}", value) or int(value) > MAXIMUM_JSON_SAFE_INTEGER:
        raise Rejected("maintainer_release_run_identity_invalid")
    return int(value)


def write_intent(path: Path, value: Mapping[str, Any]) -> str:
    payload = (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and (path.is_symlink() or not path.is_file()):
            raise Rejected("maintainer_release_intent_output_invalid")
        temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
        temporary.write_bytes(payload)
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    except Rejected:
        raise
    except OSError:
        raise Rejected("maintainer_release_intent_output_invalid") from None
    return hashlib.sha256(payload).hexdigest()


def append_outputs(path: Path, values: Mapping[str, str]) -> None:
    try:
        with path.open("a", encoding="utf-8") as output:
            for key in sorted(values):
                value = values[key]
                if "\n" in value or "\r" in value:
                    raise Rejected("maintainer_release_output_invalid")
                output.write(f"{key}={value}\n")
    except Rejected:
        raise
    except OSError:
        raise Rejected("maintainer_release_output_invalid") from None


def verify(arguments: argparse.Namespace) -> dict[str, str]:
    expected_directory, expected_repository = REPOSITORIES.get(arguments.repository_id, (None, None))
    if expected_directory is None or ROOT.name != expected_directory or arguments.repository_name != expected_repository or arguments.profile != PROFILE or arguments.release_version != VERSION or arguments.release_commit != arguments.workflow_commit or COMMIT.fullmatch(arguments.release_commit) is None or arguments.workflow_ref != "refs/heads/main" or arguments.confirmation != CONFIRMATION:
        raise Rejected("maintainer_release_dispatch_invalid")
    if git("rev-parse", "--verify", "HEAD") != arguments.release_commit:
        raise Rejected("maintainer_release_commit_mismatch")
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise Rejected("maintainer_release_worktree_dirty")
    contract = contract_lock()
    coordinates = repository_coordinates(arguments.repository_id)
    if coordinates.get("core_commit", contract["core_commit"]) != contract["core_commit"]:
        raise Rejected("maintainer_release_core_lock_mismatch")
    intent = {"schema_version": 1, "kind": "latchway_single_maintainer_release_intent", "profile": PROFILE, "status": "maintainer_requested", "status_claim": "v1_publication_in_progress_with_deferred_assurance", "publication_ready": False, "release_qualified": False, "requires_independent_human_review": False, "source": {"repository": arguments.repository_name, "commit": arguments.release_commit, "version": VERSION, "tag": TAG, "ref": arguments.workflow_ref}, "contract": {"core_commit": contract["core_commit"], "core_tag": contract["core_release"], "bundle_sha256": contract["bundle_sha256"], "wire_protocol": 2}, "workflow": {"file": ".github/workflows/single-maintainer-release.yml", "event": "workflow_dispatch", "run_id": positive_run_number(arguments.run_id), "run_attempt": positive_run_number(arguments.run_attempt)}, "maintainer_confirmation": "accepted_exact_phrase", "deferred_evidence": DEFERRED_EVIDENCE, "forbidden_claims": FORBIDDEN_CLAIMS, "downstream_required_gates": ["annotated_tag_exact_commit", "complete_local_release_tests", "deterministic_package_archives", "registry_byte_verification", "trusted_publication_provenance", "exact_github_release"]}
    digest = write_intent(arguments.intent_output, intent)
    return {
        "commit": arguments.release_commit,
        "core_commit": contract["core_commit"],
        "core_tag": contract["core_release"],
        "intent_sha256": digest,
        "tag": TAG,
        "version": VERSION,
        **coordinates,
    }


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    for name in ("repository-id", "repository-name", "profile", "release-commit", "release-version", "workflow-commit", "workflow-ref", "run-id", "run-attempt", "confirmation"):
        result.add_argument(f"--{name}", required=True)
    result.add_argument("--intent-output", type=Path, required=True)
    result.add_argument("--github-output", type=Path)
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        outputs = verify(arguments)
        if arguments.github_output is not None:
            append_outputs(arguments.github_output, outputs)
    except Rejected as error:
        print(f"single-maintainer release rejected: {error.code}", file=sys.stderr)
        return 1
    print(json.dumps(outputs, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
