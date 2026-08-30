#!/usr/bin/env python3
"""Enforce credential and OIDC isolation in the physical App Attest workflow."""

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "physical-app-attest.yml"


def job_block(source: str, job: str) -> str:
    match = re.search(rf"(?m)^  {re.escape(job)}:\n", source)
    if match is None:
        raise AssertionError(f"missing job: {job}")
    following = re.search(r"(?m)^  [a-z0-9][a-z0-9-]*:\n", source[match.end() :])
    end = len(source) if following is None else match.end() + following.start()
    return source[match.start() : end]


class PhysicalEvidenceWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = WORKFLOW.read_text(encoding="utf-8")
        cls.authorize = job_block(cls.source, "authorize-source")
        cls.collect = job_block(cls.source, "app-attest-production")
        cls.attest = job_block(cls.source, "attest")

    def test_source_authorization_is_github_hosted_and_candidate_code_free(self) -> None:
        self.assertIn("runs-on: ubuntu-24.04", self.authorize)
        self.assertIn("id-token: write", self.authorize)
        self.assertIn("artifact-metadata: write", self.authorize)
        self.assertIn("actions/attest@", self.authorize)
        self.assertIn("latchway.physical-source-authorization.v1", self.authorize)
        self.assertIn("source-authorization.sigstore.json", self.authorize)
        for forbidden in ("secrets.", "${{ vars.", "scripts/", "xcodebuild", "swift "):
            self.assertNotIn(forbidden, self.authorize)

    def test_candidate_runner_is_one_job_jit_and_has_no_privileged_authority(self) -> None:
        self.assertIn("permissions: {}", self.source.split("jobs:", 1)[0])
        self.assertIn(
            "runs-on: [self-hosted, macOS, latchway-physical-ios, latchway-ephemeral-jit]",
            self.collect,
        )
        self.assertIn("needs: authorize-source", self.collect)
        self.assertIn("actions: read\n      contents: read", self.collect)
        self.assertIn("actions/checkout@", self.collect)
        self.assertIn("run: scripts/run-physical-app-attest.sh", self.collect)
        self.assertIn("secrets.LATCHWAY_IOS_DEVICE_ID", self.collect)
        self.assertIn("secrets.LATCHWAY_ONE_TIME_DEVICE_GRANT", self.collect)
        self.assertNotIn("secrets.LATCHWAY_IDENTITY_TOKEN", self.collect)
        for forbidden in (
            "id-token:",
            "attestations:",
            "artifact-metadata:",
            "actions/attest@",
            "packages:",
            "GHCR",
        ):
            self.assertNotIn(forbidden, self.collect)
        self.assertIn("ACTIONS_ID_TOKEN_REQUEST_URL", self.collect)
        self.assertIn("AWS_ACCESS_KEY_ID", self.collect)
        self.assertIn("CLOUDFLARE_API_TOKEN", self.collect)
        self.assertIn(
            "prohibited credential class is present on physical collector",
            self.collect,
        )
        for forbidden_env in (
            "\n          AWS_ACCESS_KEY_ID:",
            "\n          AWS_SECRET_ACCESS_KEY:",
            "\n          CLOUDFLARE_API_TOKEN:",
        ):
            self.assertNotIn(forbidden_env, self.collect)

    def test_signed_lease_binds_identity_source_artifact_and_one_use_grant(self) -> None:
        for marker in (
            "/etc/latchway/physical-collector/lease.json",
            "/usr/local/libexec/latchway-physical-collector-finalize",
            "/usr/local/libexec/latchway-ios-component-evidence-observer",
            'test "$RUNNER_NAME" = "latchway-ios-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
            ".runner.ephemeral == true",
            ".runner.jit == true",
            ".runner.max_jobs == 1",
            ".runner.fresh_boot == true",
            ".runner.clean_workspace == true",
            ".runner.destroy_after_job == true",
            ".credentials == {long_lived:false,organization:false,administration:false,registry:false,oidc:false}",
            "caller_supplied_claims_accepted:false",
            "out_of_band_watchdog:true",
            "destroy_on_disconnect:true",
            '"latchway-physical-evidence/ios-app-attest"',
            ".grant.single_use == true",
            ".grant.issued_at_unix",
            ".grant.expires_at_unix <= .expires_at_unix",
            "(.grant.expires_at_unix - .grant.issued_at_unix) <= 300",
            "source_authorization_sha256",
            "ios_app_binary_sha256",
            "ios_widget_binary_sha256",
            "ios_share_binary_sha256",
            "ios_action_binary_sha256",
            "openssl dgst -sha256 -verify",
            "--deny-self-hosted-runners",
        ):
            self.assertIn(marker, self.collect)

    def test_wipe_and_finalizer_are_unconditional_and_finalizer_accepts_paths_not_hash_claims(self) -> None:
        self.assertGreaterEqual(self.collect.count("if: ${{ always() }}"), 2)
        self.assertIn("Wipe device app data even when collection fails", self.collect)
        self.assertIn("Unconditionally finalize, deregister, and arm collector destruction", self.collect)
        self.assertIn("devicectl device uninstall app", self.collect)
        self.assertIn("--source-authorization \"$source/source-authorization.json\"", self.collect)
        self.assertIn("--evidence-directory \"$evidence\"", self.collect)
        self.assertIn("--device-wipe-receipt", self.collect)
        for forbidden in (
            "--source-authorization-sha256",
            "--lease-sha256",
            "--device-wipe-sha256",
            "--evidence-manifest-sha256",
        ):
            self.assertNotIn(forbidden, self.collect)
        for marker in (
            ".evidence_eligible == true",
            "private_key_isolated:true",
            "independent_device_verification:true",
            "independent_provider_verification:true",
            "independent_component_verification:true",
            "gateway_run_receipt_verified:true",
            "one_use_invocation:true",
            "watchdog_armed:true",
            ".observations.device_inventory_sha256",
            ".observations.provider_observation_sha256",
            ".observations.component_observation_sha256",
            ".observations.gateway_run_receipt_sha256",
            ".runner.deregistered == true",
            ".runner.destroy_scheduled == true",
        ):
            self.assertIn(marker, self.collect)

    def test_action_component_candidate_and_lifecycle_observer_are_mandatory(self) -> None:
        for marker in (
            "LATCHWAY_IOS_WIDGET_BUNDLE_ID",
            "LATCHWAY_IOS_SHARE_BUNDLE_ID",
            "LATCHWAY_IOS_ACTION_BUNDLE_ID",
            "LATCHWAY_HOST_COMPONENT_DEFINITION_ID",
            "LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID",
            "LATCHWAY_SHARE_COMPONENT_DEFINITION_ID",
            "LATCHWAY_ACTION_COMPONENT_DEFINITION_ID",
            "LATCHWAY_IOS_WIDGET_BINARY_SHA256",
            "LATCHWAY_IOS_SHARE_BINARY_SHA256",
            "LATCHWAY_IOS_ACTION_BINARY_SHA256",
            "component-observation.json",
            'trust_source_after == "delegated_direct_attested"',
            "host_process_running_during_step_up:false",
            "background_execution_observed:true",
            "host_termination_observed:true",
            "user_presence_prompt_observed:false",
        ):
            self.assertIn(marker, self.source)

    def test_unsigned_handoff_is_bounded_and_short_lived(self) -> None:
        self.assertIn(
            "name: app-attest-physical-unsigned-${{ github.run_id }}-${{ github.run_attempt }}",
            self.collect,
        )
        self.assertIn("if-no-files-found: error", self.collect)
        self.assertIn("compression-level: 0", self.collect)
        self.assertIn("retention-days: 1", self.collect)
        self.assertIn("app-attest-collector-isolation-unsigned-", self.collect)

    def test_fresh_signer_is_protected_and_candidate_code_free(self) -> None:
        self.assertIn("needs: app-attest-production", self.attest)
        self.assertIn("environment: physical-evidence-signing", self.attest)
        self.assertIn("runs-on: ubuntu-24.04", self.attest)
        for permission in (
            "actions: read",
            "artifact-metadata: write",
            "attestations: write",
            "contents: read",
            "id-token: write",
        ):
            self.assertIn(permission, self.attest)
        for forbidden in ("actions/checkout@", "secrets.", "scripts/", "xcodebuild", "swift "):
            self.assertNotIn(forbidden, self.attest)
        for validation in (
            "jq --exit-status",
            "sha256sum",
            "cmp --silent",
            "find \"$root\"",
            "collector-isolation-validation.json",
            "--deny-self-hosted-runners",
            "caller_supplied_claims_accepted:false",
            "gateway_run_receipt_verified:true",
        ):
            self.assertIn(validation, self.attest)
        self.assertEqual(self.source.count("actions/attest@"), 2)

    def test_final_observer_contract_includes_direct_component_observation(self) -> None:
        self.assertIn(
            "name: app-attest-physical-${{ github.run_id }}-${{ github.run_attempt }}",
            self.attest,
        )
        observer_files = {
            "SHA256SUMS",
            "app-attest-evidence.json",
            "app-attest-junit.xml",
            "app-attest-observation.json",
            "app-attest-profile.json",
            "app-attest-validation.json",
            "component-observation.json",
            "device-inventory.json",
            "gateway-client-policy.json",
            "gateway-deployment-public-key.pem",
            "gateway-deployment-statement.json",
            "gateway-deployment-statement.sig",
            "gateway-deployment-verification.json",
            "github-attestation.sigstore.json",
        }
        for name in observer_files:
            self.assertIn(name, self.attest)
        self.assertIn("retention-days: 30", self.attest)
        self.assertIn("app-attest-collector-isolation-${{ github.run_id }}", self.attest)

    def test_all_actions_are_commit_pinned(self) -> None:
        actions = re.findall(r"(?m)^\s+uses:\s+([^\s#]+)", self.source)
        self.assertGreaterEqual(len(actions), 11)
        for action in actions:
            self.assertRegex(action, r"^[^@]+@[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
