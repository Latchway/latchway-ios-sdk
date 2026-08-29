#!/usr/bin/env python3
"""Create or resume an immutable GitHub release without overwriting assets."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import quote


REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TAG = re.compile(r"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")
MAXIMUM_ASSET_BYTES = 2 * 1024 * 1024 * 1024
MAXIMUM_ATTESTATION_JSON_BYTES = 16 * 1024 * 1024
RELEASE_PREDICATE_TYPE = "https://in-toto.io/attestation/release/v0.2"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"


class Rejected(RuntimeError):
    """The existing public release differs from the intended immutable state."""


@dataclass(frozen=True)
class Asset:
    path: Path
    name: str
    size: int
    sha256: str


class Client(Protocol):
    def immutable_releases_enabled(self, repository: str) -> bool: ...

    def release(self, repository: str, tag: str) -> dict[str, Any] | None: ...

    def validate_remote_tag(self, repository: str, tag: str, expected_commit: str) -> None: ...

    def create(self, repository: str, tag: str, title: str, prerelease: bool) -> None: ...

    def download(self, repository: str, asset_id: int, destination: Path) -> None: ...

    def upload(self, repository: str, tag: str, path: Path) -> None: ...

    def finalize(self, repository: str, tag: str, prerelease: bool) -> None: ...

    def verify_release_attestation(
        self,
        repository: str,
        tag: str,
        expected_commit: str,
        assets: list[Asset],
    ) -> None: ...


class GitHubClient:
    def immutable_releases_enabled(self, repository: str) -> bool:
        # Consume the protected credential for this one read-only settings
        # request, then remove it before any release mutation subprocess runs.
        token = os.environ.pop("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", "")
        if not token or any(character in token for character in "\x00\r\n"):
            raise RuntimeError("The protected immutable-release settings credential is missing.")
        environment = os.environ.copy()
        environment["GH_TOKEN"] = token
        result = subprocess.run(
            [
                "gh", "api",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                f"repos/{repository}/immutable-releases",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=environment,
        )
        if result.returncode != 0:
            return False
        try:
            value = _strict_json_loads(result.stdout)
        except (json.JSONDecodeError, ValueError):
            return False
        return (
            isinstance(value, dict)
            and set(value) == {"enabled", "enforced_by_owner"}
            and value.get("enabled") is True
            and isinstance(value.get("enforced_by_owner"), bool)
        )

    def validate_remote_tag(self, repository: str, tag: str, expected_commit: str) -> None:
        encoded_tag = quote(tag, safe="")
        reference = _gh_json(
            [
                "gh", "api",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                f"repos/{repository}/git/ref/tags/{encoded_tag}",
            ],
            "GitHub annotated tag reference lookup",
        )
        tag_object = reference.get("object")
        if (
            reference.get("ref") != f"refs/tags/{tag}"
            or not isinstance(tag_object, dict)
            or tag_object.get("type") != "tag"
            or not isinstance(tag_object.get("sha"), str)
            or OBJECT_ID.fullmatch(tag_object["sha"]) is None
        ):
            raise Rejected("Remote release tag is not the expected annotated tag object.")
        annotated = _gh_json(
            [
                "gh", "api",
                "-H", "Accept: application/vnd.github+json",
                "-H", "X-GitHub-Api-Version: 2026-03-10",
                f"repos/{repository}/git/tags/{tag_object['sha']}",
            ],
            "GitHub annotated tag object lookup",
        )
        target = annotated.get("object")
        if (
            annotated.get("tag") != tag
            or not isinstance(target, dict)
            or target.get("type") != "commit"
            or target.get("sha") != expected_commit
        ):
            raise Rejected("Remote annotated release tag does not identify the promoted commit.")

    def release(self, repository: str, tag: str) -> dict[str, Any] | None:
        endpoint = f"repos/{repository}/releases/tags/{quote(tag, safe='')}"
        result = subprocess.run(
            ["gh", "api", "-H", "X-GitHub-Api-Version: 2026-03-10", endpoint],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode != 0:
            if re.search(r"(?:HTTP\s+404|404\s+Not Found|release not found)", result.stderr, re.IGNORECASE):
                return None
            raise RuntimeError(f"GitHub release lookup failed: {result.stderr.strip()}")
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise RuntimeError("GitHub returned invalid release JSON.") from error
        if not isinstance(value, dict):
            raise RuntimeError("GitHub returned an invalid release document.")
        return value

    def create(self, repository: str, tag: str, title: str, prerelease: bool) -> None:
        arguments = [
            "gh", "release", "create", tag,
            "--repo", repository,
            "--verify-tag",
            "--draft",
            "--generate-notes",
            "--title", title,
        ]
        if prerelease:
            arguments.append("--prerelease")
        _run(arguments, "GitHub draft release creation")

    def download(self, repository: str, asset_id: int, destination: Path) -> None:
        endpoint = f"repos/{repository}/releases/assets/{asset_id}"
        with destination.open("wb") as output:
            result = subprocess.run(
                ["gh", "api", "--method", "GET", "-H", "Accept: application/octet-stream", endpoint],
                check=False,
                stdout=output,
                stderr=subprocess.PIPE,
            )
        if result.returncode != 0:
            raise RuntimeError(f"GitHub release asset download failed: {result.stderr.decode(errors='replace').strip()}")

    def upload(self, repository: str, tag: str, path: Path) -> None:
        # Deliberately omit --clobber. Existing assets are downloaded and
        # verified before this method is called; immutable bytes are never replaced.
        _run(
            ["gh", "release", "upload", tag, str(path), "--repo", repository],
            "GitHub release asset upload",
        )

    def finalize(self, repository: str, tag: str, prerelease: bool) -> None:
        arguments = ["gh", "release", "edit", tag, "--repo", repository, "--draft=false"]
        if prerelease:
            arguments.append("--prerelease")
        else:
            arguments.extend(["--prerelease=false", "--latest"])
        _run(arguments, "GitHub release finalization")

    def verify_release_attestation(
        self,
        repository: str,
        tag: str,
        expected_commit: str,
        assets: list[Asset],
    ) -> None:
        attempts, delay = _attestation_retry_policy()
        release_json = _run_json_with_retries(
            ["gh", "release", "verify", tag, "--repo", repository, "--format", "json"],
            "GitHub immutable release attestation verification",
            attempts,
            delay,
        )
        _validate_release_attestation(
            release_json,
            repository=repository,
            tag=tag,
            expected_commit=expected_commit,
            assets=assets,
        )
        for asset in assets:
            asset_json = _run_json_with_retries(
                [
                    "gh", "release", "verify-asset", tag, str(asset.path),
                    "--repo", repository, "--format", "json",
                ],
                f"GitHub immutable release asset attestation verification ({asset.name})",
                attempts,
                delay,
            )
            _validate_release_attestation(
                asset_json,
                repository=repository,
                tag=tag,
                expected_commit=expected_commit,
                assets=assets,
            )


def _run(arguments: list[str], operation: str) -> None:
    result = subprocess.run(arguments, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{operation} failed: {result.stderr.strip()}")


def _unique_json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"invalid JSON constant: {value}")


def _strict_json_loads(document: str) -> Any:
    return json.loads(
        document,
        object_pairs_hook=_unique_json_object,
        parse_constant=_reject_json_constant,
    )


def _gh_json(arguments: list[str], operation: str) -> dict[str, Any]:
    result = subprocess.run(
        arguments,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{operation} failed: {result.stderr.strip()}")
    if not result.stdout or len(result.stdout.encode("utf-8")) > MAXIMUM_ATTESTATION_JSON_BYTES:
        raise RuntimeError(f"{operation} returned an empty or oversized JSON document.")
    try:
        value = _strict_json_loads(result.stdout)
    except (json.JSONDecodeError, ValueError) as error:
        raise RuntimeError(f"{operation} returned invalid JSON.") from error
    if not isinstance(value, dict) or not value:
        raise RuntimeError(f"{operation} returned an invalid JSON object.")
    return value


def _attestation_retry_policy() -> tuple[int, int]:
    attempts_text = os.environ.get("LATCHWAY_GITHUB_RELEASE_ATTESTATION_ATTEMPTS", "12")
    delay_text = os.environ.get("LATCHWAY_GITHUB_RELEASE_ATTESTATION_DELAY_SECONDS", "10")
    if not attempts_text.isdigit() or not delay_text.isdigit():
        raise RuntimeError("GitHub release attestation retry settings are invalid.")
    attempts = int(attempts_text)
    delay = int(delay_text)
    if not 1 <= attempts <= 30 or not 1 <= delay <= 60:
        raise RuntimeError("GitHub release attestation retry settings are invalid.")
    return attempts, delay


def _run_json_with_retries(
    arguments: list[str],
    operation: str,
    attempts: int,
    delay: int,
) -> dict[str, Any]:
    last_error = ""
    for attempt in range(1, attempts + 1):
        result = subprocess.run(
            arguments,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode == 0:
            if not result.stdout or len(result.stdout.encode("utf-8")) > MAXIMUM_ATTESTATION_JSON_BYTES:
                raise RuntimeError(f"{operation} returned empty or oversized JSON.")
            try:
                value = _strict_json_loads(result.stdout)
            except (json.JSONDecodeError, ValueError) as error:
                raise RuntimeError(f"{operation} returned invalid JSON.") from error
            if not isinstance(value, dict) or not value:
                raise RuntimeError(f"{operation} returned an invalid JSON object.")
            return value
        last_error = result.stderr.strip()
        if attempt < attempts:
            time.sleep(delay)
    raise RuntimeError(f"{operation} failed after {attempts} attempts: {last_error}")


def _validate_release_attestation(
    value: dict[str, Any],
    *,
    repository: str,
    tag: str,
    expected_commit: str,
    assets: list[Asset],
) -> None:
    if set(value) != {"attestation", "verificationResult"}:
        raise Rejected("GitHub release attestation JSON has an unexpected top-level schema.")
    attestation = value.get("attestation")
    verification_result = value.get("verificationResult")
    if not isinstance(attestation, dict) or not attestation:
        raise Rejected("GitHub release attestation JSON has no attestation.")
    if not isinstance(verification_result, dict) or not verification_result:
        raise Rejected("GitHub release attestation JSON has no verification result.")
    bundle = attestation.get("bundle")
    envelope = bundle.get("dsseEnvelope") if isinstance(bundle, dict) else None
    payload = envelope.get("payload") if isinstance(envelope, dict) else None
    if not isinstance(payload, str) or not payload:
        raise Rejected("GitHub release attestation has no signed DSSE payload.")
    try:
        statement_bytes = base64.b64decode(payload, validate=True)
    except (ValueError, binascii.Error) as error:
        raise Rejected("GitHub release attestation DSSE payload is not valid base64.") from error
    if not statement_bytes or len(statement_bytes) > MAXIMUM_ATTESTATION_JSON_BYTES:
        raise Rejected("GitHub release attestation statement has an invalid size.")
    try:
        statement = _strict_json_loads(statement_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
        raise Rejected("GitHub release attestation statement is invalid JSON.") from error
    if (
        not isinstance(statement, dict)
        or set(statement) != {"_type", "subject", "predicateType", "predicate"}
        or statement.get("_type") != STATEMENT_TYPE
        or statement.get("predicateType") != RELEASE_PREDICATE_TYPE
        or not isinstance(statement.get("predicate"), dict)
        or not statement["predicate"]
    ):
        raise Rejected("GitHub release attestation statement schema is invalid.")
    subjects = statement.get("subject")
    if not isinstance(subjects, list) or not subjects:
        raise Rejected("GitHub release attestation has no subjects.")
    expected_repository_purl = f"pkg:github/{repository}"
    release_matches: list[dict[str, str]] = []
    asset_subjects: dict[str, dict[str, str]] = {}
    for subject in subjects:
        if not isinstance(subject, dict) or not isinstance(subject.get("digest"), dict):
            raise Rejected("GitHub release attestation contains an invalid subject.")
        digest = subject["digest"]
        if not digest or any(
            not isinstance(key, str) or not isinstance(item, str)
            for key, item in digest.items()
        ):
            raise Rejected("GitHub release attestation contains an invalid subject digest.")
        if set(subject) == {"uri", "digest"}:
            uri = subject.get("uri")
            purl_parts = uri.rsplit("@", 1) if isinstance(uri, str) else []
            if (
                not isinstance(uri, str)
                or len(purl_parts) != 2
                or purl_parts[0].casefold() != expected_repository_purl.casefold()
                or purl_parts[1] != tag
                or release_matches
            ):
                raise Rejected("GitHub release attestation contains an invalid release subject.")
            release_matches.append(digest)
        elif set(subject) == {"name", "digest"}:
            name = subject.get("name")
            if not isinstance(name, str) or not name or name in asset_subjects:
                raise Rejected("GitHub release attestation contains an invalid asset subject.")
            asset_subjects[name] = digest
        else:
            raise Rejected("GitHub release attestation contains an unexpected subject schema.")

    if release_matches != [{"sha1": expected_commit}]:
        raise Rejected("GitHub release attestation is not bound to the promoted source commit.")
    if set(asset_subjects) != {asset.name for asset in assets}:
        raise Rejected("GitHub release attestation does not contain the exact release asset set.")
    for asset in assets:
        if asset_subjects.get(asset.name) != {"sha256": asset.sha256}:
            raise Rejected(
                f"GitHub release attestation does not bind the exact asset bytes for {asset.name}."
            )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_assets(paths: list[str]) -> list[Asset]:
    if not paths:
        raise Rejected("At least one release asset is required.")
    assets: list[Asset] = []
    names: set[str] = set()
    for raw_path in paths:
        path = Path(raw_path)
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
            raise Rejected(f"Release asset must be a regular file: {path}")
        if metadata.st_size <= 0 or metadata.st_size > MAXIMUM_ASSET_BYTES:
            raise Rejected(f"Release asset has an invalid size: {path}")
        name = path.name
        if name in {"", ".", ".."} or "/" in name or "\\" in name or name in names:
            raise Rejected(f"Release asset has an unsafe or duplicate name: {name}")
        names.add(name)
        digest = sha256_file(path)
        assets.append(Asset(path=path.resolve(), name=name, size=metadata.st_size, sha256=digest))
    return sorted(assets, key=lambda asset: asset.name)


def validate_release(
    release: dict[str, Any],
    *,
    tag: str,
    title: str,
    prerelease: bool,
    expected_assets: list[Asset],
    allow_draft: bool,
) -> dict[str, dict[str, Any]]:
    if release.get("tag_name") != tag:
        raise Rejected("Existing GitHub release tag does not match the promoted tag.")
    if release.get("name") != title:
        raise Rejected("Existing GitHub release title does not match the promoted release.")
    if release.get("prerelease") is not prerelease:
        raise Rejected("Existing GitHub release prerelease state does not match the promoted version.")
    if not isinstance(release.get("draft"), bool) or (release["draft"] and not allow_draft):
        raise Rejected("Existing GitHub release is not finalized.")
    if not isinstance(release.get("immutable"), bool):
        raise Rejected("Existing GitHub release has no immutable-state proof.")
    if release["draft"] and release["immutable"]:
        raise Rejected("A draft GitHub release cannot already be immutable.")
    if not release["draft"] and not release["immutable"]:
        raise Rejected("Published GitHub release is mutable.")
    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise Rejected("Existing GitHub release has an invalid asset list.")
    expected_names = {asset.name for asset in expected_assets}
    observed: dict[str, dict[str, Any]] = {}
    for raw_asset in raw_assets:
        if not isinstance(raw_asset, dict) or not isinstance(raw_asset.get("name"), str):
            raise Rejected("Existing GitHub release has invalid asset metadata.")
        name = raw_asset["name"]
        if name in observed:
            raise Rejected(f"Existing GitHub release has duplicate asset {name}.")
        if name not in expected_names:
            raise Rejected(f"Existing GitHub release has unexpected asset {name}.")
        if raw_asset.get("state") != "uploaded":
            raise Rejected(f"Existing GitHub release asset {name} is not fully uploaded.")
        if not isinstance(raw_asset.get("id"), int) or raw_asset["id"] <= 0:
            raise Rejected(f"Existing GitHub release asset {name} has an invalid identifier.")
        observed[name] = raw_asset
    return observed


def verify_remote_asset(client: Client, repository: str, local: Asset, remote: dict[str, Any]) -> None:
    if remote.get("size") != local.size:
        raise Rejected(f"Existing GitHub release asset {local.name} has different bytes.")
    advertised_digest = remote.get("digest")
    if advertised_digest not in (None, "", f"sha256:{local.sha256}"):
        raise Rejected(f"Existing GitHub release asset {local.name} has a different digest.")
    with tempfile.TemporaryDirectory(prefix="latchway-release-asset-") as temporary:
        downloaded = Path(temporary, local.name)
        client.download(repository, remote["id"], downloaded)
        metadata = downloaded.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size != local.size:
            raise Rejected(f"Existing GitHub release asset {local.name} downloaded with a different size.")
        digest = sha256_file(downloaded)
        if digest != local.sha256:
            raise Rejected(f"Existing GitHub release asset {local.name} is not byte-identical.")


def reconcile(
    *,
    repository: str,
    tag: str,
    expected_commit: str,
    title: str,
    prerelease: bool,
    assets: list[Asset],
    client: Client,
) -> None:
    if COMMIT.fullmatch(expected_commit) is None:
        raise Rejected("The expected promoted commit is not a canonical Git object ID.")
    # This admin-read preflight is intentionally first. Publishing a draft is
    # irreversible when immutable releases are disabled, so do not create or
    # mutate any release until GitHub proves the repository setting is active.
    if not client.immutable_releases_enabled(repository):
        raise Rejected("Immutable GitHub releases are not enabled for this repository.")
    release = client.release(repository, tag)
    if release is None:
        # Re-resolve the server-side annotated tag immediately before the first
        # irreversible release mutation. A local fetch is not sufficient: the
        # remote ref may have changed since the workflow preflight.
        client.validate_remote_tag(repository, tag, expected_commit)
        client.create(repository, tag, title, prerelease)
        release = client.release(repository, tag)
        if release is None:
            raise RuntimeError("GitHub did not expose the newly created draft release.")

    observed = validate_release(
        release,
        tag=tag,
        title=title,
        prerelease=prerelease,
        expected_assets=assets,
        allow_draft=True,
    )
    # Prove every existing byte before making any mutation. A mismatched
    # partial release must fail without uploading otherwise-missing assets.
    for asset in assets:
        remote = observed.get(asset.name)
        if remote is not None:
            verify_remote_asset(client, repository, asset, remote)
    for asset in assets:
        if asset.name not in observed:
            if release["draft"] is not True:
                raise Rejected(f"Final GitHub release is missing immutable asset {asset.name}.")
            client.upload(repository, tag, asset.path)

    release = client.release(repository, tag)
    if release is None:
        raise RuntimeError("GitHub release disappeared during asset reconciliation.")
    observed = validate_release(
        release,
        tag=tag,
        title=title,
        prerelease=prerelease,
        expected_assets=assets,
        allow_draft=True,
    )
    if set(observed) != {asset.name for asset in assets}:
        raise Rejected("GitHub draft release does not contain the complete immutable asset set.")
    for asset in assets:
        verify_remote_asset(client, repository, asset, observed[asset.name])

    if release["draft"]:
        # Bind finalization to the same promoted commit at the last possible
        # moment, after every asset byte has been downloaded and reverified.
        client.validate_remote_tag(repository, tag, expected_commit)
        client.finalize(repository, tag, prerelease)

    final = client.release(repository, tag)
    if final is None:
        raise RuntimeError("GitHub release disappeared after finalization.")
    final_assets = validate_release(
        final,
        tag=tag,
        title=title,
        prerelease=prerelease,
        expected_assets=assets,
        allow_draft=False,
    )
    if set(final_assets) != {asset.name for asset in assets}:
        raise Rejected("Final GitHub release does not contain the complete immutable asset set.")
    for asset in assets:
        verify_remote_asset(client, repository, asset, final_assets[asset.name])
    client.verify_release_attestation(repository, tag, expected_commit, assets)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--prerelease", action="store_true")
    parser.add_argument("assets", nargs="+")
    arguments = parser.parse_args()
    if not isinstance(arguments.repository, str) or REPOSITORY.fullmatch(arguments.repository) is None:
        parser.error("--repository must be an owner/repository name")
    if TAG.fullmatch(arguments.tag) is None:
        parser.error("--tag must be a canonical semantic-version release tag")
    if COMMIT.fullmatch(arguments.expected_commit) is None:
        parser.error("--expected-commit must be a lowercase 40-character commit ID")
    if not arguments.title or "\n" in arguments.title or "\r" in arguments.title:
        parser.error("--title must be a non-empty single line")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        assets = inspect_assets(arguments.assets)
        reconcile(
            repository=arguments.repository,
            tag=arguments.tag,
            expected_commit=arguments.expected_commit,
            title=arguments.title,
            prerelease=arguments.prerelease,
            assets=assets,
            client=GitHubClient(),
        )
    except (OSError, Rejected, RuntimeError) as error:
        print(f"release reconciliation rejected: {error}", file=sys.stderr)
        return 1
    print(f"Verified immutable GitHub release {arguments.repository}@{arguments.tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
