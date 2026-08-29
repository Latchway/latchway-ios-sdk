#!/usr/bin/env python3
"""Offline state-machine tests for CocoaPods release resumability."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/publish-or-verify-cocoapods.sh"


class CocoaPodsPublicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "published"
        self.log = self.root / "pod.log"
        self.local = self.root / "local.json"
        self.remote = self.root / "remote.json"
        self.mismatch = self.root / "mismatch.json"
        document = {
            "name": "Latchway",
            "version": "1.0.0",
            "source": {
                "git": "https://github.com/Latchway/latchway-ios-sdk.git",
                "tag": "v1.0.0",
            },
            "subspecs": [{"name": "Core"}, {"name": "AppAttest"}, {"name": "FirebaseAuth"}],
        }
        self.local.write_text(json.dumps(document), encoding="utf-8")
        self.remote.write_text(json.dumps(document), encoding="utf-8")
        document["source"]["tag"] = "v9.9.9"
        self.mismatch.write_text(json.dumps(document), encoding="utf-8")
        self.write_executable("pod", """#!/bin/bash
set -euo pipefail
if [[ "$1 $2" == "ipc spec" ]]; then
  cat "$FAKE_LOCAL_SPEC"
elif [[ "$1 $2" == "trunk push" ]]; then
  printf 'push\n' >>"$FAKE_POD_LOG"
  touch "$FAKE_PUBLISHED_STATE"
else
  echo "unexpected pod command: $*" >&2
  exit 2
fi
""")
        self.write_executable("curl", """#!/bin/bash
set -euo pipefail
output=
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" ]]; then
    output=$2
    shift 2
  else
    shift
  fi
done
case "$FAKE_REGISTRY_MODE" in
  exact) cp "$FAKE_REMOTE_SPEC" "$output"; printf 200 ;;
  mismatch) cp "$FAKE_MISMATCH_SPEC" "$output"; printf 200 ;;
  missing_then_publish)
    if [[ -f "$FAKE_PUBLISHED_STATE" ]]; then
      cp "$FAKE_REMOTE_SPEC" "$output"
      printf 200
    else
      printf '{}\n' >"$output"
      printf 404
    fi
    ;;
  missing) printf '{}\n' >"$output"; printf 404 ;;
  error) printf '{}\n' >"$output"; printf 503 ;;
  *) exit 2 ;;
esac
""")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_executable(self, name: str, source: str) -> None:
        path = self.bin / name
        path.write_text(source, encoding="utf-8")
        path.chmod(0o755)

    def invoke(self, mode: str, *, token: bool = False) -> subprocess.CompletedProcess[str]:
        environment = {
            **os.environ,
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "FAKE_LOCAL_SPEC": str(self.local),
            "FAKE_REMOTE_SPEC": str(self.remote),
            "FAKE_MISMATCH_SPEC": str(self.mismatch),
            "FAKE_PUBLISHED_STATE": str(self.state),
            "FAKE_POD_LOG": str(self.log),
            "FAKE_REGISTRY_MODE": mode,
            "LATCHWAY_COCOAPODS_VERIFY_ATTEMPTS": "1",
            "LATCHWAY_COCOAPODS_VERIFY_DELAY_SECONDS": "1",
        }
        environment.pop("COCOAPODS_TRUNK_TOKEN", None)
        if token:
            environment["COCOAPODS_TRUNK_TOKEN"] = "test-only-token"
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), "1.0.0"],
            cwd=ROOT,
            env=environment,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def test_existing_exact_coordinate_is_read_only_success(self) -> None:
        result = self.invoke("exact")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_existing_mismatch_is_rejected_without_publish(self) -> None:
        result = self.invoke("mismatch", token=True)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not exactly", result.stderr)
        self.assertFalse(self.log.exists())

    def test_missing_coordinate_publishes_once_then_verifies(self) -> None:
        result = self.invoke("missing_then_publish", token=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.log.read_text(encoding="utf-8"), "push\n")

    def test_missing_coordinate_requires_credential(self) -> None:
        result = self.invoke("missing")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("COCOAPODS_TRUNK_TOKEN", result.stderr)
        self.assertFalse(self.log.exists())

    def test_unknown_registry_state_never_publishes(self) -> None:
        result = self.invoke("error", token=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 503", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
