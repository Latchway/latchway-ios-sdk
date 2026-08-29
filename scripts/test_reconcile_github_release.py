#!/usr/bin/env python3
"""Offline tests for fail-closed GitHub release reconciliation."""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("reconcile-github-release.py")
SPEC = importlib.util.spec_from_file_location("reconcile_github_release", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

REPOSITORY = "Latchway/example"
TAG = "v1.0.0"
COMMIT = "0123456789abcdef0123456789abcdef01234567"
TAG_OBJECT = "89abcdef0123456789abcdef0123456789abcdef"


class FakeClient:
    def __init__(self, release: dict[str, Any] | None = None, contents: dict[int, bytes] | None = None) -> None:
        self.value = release
        self.contents = dict(contents or {})
        self.created = 0
        self.uploaded: list[str] = []
        self.finalized = 0
        self.attestations_verified = 0
        self.attested_commits: list[str] = []
        self.immutability_enabled = True
        self.tag_validations: list[tuple[str, str, str]] = []
        self.reject_tag_validation_calls: set[int] = set()

    def immutable_releases_enabled(self, repository: str) -> bool:
        del repository
        return self.immutability_enabled

    def release(self, repository: str, tag: str) -> dict[str, Any] | None:
        del repository, tag
        if self.value is None:
            return None
        return {
            **self.value,
            "assets": [dict(asset) for asset in self.value["assets"]],
        }

    def validate_remote_tag(self, repository: str, tag: str, expected_commit: str) -> None:
        self.tag_validations.append((repository, tag, expected_commit))
        if len(self.tag_validations) in self.reject_tag_validation_calls:
            raise MODULE.Rejected("Remote annotated release tag does not identify the promoted commit.")

    def create(self, repository: str, tag: str, title: str, prerelease: bool) -> None:
        del repository
        self.created += 1
        self.value = {
            "tag_name": tag,
            "name": title,
            "draft": True,
            "immutable": False,
            "prerelease": prerelease,
            "assets": [],
        }

    def download(self, repository: str, asset_id: int, destination: Path) -> None:
        del repository
        destination.write_bytes(self.contents[asset_id])

    def upload(self, repository: str, tag: str, path: Path) -> None:
        del repository, tag
        assert self.value is not None
        asset_id = max(self.contents, default=0) + 1
        payload = path.read_bytes()
        self.contents[asset_id] = payload
        self.value["assets"].append({
            "id": asset_id,
            "name": path.name,
            "size": len(payload),
            "state": "uploaded",
        })
        self.uploaded.append(path.name)

    def finalize(self, repository: str, tag: str, prerelease: bool) -> None:
        del repository, tag, prerelease
        assert self.value is not None
        self.finalized += 1
        self.value["draft"] = False
        self.value["immutable"] = True

    def verify_release_attestation(
        self,
        repository: str,
        tag: str,
        expected_commit: str,
        assets: list[MODULE.Asset],
    ) -> None:
        del repository, tag, assets
        self.attestations_verified += 1
        self.attested_commits.append(expected_commit)


def release(
    *, draft: bool, assets: list[dict[str, Any]], title: str = "Latchway v1.0.0",
    immutable: bool | None = None,
) -> dict[str, Any]:
    return {
        "tag_name": "v1.0.0",
        "name": title,
        "draft": draft,
        "immutable": (not draft) if immutable is None else immutable,
        "prerelease": False,
        "assets": assets,
    }


class ReconciliationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.first_path = root / "first.tgz"
        self.second_path = root / "SHA256SUMS"
        self.first_path.write_bytes(b"first immutable bytes")
        self.second_path.write_bytes(b"digest  first.tgz\n")
        self.assets = MODULE.inspect_assets([str(self.first_path), str(self.second_path)])

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def reconcile(self, client: FakeClient) -> None:
        MODULE.reconcile(
            repository=REPOSITORY,
            tag=TAG,
            expected_commit=COMMIT,
            title="Latchway v1.0.0",
            prerelease=False,
            assets=self.assets,
            client=client,
        )

    def test_creates_uploads_and_finalizes_new_release(self) -> None:
        client = FakeClient()
        self.reconcile(client)
        self.assertEqual(client.created, 1)
        self.assertEqual(client.uploaded, ["SHA256SUMS", "first.tgz"])
        self.assertEqual(client.finalized, 1)
        self.assertEqual(client.attestations_verified, 1)
        self.assertEqual(client.tag_validations, [(REPOSITORY, TAG, COMMIT)] * 2)
        self.assertEqual(client.attested_commits, [COMMIT])

    def test_resumes_partial_draft_without_overwriting_identical_asset(self) -> None:
        first = next(asset for asset in self.assets if asset.name == "first.tgz")
        client = FakeClient(
            release(
                draft=True,
                assets=[{
                    "id": 7,
                    "name": first.name,
                    "size": first.size,
                    "state": "uploaded",
                    "digest": f"sha256:{first.sha256}",
                }],
            ),
            {7: self.first_path.read_bytes()},
        )
        self.reconcile(client)
        self.assertEqual(client.created, 0)
        self.assertEqual(client.uploaded, ["SHA256SUMS"])
        self.assertEqual(client.finalized, 1)
        self.assertEqual(client.attestations_verified, 1)
        self.assertEqual(client.tag_validations, [(REPOSITORY, TAG, COMMIT)])

    def test_exact_final_release_is_a_read_only_success(self) -> None:
        remote_assets = []
        contents: dict[int, bytes] = {}
        for identifier, asset in enumerate(self.assets, 1):
            remote_assets.append({
                "id": identifier,
                "name": asset.name,
                "size": asset.size,
                "state": "uploaded",
                "digest": f"sha256:{asset.sha256}",
            })
            contents[identifier] = asset.path.read_bytes()
        client = FakeClient(release(draft=False, assets=remote_assets), contents)
        self.reconcile(client)
        self.assertEqual(client.created, 0)
        self.assertEqual(client.uploaded, [])
        self.assertEqual(client.finalized, 0)
        self.assertEqual(client.attestations_verified, 1)
        self.assertEqual(client.tag_validations, [])
        self.assertEqual(client.attested_commits, [COMMIT])

    def test_rejects_different_existing_bytes(self) -> None:
        first = next(asset for asset in self.assets if asset.name == "first.tgz")
        client = FakeClient(
            release(draft=True, assets=[{
                "id": 1,
                "name": first.name,
                "size": first.size,
                "state": "uploaded",
            }]),
            {1: b"x" * first.size},
        )
        with self.assertRaisesRegex(MODULE.Rejected, "not byte-identical"):
            self.reconcile(client)
        self.assertEqual(client.uploaded, [])
        self.assertEqual(client.finalized, 0)

    def test_rejects_unexpected_asset_and_metadata_mismatch(self) -> None:
        unexpected = FakeClient(release(draft=True, assets=[{
            "id": 1, "name": "foreign.bin", "size": 1, "state": "uploaded",
        }]), {1: b"x"})
        with self.assertRaisesRegex(MODULE.Rejected, "unexpected asset"):
            self.reconcile(unexpected)

        wrong_title = FakeClient(release(draft=True, assets=[], title="wrong"))
        with self.assertRaisesRegex(MODULE.Rejected, "title"):
            self.reconcile(wrong_title)

    def test_final_release_cannot_be_backfilled(self) -> None:
        client = FakeClient(release(draft=False, assets=[]))
        with self.assertRaisesRegex(MODULE.Rejected, "missing immutable asset"):
            self.reconcile(client)
        self.assertEqual(client.uploaded, [])

    def test_rejects_mutable_release_or_disabled_repository_before_mutation(self) -> None:
        mutable = FakeClient(release(draft=False, immutable=False, assets=[]))
        with self.assertRaisesRegex(MODULE.Rejected, "mutable"):
            self.reconcile(mutable)
        self.assertEqual(mutable.uploaded, [])

        disabled = FakeClient()
        disabled.immutability_enabled = False
        with self.assertRaisesRegex(MODULE.Rejected, "not enabled"):
            self.reconcile(disabled)
        self.assertEqual(disabled.created, 0)
        self.assertEqual(disabled.uploaded, [])

    def test_rejects_remote_tag_change_before_create_without_mutation(self) -> None:
        client = FakeClient()
        client.reject_tag_validation_calls = {1}
        with self.assertRaisesRegex(MODULE.Rejected, "promoted commit"):
            self.reconcile(client)
        self.assertEqual(client.created, 0)
        self.assertEqual(client.uploaded, [])
        self.assertEqual(client.finalized, 0)

    def test_rejects_remote_tag_change_immediately_before_finalization(self) -> None:
        remote_assets = []
        contents: dict[int, bytes] = {}
        for identifier, asset in enumerate(self.assets, 1):
            remote_assets.append({
                "id": identifier,
                "name": asset.name,
                "size": asset.size,
                "state": "uploaded",
                "digest": f"sha256:{asset.sha256}",
            })
            contents[identifier] = asset.path.read_bytes()
        client = FakeClient(release(draft=True, assets=remote_assets), contents)
        client.reject_tag_validation_calls = {1}
        with self.assertRaisesRegex(MODULE.Rejected, "promoted commit"):
            self.reconcile(client)
        self.assertEqual(client.uploaded, [])
        self.assertEqual(client.finalized, 0)
        self.assertEqual(client.attestations_verified, 0)

    def test_rejects_noncanonical_expected_commit_before_any_remote_action(self) -> None:
        client = FakeClient()
        with self.assertRaisesRegex(MODULE.Rejected, "canonical Git object ID"):
            MODULE.reconcile(
                repository=REPOSITORY,
                tag=TAG,
                expected_commit="A" * 40,
                title="Latchway v1.0.0",
                prerelease=False,
                assets=self.assets,
                client=client,
            )
        self.assertEqual(client.created, 0)
        self.assertEqual(client.tag_validations, [])


def attestation_document(
    assets: list[MODULE.Asset],
    *,
    commit: str = COMMIT,
    include_all_assets: bool = True,
) -> dict[str, Any]:
    subjects = [{
        "uri": f"pkg:github/{REPOSITORY}@{TAG}",
        "digest": {"sha1": commit},
    }]
    if include_all_assets:
        subjects.extend(
            {"name": asset.name, "digest": {"sha256": asset.sha256}}
            for asset in assets
        )
    statement = {
        "_type": MODULE.STATEMENT_TYPE,
        "subject": subjects,
        "predicateType": MODULE.RELEASE_PREDICATE_TYPE,
        "predicate": {"release": {"tag": TAG}},
    }
    encoded = base64.b64encode(
        json.dumps(statement, separators=(",", ":"), sort_keys=True).encode("utf-8")
    ).decode("ascii")
    return {
        "attestation": {"bundle": {"dsseEnvelope": {"payload": encoded}}},
        "verificationResult": {"verified": True},
    }


class GitHubClientTests(unittest.TestCase):
    def make_assets(self, temporary: str) -> list[MODULE.Asset]:
        first = Path(temporary, "first.tgz")
        second = Path(temporary, "SHA256SUMS")
        first.write_bytes(b"first")
        second.write_bytes(b"sum")
        return MODULE.inspect_assets([str(first), str(second)])

    def test_release_attestation_retries_and_verifies_commit_and_every_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            assets = self.make_assets(temporary)
            document = json.dumps(attestation_document(assets))
            results = [
                MODULE.subprocess.CompletedProcess([], 1, "", "not propagated"),
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
            ]
            with patch.dict(
                os.environ,
                {
                    "LATCHWAY_GITHUB_RELEASE_ATTESTATION_ATTEMPTS": "2",
                    "LATCHWAY_GITHUB_RELEASE_ATTESTATION_DELAY_SECONDS": "1",
                },
            ), patch.object(MODULE.subprocess, "run", side_effect=results) as run, patch.object(
                MODULE.time, "sleep"
            ) as sleep:
                MODULE.GitHubClient().verify_release_attestation(
                    REPOSITORY, TAG, COMMIT, assets
                )
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0][:4], ["gh", "release", "verify", TAG])
            self.assertEqual(commands[1], commands[0])
            self.assertEqual(len(commands), 4)
            self.assertEqual(
                {Path(command[4]).name for command in commands[2:]},
                {"first.tgz", "SHA256SUMS"},
            )
            sleep.assert_called_once_with(1)

    def test_each_asset_attestation_has_an_independent_bounded_retry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            assets = self.make_assets(temporary)
            document = json.dumps(attestation_document(assets))
            results = [
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
                MODULE.subprocess.CompletedProcess([], 1, "", "asset not propagated"),
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
                MODULE.subprocess.CompletedProcess([], 0, document, ""),
            ]
            with patch.dict(
                os.environ,
                {
                    "LATCHWAY_GITHUB_RELEASE_ATTESTATION_ATTEMPTS": "2",
                    "LATCHWAY_GITHUB_RELEASE_ATTESTATION_DELAY_SECONDS": "1",
                },
            ), patch.object(MODULE.subprocess, "run", side_effect=results) as run, patch.object(
                MODULE.time, "sleep"
            ) as sleep:
                MODULE.GitHubClient().verify_release_attestation(
                    REPOSITORY, TAG, COMMIT, assets
                )
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[1], commands[2])
            self.assertEqual(commands[1][2], "verify-asset")
            self.assertNotEqual(commands[2][4], commands[3][4])
            sleep.assert_called_once_with(1)

    def test_release_attestation_rejects_wrong_commit_or_missing_asset_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            assets = self.make_assets(temporary)
            wrong_asset = attestation_document(assets)
            payload = wrong_asset["attestation"]["bundle"]["dsseEnvelope"]["payload"]
            statement = json.loads(base64.b64decode(payload, validate=True))
            statement["subject"][1]["digest"]["sha256"] = "f" * 64
            wrong_asset["attestation"]["bundle"]["dsseEnvelope"]["payload"] = (
                base64.b64encode(json.dumps(statement).encode("utf-8")).decode("ascii")
            )
            for document, message in (
                (attestation_document(assets, commit="f" * 40), "promoted source commit"),
                (attestation_document(assets, include_all_assets=False), "exact release asset set"),
                (wrong_asset, "exact asset bytes"),
            ):
                with self.subTest(message=message), patch.object(
                    MODULE.subprocess,
                    "run",
                    return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(document), ""),
                ):
                    with self.assertRaisesRegex(MODULE.Rejected, message):
                        MODULE.GitHubClient().verify_release_attestation(
                            REPOSITORY, TAG, COMMIT, assets
                        )

    def test_release_attestation_rejects_success_with_empty_or_malformed_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            assets = self.make_assets(temporary)
            for output in (
                "",
                "not-json",
                "[]",
                "{}",
                '{"attestation":{},"attestation":{},"verificationResult":{}}',
            ):
                with self.subTest(output=output), patch.object(
                    MODULE.subprocess,
                    "run",
                    return_value=MODULE.subprocess.CompletedProcess([], 0, output, ""),
                ):
                    with self.assertRaises((RuntimeError, MODULE.Rejected)):
                        MODULE.GitHubClient().verify_release_attestation(
                            REPOSITORY, TAG, COMMIT, assets
                        )

    def test_remote_tag_requires_exact_annotated_object_and_commit(self) -> None:
        reference = {
            "ref": f"refs/tags/{TAG}",
            "object": {"type": "tag", "sha": TAG_OBJECT},
        }
        annotated = {"tag": TAG, "object": {"type": "commit", "sha": COMMIT}}
        with patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[
                MODULE.subprocess.CompletedProcess([], 0, json.dumps(reference), ""),
                MODULE.subprocess.CompletedProcess([], 0, json.dumps(annotated), ""),
            ],
        ) as run:
            MODULE.GitHubClient().validate_remote_tag(REPOSITORY, TAG, COMMIT)
        self.assertIn(f"repos/{REPOSITORY}/git/ref/tags/{TAG}", run.call_args_list[0].args[0])
        self.assertIn(f"repos/{REPOSITORY}/git/tags/{TAG_OBJECT}", run.call_args_list[1].args[0])

        lightweight = {**reference, "object": {"type": "commit", "sha": COMMIT}}
        with patch.object(
            MODULE.subprocess,
            "run",
            return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(lightweight), ""),
        ) as run:
            with self.assertRaisesRegex(MODULE.Rejected, "annotated tag object"):
                MODULE.GitHubClient().validate_remote_tag(REPOSITORY, TAG, COMMIT)
            self.assertEqual(run.call_count, 1)

        wrong_commit = {"tag": TAG, "object": {"type": "commit", "sha": "f" * 40}}
        with patch.object(
            MODULE.subprocess,
            "run",
            side_effect=[
                MODULE.subprocess.CompletedProcess([], 0, json.dumps(reference), ""),
                MODULE.subprocess.CompletedProcess([], 0, json.dumps(wrong_commit), ""),
            ],
        ):
            with self.assertRaisesRegex(MODULE.Rejected, "promoted commit"):
                MODULE.GitHubClient().validate_remote_tag(REPOSITORY, TAG, COMMIT)

    def test_preflight_requires_exact_enabled_response_and_consumes_protected_token(self) -> None:
        client = MODULE.GitHubClient()
        accepted = {"enabled": True, "enforced_by_owner": False}
        with patch.dict(
            os.environ,
            {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": "token"},
            clear=True,
        ), patch.object(
            MODULE.subprocess,
            "run",
            return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(accepted), ""),
        ) as run:
            self.assertTrue(client.immutable_releases_enabled(REPOSITORY))
            self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", os.environ)
            arguments = run.call_args.args[0]
            self.assertIn("X-GitHub-Api-Version: 2026-03-10", arguments)
            self.assertIn(f"repos/{REPOSITORY}/immutable-releases", arguments)
            environment = run.call_args.kwargs["env"]
            self.assertEqual(environment["GH_TOKEN"], "token")
            self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", environment)

        for response in (
            {"enabled": False, "enforced_by_owner": False},
            {"enabled": True},
            {"enabled": True, "enforced_by_owner": False, "unexpected": True},
        ):
            with self.subTest(response=response), patch.dict(
                os.environ, {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": "token"}, clear=True
            ), patch.object(
                MODULE.subprocess,
                "run",
                return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(response), ""),
            ):
                self.assertFalse(client.immutable_releases_enabled(REPOSITORY))
                self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", os.environ)

        with patch.dict(
            os.environ, {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": "token"}, clear=True
        ), patch.object(
            MODULE.subprocess,
            "run",
            return_value=MODULE.subprocess.CompletedProcess(
                [],
                0,
                '{"enabled":false,"enabled":true,"enforced_by_owner":false}',
                "",
            ),
        ):
            self.assertFalse(client.immutable_releases_enabled(REPOSITORY))
            self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", os.environ)

    def test_preflight_rejects_missing_or_multiline_token_without_network(self) -> None:
        client = MODULE.GitHubClient()
        for token in (None, "bad\nvalue"):
            environment = {} if token is None else {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": token}
            with self.subTest(token=token), patch.dict(os.environ, environment, clear=True), patch.object(
                MODULE.subprocess, "run"
            ) as run:
                with self.assertRaisesRegex(RuntimeError, "credential is missing"):
                    client.immutable_releases_enabled(REPOSITORY)
                self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", os.environ)
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
