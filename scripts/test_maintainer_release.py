#!/usr/bin/env python3
"""Adversarial tests for the explicit single-maintainer release verifier."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-maintainer-release.py")
SPEC = importlib.util.spec_from_file_location("verify_maintainer_release", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)
SOURCE = SCRIPT.parents[1]


class MaintainerReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="latchway-maintainer-release-")
        self.root = Path(self.temporary.name) / SOURCE.name
        subprocess.run(["git", "clone", "--quiet", "--no-local", str(SOURCE), str(self.root)], check=True)
        self.commit = self.git("rev-parse", "HEAD")
        self.original_root = MODULE.ROOT
        MODULE.ROOT = self.root

    def tearDown(self) -> None:
        MODULE.ROOT = self.original_root
        self.temporary.cleanup()

    def arguments(self, **changes: str) -> argparse.Namespace:
        values = {
            "repository_id": "ios",
            "repository_name": "Latchway/latchway-ios-sdk",
            "profile": "single_maintainer_v1",
            "release_commit": self.commit,
            "release_version": "1.0.0",
            "workflow_commit": self.commit,
            "workflow_ref": "refs/heads/main",
            "run_id": "123",
            "run_attempt": "1",
            "confirmation": "publish-v1.0.0-with-deferred-assurance",
            "intent_output": Path(self.temporary.name) / "intent.json",
            "github_output": None,
        }
        values.update(changes)
        return argparse.Namespace(**values)

    def test_accepts_exact_source_and_labels_deferred_assurance(self) -> None:
        result = MODULE.verify(self.arguments())
        self.assertEqual(result["commit"], self.commit)
        self.assertRegex(result["core_commit"], r"^[0-9a-f]{40}$")
        intent = json.loads((Path(self.temporary.name) / "intent.json").read_text())
        self.assertFalse(intent["publication_ready"])
        self.assertFalse(intent["release_qualified"])
        self.assertEqual(intent["workflow"]["file"], ".github/workflows/single-maintainer-release.yml")
        self.assertIn("cloud_deployments", intent["deferred_evidence"])
        self.assertFalse(any(item.startswith("cloud_deployments.") for item in intent["deferred_evidence"]))

    def test_rejects_wrong_confirmation_or_non_main_ref(self) -> None:
        for change in ({"confirmation": "yes"}, {"workflow_ref": "refs/heads/feature"}):
            with self.subTest(change=change), self.assertRaisesRegex(MODULE.Rejected, "maintainer_release_dispatch_invalid"):
                MODULE.verify(self.arguments(**change))

    def test_rejects_dirty_source(self) -> None:
        (self.root / "untracked").write_text("dirty\n", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.Rejected, "maintainer_release_worktree_dirty"):
            MODULE.verify(self.arguments())

    def test_workflow_gates_tag_and_documents_cocoapods_credential_boundary(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        self.assertIn("--rawfile body", workflow)
        documentation = (SOURCE / "docs/releasing.md").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn(
            "needs: [intent, verify-source, core-release-gate]",
            workflow,
        )
        source_gate = workflow.split("\n  verify-source:\n", 1)[1].split("\n  tag:\n", 1)[0]
        self.assertIn("scripts/verify-package.sh", source_gate)
        package = workflow.split("\n  package:\n", 1)[1].split("\n  publish-cocoapods:\n", 1)[0]
        publisher = workflow.split("\n  publish-cocoapods:\n", 1)[1].split("\n  github-release:\n", 1)[0]
        github_release = workflow.split("\n  github-release:\n", 1)[1]
        self.assertIn("ios-registry-candidate.json", package)
        self.assertIn("latchway.ios-single-maintainer-registry-candidate.v1", package)
        self.assertIn('test -z "$(find "$root" -mindepth 2 -print -quit)"', package)
        self.assertIn('test -z "$(find "$root" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"', package)
        self.assertNotIn("actions/checkout", publisher)
        self.assertNotIn("pod ipc spec", publisher)
        self.assertNotIn("scripts/publish-or-verify-cocoapods.sh", publisher)
        self.assertIn('test -z "$(find "$root" -mindepth 2 -print -quit)"', publisher)
        self.assertIn('test -z "$(find "$root" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"', publisher)
        self.assertIn("--data-binary \"@$RUNNER_TEMP/ios-registry-candidate/cocoapods-reviewed-podspec.json\"", publisher)
        self.assertIn("unset COCOAPODS_TRUNK_TOKEN", publisher)
        self.assertEqual(publisher.count("COCOAPODS_TRUNK_TOKEN: ${{ secrets.COCOAPODS_TRUNK_TOKEN }}"), 1)
        token_step = publisher.split("- name: Upload only reviewed JSON bytes with the protected Trunk credential", 1)[1]
        token_step = token_step.split("\n      - name:", 1)[0]
        self.assertIn("COCOAPODS_TRUNK_TOKEN: ${{ secrets.COCOAPODS_TRUNK_TOKEN }}", token_step)
        self.assertIn("cocoapods-release-evidence.json", publisher)
        self.assertIn("Validate exact release closure before requesting OIDC", github_release)
        self.assertLess(
            github_release.index("Validate exact release closure before requesting OIDC"),
            github_release.index("actions/attest-build-provenance"),
        )
        self.assertIn("ios-expected-release-files.txt", github_release)
        self.assertIn("local `pod trunk me` session is not available", documentation)
        self.assertIn("single-maintainer-v1", documentation)

    def test_selected_release_proves_github_immutability_after_publication(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        release = workflow.split("\n  github-release:\n", 1)[1]
        self.assertNotIn("\n  immutable-release-settings:\n", workflow)
        self.assertNotIn("single-maintainer-v1-administration", workflow)
        self.assertNotIn("LATCHWAY_RELEASE_PROFILE_POLICY_ID", workflow)
        self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", workflow)
        self.assertNotIn("repos/$GITHUB_REPOSITORY/immutable-releases", workflow)
        self.assertIn(".immutable==true", release)
        self.assertIn("If-None-Match:", release)
        self.assertIn("304( |$)", release)
        self.assertIn("gh release verify-asset", release)
        self.assertIn("gh release verify \"$RELEASE_TAG\"", release)
        self.assertIn("pre-publish-tag-ref.json", release)
        self.assertNotIn("--clobber", release)
        self.assertNotIn("gh release delete", release)

    def test_every_github_release_command_names_the_repository(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        commands = [line.strip() for line in workflow.splitlines() if "gh release " in line]
        self.assertGreater(len(commands), 0)
        for command in commands:
            with self.subTest(command=command):
                self.assertIn('--repo "$GITHUB_REPOSITORY"', command)

    def test_workflow_authenticates_public_core_and_owns_one_resumable_transaction(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        documentation = (SOURCE / "docs/releasing.md").read_text(encoding="utf-8")
        verifier = (SOURCE / "scripts/verify-public-core-release.sh").read_text(encoding="utf-8")
        semantic = (SOURCE / "scripts/verify-public-core-release.py").read_text(encoding="utf-8")
        for value in (
            "core-release-gate:",
            "Reject a v1 tag owned by another workflow transaction",
            "verify-public-core-release.sh",
            "retention-days: 90",
            "--draft --verify-tag",
            "cmp --silent",
            "{\"draft\":false}",
        ):
            self.assertIn(value, workflow)
        self.assertNotIn("--clobber", workflow)
        self.assertNotIn("gh release delete", workflow)
        for value in (
            "gh attestation verify",
            "single-maintainer-release.yml",
            "release.yml",
            "compare/$locked_core_commit...$core_commit",
            "registry-only; cloud deployment evidence is explicitly deferred",
            ".immutable == true",
            "(.assets | length) == 11",
        ):
            self.assertIn(value, verifier)
        for value in (
            "core_publication_gate",
            "vulnerability_scan_verified",
            "sbom_verified",
            'record.get("deployment_evidence") != {}',
            '"cloud_deployments"',
            '"publication_scope": "registry_only"',
        ):
            self.assertIn(value, semantic)
        self.assertNotIn("deployment-evidence.yml", verifier)
        self.assertNotIn("compose.tar.gz", semantic)
        self.assertNotIn("cloud_run.tar.gz", semantic)
        self.assertIn("registry-only", documentation)
        self.assertIn("Re-run failed jobs", documentation)
        self.assertIn("Never use **Re-run all jobs**", documentation)
        self.assertIn("never start a new workflow", documentation)

    def test_workflow_authenticates_main_run_before_candidate_code_or_tag_mutation(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        intent = workflow.split("\n  intent:\n", 1)[1].split("\n  verify-source:\n", 1)[0]
        steps = intent.split("\n    steps:\n", 1)[1].lstrip()
        self.assertTrue(steps.startswith("- name: Authenticate this exact main workflow run before candidate checkout"))
        authentication = steps.split("\n      - uses: actions/checkout", 1)[0]
        for value in (
            "actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT",
            '.head_sha == $commit and .head_branch == "main"',
            '.path == ".github/workflows/single-maintainer-release.yml"',
            'github.ref == \'refs/heads/main\'',
        ):
            self.assertIn(value, intent)
        self.assertNotIn("scripts/verify-maintainer-release.py", authentication)
        tag = workflow.split("\n  tag:\n", 1)[1].split("\n  package:\n", 1)[0]
        self.assertIn('test "$RELEASE_COMMIT" = "$REQUESTED_COMMIT"', tag)
        self.assertIn('test "$RELEASE_COMMIT" = "$WORKFLOW_COMMIT"', tag)
        self.assertIn('git/ref/heads/main', tag)

    def test_every_lower_assurance_environment_job_checks_exact_sentinel_first(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        expected = "latchway-release-controls-v1:latchway-ios-sdk:single-maintainer-v1"
        boundaries = {
            "tag": "package",
            "publish-cocoapods": "github-release",
            "github-release": None,
        }
        for job, following_job in boundaries.items():
            with self.subTest(job=job):
                section = workflow.split(f"\n  {job}:\n", 1)[1]
                if following_job is not None:
                    section = section.split(f"\n  {following_job}:\n", 1)[0]
                self.assertIn("environment: single-maintainer-v1", section)
                steps = section.split("\n    steps:\n", 1)[1].lstrip()
                self.assertTrue(
                    steps.startswith("- name: Verify exact lower-assurance environment"),
                    f"{job} must fail closed before any action, credential, OIDC request, or mutation",
                )
                first_step = steps.split("\n      - ", 1)[0]
                self.assertIn("OBSERVED_POLICY_ID: ${{ vars.LATCHWAY_RELEASE_CONTROL_POLICY_ID }}", first_step)
                self.assertIn(expected, first_step)

    def test_workflow_never_interpolates_dispatch_input_inside_shell(self) -> None:
        workflow = (SOURCE / ".github/workflows/single-maintainer-release.yml").read_text(encoding="utf-8")
        lines = workflow.splitlines()
        run_bodies: list[str] = []
        for index, line in enumerate(lines):
            match = re.match(r"^(\s*)run:\s*(.*)$", line)
            if match is None:
                continue
            indentation = len(match.group(1))
            body = [match.group(2)]
            for following in lines[index + 1 :]:
                if following.strip() and len(following) - len(following.lstrip()) <= indentation:
                    break
                body.append(following)
            run_bodies.append("\n".join(body))
        self.assertTrue(run_bodies)
        for body in run_bodies:
            self.assertNotIn("${{ inputs.", body)

    def git(self, *arguments: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *arguments], check=True, capture_output=True, text=True).stdout.strip()


if __name__ == "__main__":
    unittest.main()
