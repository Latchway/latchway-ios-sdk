#!/usr/bin/env python3
"""Offline tests for fail-closed GitHub release reconciliation."""

from __future__ import annotations

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


class FakeClient:
    def __init__(self, release: dict[str, Any] | None = None, contents: dict[int, bytes] | None = None) -> None:
        self.value = release
        self.contents = dict(contents or {})
        self.created = 0
        self.uploaded: list[str] = []
        self.finalized = 0
        self.attestations_verified = 0
        self.immutability_enabled = True

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
        self, repository: str, tag: str, assets: list[MODULE.Asset]
    ) -> None:
        del repository, tag, assets
        self.attestations_verified += 1


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
            repository="Latchway/example",
            tag="v1.0.0",
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


class GitHubClientTests(unittest.TestCase):
    def test_release_attestation_verifies_release_and_every_exact_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary, "first.tgz")
            second = Path(temporary, "SHA256SUMS")
            first.write_bytes(b"first")
            second.write_bytes(b"sum")
            assets = MODULE.inspect_assets([str(first), str(second)])
            with patch.object(MODULE, "_run") as run:
                MODULE.GitHubClient().verify_release_attestation(
                    "Latchway/example", "v1.0.0", assets
                )
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual(commands[0][:4], ["gh", "release", "verify", "v1.0.0"])
            self.assertEqual(len(commands), 3)
            self.assertEqual(
                {Path(command[4]).name for command in commands[1:]},
                {"first.tgz", "SHA256SUMS"},
            )

    def test_preflight_requires_exact_enabled_response_and_protected_token(self) -> None:
        client = MODULE.GitHubClient()
        accepted = {"enabled": True, "enforced_by_owner": False}
        with patch.dict(os.environ, {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": "token"}), patch.object(
            MODULE.subprocess,
            "run",
            return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(accepted), ""),
        ) as run:
            self.assertTrue(client.immutable_releases_enabled("Latchway/example"))
            arguments = run.call_args.args[0]
            self.assertIn("X-GitHub-Api-Version: 2026-03-10", arguments)
            self.assertIn("repos/Latchway/example/immutable-releases", arguments)
            self.assertEqual(run.call_args.kwargs["env"]["GH_TOKEN"], "token")

        for response in (
            {"enabled": False, "enforced_by_owner": False},
            {"enabled": True},
            {"enabled": True, "enforced_by_owner": False, "unexpected": True},
        ):
            with self.subTest(response=response), patch.dict(
                os.environ, {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": "token"}
            ), patch.object(
                MODULE.subprocess,
                "run",
                return_value=MODULE.subprocess.CompletedProcess([], 0, json.dumps(response), ""),
            ):
                self.assertFalse(client.immutable_releases_enabled("Latchway/example"))

    def test_preflight_rejects_missing_or_multiline_token_without_network(self) -> None:
        client = MODULE.GitHubClient()
        for token in (None, "bad\nvalue"):
            environment = {} if token is None else {"LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN": token}
            with self.subTest(token=token), patch.dict(os.environ, environment, clear=True), patch.object(
                MODULE.subprocess, "run"
            ) as run:
                with self.assertRaisesRegex(RuntimeError, "credential is missing"):
                    client.immutable_releases_enabled("Latchway/example")
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
