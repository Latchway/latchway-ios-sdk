#!/usr/bin/env python3
"""Offline checks for current supplied-identity candidate and resume wiring.

No device, credentials, signing tools, gateway, or historical CI workflow is used.
"""

from __future__ import annotations

import ast
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILDER = ROOT / "scripts/build-physical-app-attest-candidate.sh"
RUNNER = ROOT / "scripts/run-physical-app-attest.sh"
INSPECTOR = ROOT / "scripts/inspect-physical-app-attest-candidate.py"
HOST = ROOT / "Examples/AppAttestConformance/Sources/AppAttestConformanceApp.swift"


class CurrentPhysicalIdentityTests(unittest.TestCase):
    def test_public_metadata_is_required_forwarded_and_exactly_bound(self) -> None:
        builder = BUILDER.read_text()
        inspector = INSPECTOR.read_text()
        assignments = {
            target.id: node.value
            for node in ast.walk(ast.parse(inspector))
            if isinstance(node, ast.Assign)
            for target in node.targets
            if isinstance(target, ast.Name)
        }
        for suffix, plist_key, local in (
            ("ISSUER", "LatchwayIdentityIssuer", "identity_issuer"),
            ("AUDIENCE", "LatchwayIdentityAudience", "identity_audience"),
        ):
            name = f"LATCHWAY_IDENTITY_{suffix}"
            self.assertIn(f"  {name}\n", builder.split("for variable_name", 1)[0])
            self.assertIn(f'export TUIST_{name}="${name}"', builder)
            self.assertIn(f'{local} = required("{name}")', inspector)
            for dictionary, key in (("expected_info", plist_key), ("protected_inputs", name)):
                value = assignments[dictionary]
                self.assertIsInstance(value, ast.Dict)
                fields = {k.value: v.id for k, v in zip(value.keys, value.values)
                          if isinstance(k, ast.Constant) and isinstance(v, ast.Name)}
                self.assertEqual(fields[key], local)
        self.assertEqual(inspector.count("expected_info=expected_info"), 4)
        self.assertIn("host_info.get(key) != value", inspector)

    def test_candidate_rejects_each_resume_environment_variant_before_build(self) -> None:
        source = BUILDER.read_text()
        names = re.findall(r"^  (LATCHWAY_[A-Z0-9_]+)$",
                           source.split("required_variables=(", 1)[1].split(")", 1)[0], re.M)
        for token_name in ("LATCHWAY_RESUME_IDENTITY_TOKEN",
                           "DEVICECTL_CHILD_LATCHWAY_RESUME_IDENTITY_TOKEN"):
            with self.subTest(token_name=token_name), tempfile.TemporaryDirectory() as directory:
                environment = {"PATH": "/usr/bin:/bin", **{name: "fixture" for name in names},
                               token_name: "synthetic-resume-fixture-not-a-credential"}
                result = subprocess.run(["/bin/bash", str(BUILDER), directory],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertIn("runtime identity/device grants are forbidden", result.stderr)
                self.assertNotIn(environment[token_name], result.stdout + result.stderr)

    def test_all_raw_tokens_are_removed_before_any_child_process(self) -> None:
        prefix = RUNNER.read_text().split('repository_root="$(', 1)[0]
        raw_names = [f"LATCHWAY_{kind}_IDENTITY_TOKEN" for kind in ("REGISTRATION", "ASSERTION", "RESUME")]
        slots = ("latchway_registration_grant", "latchway_assertion_grant", "latchway_resume_identity_token")
        for name in raw_names:
            self.assertIn(f"unset {name}", prefix)
        for slot in slots:
            self.assertIn(slot, prefix.split("export -n", 1)[1].splitlines()[0])
        probe = '\n/bin/bash -c \'[[ -z "${LATCHWAY_REGISTRATION_IDENTITY_TOKEN:-}${LATCHWAY_ASSERTION_IDENTITY_TOKEN:-}${LATCHWAY_RESUME_IDENTITY_TOKEN:-}${latchway_registration_grant:-}${latchway_assertion_grant:-}${latchway_resume_identity_token:-}" ]]\'\n'
        result = subprocess.run(["/bin/bash", "-c", prefix + probe],
                                env={"PATH": "/usr/bin:/bin", **{name: "synthetic-token" for name in raw_names}},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_resume_token_is_only_exported_after_observer_and_cleared(self) -> None:
        runner = RUNNER.read_text()
        export = 'export DEVICECTL_CHILD_LATCHWAY_RESUME_IDENTITY_TOKEN="$latchway_resume_identity_token"'
        self.assertEqual(runner.count(export), 1)
        resume = runner.index("validate_signed_lease_before_launch resume")
        self.assertLess(runner.index('"$component_observer_hook" \\\n'), resume)
        self.assertLess(resume, runner.index(export))
        launch = runner.index("xcrun devicectl device process launch", runner.index(export))
        end = runner.index('observation_path="$output_dir/app-attest-observation.json"', launch)
        after_launch = runner[launch:end]
        cleanup = runner.split("cleanup() {", 1)[1].split("trap cleanup EXIT", 1)[0]
        for marker in ("unset DEVICECTL_CHILD_LATCHWAY_RESUME_IDENTITY_TOKEN",
                       'latchway_resume_identity_token=""', "unset latchway_resume_identity_token"):
            self.assertIn(marker, after_launch)
            self.assertIn(marker, cleanup)
        self.assertIn("a separate bounded resume identity token is required", runner)

    def test_host_consumes_resume_environment_before_work_and_restores(self) -> None:
        source = HOST.read_text()
        self.assertLess(source.index('unsetenv("LATCHWAY_RESUME_IDENTITY_TOKEN")'),
                        source.index("guard var values = Values("))
        resume = source.split("private func resumeAfterComponentObservation", 1)[1].split(
            "private func authorizedQuotaProbe", 1)[0]
        self.assertIn("(16...65_536).contains(token.utf8.count)", resume)
        self.assertIn("restoring: true", resume)
        self.assertNotIn("ProcessInfo.processInfo.environment", resume)
        factory = source.split("private func makeClient", 1)[1].split(
            "private func resumeAfterComponentObservation", 1)[0]
        self.assertRegex(factory, r"if restoring \{\s+signedIn = try await app\.restore")

    def test_runtime_resume_does_not_change_two_grant_evidence_schema(self) -> None:
        runner = RUNNER.read_text()
        self.assertIn('set(grants) != {"registration", "assertion"}', runner)
        lease_validation = runner.split("validate_signed_lease_before_launch()", 1)[1].split(
            "validate_signed_lease_before_launch initial", 1)[0]
        self.assertNotIn("latchway_resume_identity_token", lease_validation)


if __name__ == "__main__":
    unittest.main()
