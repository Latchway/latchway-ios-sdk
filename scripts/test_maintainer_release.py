#!/usr/bin/env python3
"""Adversarial tests for the explicit single-maintainer release verifier."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
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
        intent = json.loads((Path(self.temporary.name) / "intent.json").read_text())
        self.assertFalse(intent["publication_ready"])
        self.assertFalse(intent["release_qualified"])
        self.assertEqual(intent["workflow"]["file"], ".github/workflows/single-maintainer-release.yml")

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
        self.assertIn("needs: [intent, verify-source]", workflow)
        source_gate = workflow.split("\n  verify-source:\n", 1)[1].split("\n  tag:\n", 1)[0]
        self.assertIn("scripts/verify-package.sh", source_gate)
        self.assertIn("scripts/publish-or-verify-cocoapods.sh", workflow)
        self.assertIn("COCOAPODS_TRUNK_TOKEN: ${{ secrets.COCOAPODS_TRUNK_TOKEN }}", workflow)
        self.assertIn("local `pod trunk me` session is not available", documentation)
        self.assertIn("single-maintainer-v1", documentation)

    def git(self, *arguments: str) -> str:
        return subprocess.run(["git", "-C", str(self.root), *arguments], check=True, capture_output=True, text=True).stdout.strip()


if __name__ == "__main__":
    unittest.main()
