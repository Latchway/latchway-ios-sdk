#!/usr/bin/env python3
"""Enforce credential and OIDC isolation in the physical App Attest workflow."""

from __future__ import annotations

import datetime as dt
import base64
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
import uuid
from types import SimpleNamespace
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "physical-app-attest.yml"
PROJECT = ROOT / "Examples" / "AppAttestConformance" / "Project.swift"
HOST_SOURCE = (
    ROOT / "Examples" / "AppAttestConformance" / "Sources" / "AppAttestConformanceApp.swift"
)
PRODUCER_SOURCE = (
    ROOT / "Examples" / "AppAttestConformance" / "Sources" / "PhysicalComponentProducer.swift"
)
ACTION_SOURCE = (
    ROOT / "Examples" / "AppExtensionComponents" / "Action" / "ComponentActionViewController.swift"
)
SHARED_COMPONENT_SOURCE = (
    ROOT / "Examples" / "AppExtensionComponents" / "Shared" / "ComponentExampleConfiguration.swift"
)
CANDIDATE_BUILDER = ROOT / "scripts" / "build-physical-app-attest-candidate.sh"
CANDIDATE_INSPECTOR = ROOT / "scripts" / "inspect-physical-app-attest-candidate.py"
PHYSICAL_RUNNER = ROOT / "scripts" / "run-physical-app-attest.sh"
INSTALL_VALIDATOR = ROOT / "scripts" / "validate-devicectl-install.py"
INSPECTOR_SPEC = importlib.util.spec_from_file_location(
    "physical_candidate_inspector", CANDIDATE_INSPECTOR
)
assert INSPECTOR_SPEC is not None and INSPECTOR_SPEC.loader is not None
candidate_inspector = importlib.util.module_from_spec(INSPECTOR_SPEC)
INSPECTOR_SPEC.loader.exec_module(candidate_inspector)
tree_helper = sys.modules[candidate_inspector.app_bundle_tree_digest.__module__]
INSTALL_SPEC = importlib.util.spec_from_file_location(
    "devicectl_install_validator", INSTALL_VALIDATOR
)
assert INSTALL_SPEC is not None and INSTALL_SPEC.loader is not None
install_validator = importlib.util.module_from_spec(INSTALL_SPEC)
INSTALL_SPEC.loader.exec_module(install_validator)


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
        cls.project = PROJECT.read_text(encoding="utf-8")
        cls.host_source = HOST_SOURCE.read_text(encoding="utf-8")
        cls.producer_source = PRODUCER_SOURCE.read_text(encoding="utf-8")
        cls.action_source = ACTION_SOURCE.read_text(encoding="utf-8")
        cls.shared_component_source = SHARED_COMPONENT_SOURCE.read_text(encoding="utf-8")
        cls.builder = CANDIDATE_BUILDER.read_text(encoding="utf-8")
        cls.inspector = CANDIDATE_INSPECTOR.read_text(encoding="utf-8")
        cls.runner = PHYSICAL_RUNNER.read_text(encoding="utf-8")

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
        self.assertIn("secrets.LATCHWAY_REGISTRATION_DEVICE_GRANT", self.collect)
        self.assertIn("secrets.LATCHWAY_ASSERTION_DEVICE_GRANT", self.collect)
        self.assertNotIn("secrets.LATCHWAY_ONE_TIME_DEVICE_GRANT", self.collect)
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
            ".grants.registration.single_use == true",
            ".grants.assertion.single_use == true",
            ".grants.registration.issued_at_unix",
            ".grants.assertion.issued_at_unix",
            ".grants.registration.expires_at_unix <= .expires_at_unix",
            ".grants.assertion.expires_at_unix <= .expires_at_unix",
            "(.grants.registration.expires_at_unix - .grants.registration.issued_at_unix) <= 300",
            "(.grants.assertion.expires_at_unix - .grants.assertion.issued_at_unix) <= 300",
            '"latchway-physical-evidence/ios-app-attest/registration"',
            '"latchway-physical-evidence/ios-app-attest/assertion"',
            "source_authorization_sha256",
            "ios_app_binary_sha256",
            "ios_app_bundle_tree_sha256",
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

    def test_component_v2_candidate_execution_isolation_race_and_lifecycle_are_mandatory(self) -> None:
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
            "LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256",
            "LATCHWAY_IOS_APP_ID_PREFIX",
            "LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID",
            "LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL",
            "component-observation.json",
            'latchway.ios-component-observation.v2',
            'widget_delegated_execution.trust_source == "delegated_from_attested_root"',
            'share_delegated_execution.trust_source == "delegated_from_attested_root"',
            'delegated_execution.trust_source == "delegated_from_attested_root"',
            'keychain_sibling_denial.operation == "SecItemCopyMatching"',
            'keychain_sibling_denial.os_status == -34018',
            'keychain_sibling_denial.os_status_name == "errSecMissingEntitlement"',
            "keychain_sibling_denial.key_material_returned == false",
            "component_refresh_race.requests_started_concurrently == true",
            "component_refresh_race.overlap_observed == true",
            "component_refresh_race.results_identical == true",
            'component_keychain_sibling_denied',
            'component_refresh_race',
            '.provider.trust_level == "app_verified"',
            "host_process_running_during_action_request:false",
            "background_execution_observed:true",
            "host_termination_observed:true",
            "user_presence_prompt_observed:false",
        ):
            self.assertIn(marker, self.source)
        self.assertNotIn("latchway.ios-component-observation.v1", self.source)

    def test_source_owned_candidate_embeds_exact_component_topology(self) -> None:
        for target in (
            'name: "AppAttestConformance"',
            'name: "ComponentWidget"',
            'name: "ComponentShare"',
            'name: "ComponentAction"',
        ):
            self.assertIn(target, self.project)
        for point in (
            "com.apple.widgetkit-extension",
            "com.apple.share-services",
            "com.apple.ui-services",
        ):
            self.assertIn(point, self.project)
        self.assertEqual(
            self.project.count('"com.apple.developer.devicecheck.appattest-environment"'),
            1,
        )
        self.assertIn('.string(hostAccessGroup)', self.project)
        self.assertIn('"LatchwayRootKeychainAccessGroup": .string(hostAccessGroup)', self.project)
        self.assertIn("groups != list(sys.argv[2:])", self.runner)
        self.assertIn('expected_groups=[\n                    access_groups["host"]', self.inspector)
        self.assertIn('.string(widgetAccessGroup)', self.project)
        self.assertIn('.string(shareAccessGroup)', self.project)
        self.assertIn('.string(actionAccessGroup)', self.project)

    def test_native_lifecycle_consumes_grants_once_and_resume_cannot_establish(self) -> None:
        for marker in (
            "private actor SingleUseConformanceIdentityProvider",
            "self.token = nil",
            'environment.removeValue(\n            forKey: "LATCHWAY_REGISTRATION_IDENTITY_TOKEN"',
            'environment.removeValue(\n            forKey: "LATCHWAY_ASSERTION_IDENTITY_TOKEN"',
            'unsetenv("LATCHWAY_REGISTRATION_IDENTITY_TOKEN")',
            'unsetenv("LATCHWAY_ASSERTION_IDENTITY_TOKEN")',
            "values.takeRegistrationIdentityProvider()",
            "values.takeAssertionIdentityProvider()",
            "registrationIdentityToken = nil",
            "assertionIdentityToken = nil",
            "UnavailableConformanceIdentityProvider()",
            "grantlessResumeIsValid",
            "PhysicalComponentProducer.loadCheckpoint(runID: runID) != nil",
            "PhysicalComponentProducer.observerCompleted(runID: runID)",
            'trustLevel == "app_verified"',
        ):
            self.assertIn(marker, self.host_source)
        values_initializer = self.host_source.split("init?(\n        environment values:", 1)[1]
        values_initializer = values_initializer.split(
            "mutating func takeRegistrationIdentityProvider", 1
        )[0]
        self.assertNotIn('values["LATCHWAY_REGISTRATION_IDENTITY_TOKEN"]', values_initializer)
        self.assertNotIn('values["LATCHWAY_ASSERTION_IDENTITY_TOKEN"]', values_initializer)
        self.assertNotIn("LaunchEnvironmentIdentityProvider", self.shared_component_source)
        resume = self.host_source.split("private func resumeAfterComponentObservation", 1)[1]
        resume = resume.split("private func authorizedQuotaProbe", 1)[0]
        self.assertLess(
            resume.index("authorizedQuotaProbe(client: client"),
            resume.index("let loadedDiagnostics = await client.diagnostics()"),
        )

    def test_component_producer_and_action_fail_closed_on_delegated_trust(self) -> None:
        for marker in (
            "Set(familyIDs).count == 1",
            "Set(componentIDs).count == diagnostics.count",
            "Set(diagnostics.map(\\.definitionID)).count == diagnostics.count",
            "testIDs == EvidencePolicy.preObserverTests",
            'value.tests.allSatisfy({ $0.status == "passed" })',
            "diagnostic.trustSource == .delegatedFromAttestedRoot",
            "diagnostic.trustExpiresAt.map({ $0 > now }) == true",
            "diagnostic.keyStorage == .secureEnclave",
        ):
            self.assertIn(marker, self.producer_source)
        for marker in (
            "try await client.refresh()",
            "diagnostics.trustSource == .delegatedFromAttestedRoot",
            "diagnostics.keyStorage == .secureEnclave",
            'statusLabel.accessibilityValue = "delegated_from_attested_root"',
        ):
            self.assertIn(marker, self.action_source)
        for forbidden in (
            "LatchwayAppAttest",
            "establishDirectAttestation",
            "delegatedDirectAttested",
        ):
            self.assertNotIn(forbidden, self.action_source)

    def test_candidate_builder_requires_external_signing_and_emits_safe_pins(self) -> None:
        for marker in (
            "LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_SPECIFIER",
            "LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER",
            "LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_SPECIFIER",
            "LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_SPECIFIER",
            "LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID",
            "LATCHWAY_IOS_APP_ID_PREFIX",
            "LATCHWAY_IOS_EXPECTED_SIGNING_CERTIFICATE_SHA256",
            "CODE_SIGN_IDENTITY=",
            "TUIST_LATCHWAY_CODE_SIGN_STYLE=Manual",
            'TUIST_LATCHWAY_IDENTITY_PROVIDER="$LATCHWAY_IDENTITY_PROVIDER"',
            "physical_app_bundle_tree.py",
            "staged application changed after candidate inspection",
            "published application changed during candidate handoff",
        ):
            self.assertIn(marker, self.builder)
        for forbidden in ("security import", "-allowProvisioningUpdates", "create-keychain"):
            self.assertNotIn(forbidden, self.builder)
        for marker in (
            "DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN",
            "DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN",
            "*APP_ATTEST*VERIFICATION*RESOURCE*",
            "*APP_ATTEST*PRIVATE*KEY*",
        ):
            self.assertIn(marker, self.builder)
        for marker in (
            "keychain-access-groups",
            "production App Attest entitlement",
            "profile_uuid",
            "protected_inputs",
            '"LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256"',
            '"app_bundle_tree"',
            '"LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID"',
            '"LATCHWAY_IOS_INSTALL_MODE"',
            '"LatchwayActionFeature"',
            '"LatchwayIdentityProvider"',
            "delegated-only",
            "ApplicationIdentifierPrefix",
            "profile does not authorize the signed Keychain groups",
            '"openssl", "smime", "-verify", "-inform", "der", "-noverify"',
            "expiration.tzinfo is None",
        ):
            self.assertIn(marker, self.inspector)
        staging_rehash = self.builder.index('staged_tree_sha256="$(')
        handoff = self.builder.index('mv "$staging" "$candidate_root"')
        final_rehash = self.builder.index('final_tree_sha256="$(')
        self.assertLess(staging_rehash, handoff)
        self.assertLess(handoff, final_rehash)

    def test_component_observer_phase_relaunch_does_not_receive_grants(self) -> None:
        first_launch = self.runner.index("xcrun devicectl device process launch")
        observer = self.runner.index('"$component_observer_hook" \\\n', first_launch)
        self.assertLess(first_launch, observer)
        between = self.runner[first_launch:observer]
        for marker in (
            "unset DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN",
            "unset DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN",
            'latchway_registration_grant=""',
            'latchway_assertion_grant=""',
            "unset latchway_registration_grant",
            "unset latchway_assertion_grant",
        ):
            self.assertIn(marker, between)
        self.assertIn("--producer-ready-relative-path", self.runner)
        self.assertIn("--observer-completion-relative-path", self.runner)
        self.assertIn("candidate must embed exactly three real app extensions", self.runner)
        self.assertIn("requires exact app_verified trust", self.runner)
        self.assertIn("registration and assertion grants must be distinct", self.runner)

    def test_raw_grants_are_shell_only_until_single_initial_launch(self) -> None:
        repository_setup = self.runner.index('repository_root="$(cd')
        self.assertTrue(self.runner.startswith("#!/bin/bash\nset +x\n"))
        for marker in (
            'latchway_registration_grant="${LATCHWAY_REGISTRATION_IDENTITY_TOKEN:-}"',
            'latchway_assertion_grant="${LATCHWAY_ASSERTION_IDENTITY_TOKEN:-}"',
            "unset LATCHWAY_REGISTRATION_IDENTITY_TOKEN",
            "unset LATCHWAY_ASSERTION_IDENTITY_TOKEN",
            "export -n latchway_registration_grant latchway_assertion_grant",
            'for environment_name in "${!DEVICECTL_CHILD_@}"',
            'for environment_name in "${!LATCHWAY_@}"',
            "unexpected ambient identity or device grant is forbidden",
        ):
            self.assertLess(self.runner.index(marker), repository_setup)

        hash_validation = self.runner.index(
            'actual_registration_grant_sha256="$(printf \'%s\' '
        )
        registration_export = self.runner.index(
            "export DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN="
        )
        self.assertLess(hash_validation, registration_export)
        for marker in (
            'actual_assertion_grant_sha256="$(printf \'%s\' ',
            'actual_registration_grant_sha256" != "$LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256',
            'actual_assertion_grant_sha256" != "$LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256',
            "one-use grants do not match the protected signed hashes",
        ):
            self.assertIn(marker, self.runner[hash_validation:registration_export])

        assertion_export = self.runner.index(
            "export DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN="
        )
        initial_launch = self.runner.index(
            "xcrun devicectl device process launch", assertion_export
        )
        self.assertLess(registration_export, assertion_export)
        for line in self.runner[registration_export:initial_launch].splitlines():
            if line.strip():
                self.assertTrue(line.startswith("export DEVICECTL_CHILD_"), line)
        post_launch = self.runner[initial_launch:]
        for marker in (
            "unset DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN",
            "unset DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN",
            'latchway_registration_grant=""',
            'latchway_assertion_grant=""',
        ):
            self.assertIn(marker, post_launch)
        self.assertIn("export -n registration_grant assertion_grant", self.collect)
        exact_artifacts = (
            ".candidate.artifacts == {ios_app_binary_sha256:$artifact,"
            "ios_app_bundle_tree_sha256:$bundle_tree,"
            "ios_widget_binary_sha256:$widget,ios_share_binary_sha256:$share,"
            "ios_action_binary_sha256:$action}"
        )
        self.assertIn(exact_artifacts, self.collect)
        self.assertIn(exact_artifacts, self.attest)
        self.assertEqual(self.source.count(exact_artifacts), 2)
        for marker in (
            ".candidate.configuration == {application_id:$application,environment:$environment,identity_provider:$identity_provider}",
            ".grants.registration.environment == $environment",
            ".grants.assertion.identity_provider == $identity_provider",
            "validate_signed_lease_before_launch initial",
            "validate_signed_lease_before_launch resume",
        ):
            self.assertIn(marker, self.source + self.runner)

        initial_validation = self.runner.index("validate_signed_lease_before_launch initial")
        first_child_secret = self.runner.index(
            "export DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN="
        )
        self.assertLess(initial_validation, first_child_secret)
        self.assertNotIn("xcrun ", self.runner[initial_validation:first_child_secret])

        assertion_establishment = self.host_source.index(
            "let assertionClient = makeClient("
        )
        extended_tamper = self.host_source.index(
            "var tampered = try await authorizedQuotaProbe"
        )
        self.assertLess(assertion_establishment, extended_tamper)

    def test_signed_tenant_auth_configuration_is_bound_end_to_end(self) -> None:
        for marker in (
            '"LatchwayApplicationID": .string(applicationID)',
            '"LatchwayEnvironment": .string(latchwayEnvironment)',
            '"LatchwayIdentityProvider": .string(identityProvider)',
        ):
            self.assertIn(marker, self.project)
        for marker in (
            "applicationID == signedApplicationID",
            "environment == signedEnvironment",
            "identityProvider == signedIdentityProvider",
            '"latchway_application_id": signedApplicationID',
            '"latchway_environment": signedEnvironment',
            '"identity_provider": signedIdentityProvider',
        ):
            self.assertIn(marker, self.host_source)
        for marker in (
            'actual_latchway_application_id="$(/usr/libexec/PlistBuddy',
            'extension_latchway_application_id="$(/usr/libexec/PlistBuddy',
            '"latchway_application_id": os.environ["LATCHWAY_APPLICATION_ID"]',
            '"latchway_environment": os.environ["LATCHWAY_ENVIRONMENT"]',
            '"identity_provider": os.environ["LATCHWAY_IDENTITY_PROVIDER"]',
        ):
            self.assertIn(marker, self.runner)
        for marker in (
            ".expected_pins.latchway_application_id == $application",
            ".expected_pins.latchway_environment == $environment",
            ".expected_pins.identity_provider == $identity_provider",
            '.name == "latchway_application_id"',
            '.name == "latchway_environment"',
            '.name == "identity_provider"',
        ):
            self.assertIn(marker, self.attest)

    def test_runner_snapshots_and_revalidates_exact_whole_app_tree(self) -> None:
        for marker in (
            "LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256",
            'snapshot_directory="$temporary_root/candidate-snapshot"',
            'ditto --norsrc "$caller_app_bundle_path" "$snapshot_app_bundle_path"',
            'LATCHWAY_IOS_APP_BUNDLE_PATH="$snapshot_app_bundle_path"',
            "physical_app_bundle_tree.py",
            "private application snapshot changed before installation",
        ):
            self.assertIn(marker, self.runner)
        self.assertEqual(self.runner.count("ditto --norsrc"), 1)
        self.assertGreaterEqual(self.runner.count("physical_app_bundle_tree.py"), 2)
        self.assertIn(
            '"application_bundle_tree_sha256": os.environ["LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256"]',
            self.runner,
        )
        self.assertGreaterEqual(
            self.source.count("application_bundle_tree_sha256"), 3
        )
        fixed_receipt = self.attest.split(
            "- name: Validate the fixed receipt, hashes, and coordinates without candidate code",
            1,
        )[1].split("- name: Attest the exact validated profile", 1)[0]
        for marker in (
            "EXPECTED_BUNDLE_TREE_SHA256: ${{ vars.LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256 }}",
            '[[ "$EXPECTED_BUNDLE_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]]',
            ".artifacts.application_bundle_tree_sha256 == $bundle_tree",
            ".application_bundle_tree_sha256 == $bundle_tree",
        ):
            self.assertIn(marker, fixed_receipt)
        snapshot = self.runner.index('ditto --norsrc "$caller_app_bundle_path"')
        signed_validation = self.runner.index("codesign --verify --deep --strict")
        preinstall_recheck = self.runner.index(
            "private application snapshot changed before installation"
        )
        install = self.runner.index("xcrun devicectl device install app")
        self.assertLess(snapshot, signed_validation)
        self.assertLess(preinstall_recheck, install)

    def test_candidate_tools_fail_closed_without_inputs(self) -> None:
        builder = subprocess.run(
            ["bash", str(CANDIDATE_BUILDER)],
            check=False,
            capture_output=True,
            text=True,
        )
        inspector = subprocess.run(
            ["python3", str(CANDIDATE_INSPECTOR)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(builder.returncode, 64)
        self.assertEqual(inspector.returncode, 64)
        self.assertNotIn("Traceback", builder.stderr + inspector.stderr)

    def test_candidate_inspector_uses_verified_profile_fallback(self) -> None:
        payload = plistlib.dumps({"UUID": "00000000-0000-0000-0000-000000000000"})
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Candidate.app"
            bundle.mkdir()
            profile = bundle / "embedded.mobileprovision"
            profile.write_bytes(b"signed-profile")
            responses = [
                SimpleNamespace(returncode=1, stdout=b"", stderr=b"security failed"),
                SimpleNamespace(returncode=0, stdout=payload, stderr=b"verified"),
            ]
            with mock.patch.object(
                candidate_inspector.subprocess, "run", side_effect=responses
            ) as invoked:
                decoded = candidate_inspector.embedded_profile(bundle)
        self.assertEqual(decoded["UUID"], "00000000-0000-0000-0000-000000000000")
        self.assertEqual(invoked.call_count, 2)
        self.assertEqual(invoked.call_args_list[1].args[0][:6], (
            "openssl", "smime", "-verify", "-inform", "der", "-noverify",
        ))

    def test_candidate_inspector_normalizes_naive_profile_expiration_to_utc(self) -> None:
        expiration = dt.datetime.now() + dt.timedelta(days=1)
        normalized = candidate_inspector.validated_profile_expiration(
            {"ExpirationDate": expiration}, "host"
        )
        self.assertEqual(normalized.tzinfo, dt.timezone.utc)

    def test_candidate_inspector_profile_group_authorization_is_exact_or_prefix_wildcard(self) -> None:
        authorize = candidate_inspector.profile_group_authorizes
        self.assertTrue(authorize("ABCD123456.dev.latchway", "ABCD123456.dev.latchway"))
        self.assertTrue(authorize("ABCD123456.*", "ABCD123456.dev.latchway.action"))
        self.assertFalse(authorize("ABCD123456.dev.latchway", "ABCD123456.dev.latchway.action"))
        self.assertFalse(authorize("OTHER12345.*", "ABCD123456.dev.latchway.action"))
        self.assertFalse(authorize("*", ""))

    def test_bundle_tree_hash_binds_content_addition_deletion_and_empty_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Candidate.app"
            bundle.mkdir(mode=0o755)
            executable = bundle / "Candidate"
            executable.write_bytes(b"original")
            executable.chmod(0o755)
            signature = bundle / "_CodeSignature" / "CodeResources"
            signature.parent.mkdir()
            signature.write_bytes(b"signature")
            profile = bundle / "embedded.mobileprovision"
            profile.write_bytes(b"profile")
            resource = bundle / "Resources" / "config.json"
            resource.parent.mkdir()
            resource.write_bytes(b"resource")

            digest = candidate_inspector.app_bundle_tree_digest
            baseline = digest(bundle)
            self.assertEqual(baseline.sha256, digest(bundle).sha256)

            copied = pathlib.Path(directory) / "Copied.app"
            subprocess.run(
                ["ditto", "--norsrc", str(bundle), str(copied)], check=True
            )
            self.assertEqual(baseline.sha256, digest(copied).sha256)

            executable.write_bytes(b"changed")
            self.assertNotEqual(baseline.sha256, digest(bundle).sha256)
            executable.write_bytes(b"original")
            executable.chmod(0o755)
            self.assertEqual(baseline.sha256, digest(bundle).sha256)

            for path, original in (
                (signature, b"signature"),
                (profile, b"profile"),
                (resource, b"resource"),
            ):
                with self.subTest(path=path.name):
                    path.write_bytes(original + b"-changed")
                    self.assertNotEqual(baseline.sha256, digest(bundle).sha256)
                    path.write_bytes(original)
                    self.assertEqual(baseline.sha256, digest(bundle).sha256)

            added = bundle / "added.txt"
            added.write_bytes(b"added")
            self.assertNotEqual(baseline.sha256, digest(bundle).sha256)
            added.unlink()
            self.assertEqual(baseline.sha256, digest(bundle).sha256)

            empty = bundle / "Empty"
            empty.mkdir()
            self.assertNotEqual(baseline.sha256, digest(bundle).sha256)
            empty.rmdir()
            self.assertEqual(baseline.sha256, digest(bundle).sha256)

            executable.chmod(0o700)
            self.assertNotEqual(baseline.sha256, digest(bundle).sha256)
            executable.chmod(0o755)
            self.assertEqual(baseline.sha256, digest(bundle).sha256)

    def test_bundle_tree_rejects_links_special_entries_collisions_and_bounds(self) -> None:
        error = candidate_inspector.BundleTreeError
        reject_collisions = candidate_inspector.assert_no_case_or_nfc_collisions
        with self.assertRaises(error):
            reject_collisions(["Frameworks/Foo", "frameworks/foo"])
        with self.assertRaises(error):
            reject_collisions(["Resources/\N{LATIN SMALL LETTER E WITH ACUTE}", "Resources/e\N{COMBINING ACUTE ACCENT}"])

        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Candidate.app"
            bundle.mkdir()
            payload = bundle / "payload"
            payload.write_bytes(b"1234")
            digest = candidate_inspector.app_bundle_tree_digest
            with self.assertRaises(error):
                digest(bundle, max_expanded_bytes=3)
            with self.assertRaises(error):
                digest(bundle, max_entries=1)
            with self.assertRaises(error):
                digest(bundle, max_depth=0)

            link = bundle / "link"
            link.symlink_to("payload")
            with self.assertRaises(error):
                digest(bundle)
            link.unlink()

            fifo = bundle / "fifo"
            os.mkfifo(fifo)
            with self.assertRaises(error):
                digest(bundle)
            fifo.unlink()

    def test_bundle_tree_rejects_nested_rename_to_symlink_or_directory_swap(self) -> None:
        error = candidate_inspector.BundleTreeError
        digest = candidate_inspector.app_bundle_tree_digest
        for replacement_kind in ("symlink", "directory"):
            with self.subTest(replacement=replacement_kind), tempfile.TemporaryDirectory() as directory:
                bundle = pathlib.Path(directory) / "Candidate.app"
                inner = bundle / "Outer" / "Inner"
                inner.mkdir(parents=True)
                (inner / "payload").write_bytes(b"payload")
                moved = inner.with_name("Inner-original")
                original_open = tree_helper._open_directory_at
                changed = False

                def swapping_open(parent_descriptor, name, expected):
                    nonlocal changed
                    if parent_descriptor is not None and name == "Inner" and not changed:
                        changed = True
                        inner.rename(moved)
                        if replacement_kind == "symlink":
                            inner.symlink_to(moved.name, target_is_directory=True)
                        else:
                            inner.mkdir()
                    return original_open(parent_descriptor, name, expected)

                with mock.patch.object(tree_helper, "_open_directory_at", side_effect=swapping_open):
                    with self.assertRaises(error):
                        digest(bundle)
                self.assertTrue(changed)

    def test_bundle_tree_rejects_regular_file_mutation_after_first_hash_pass(self) -> None:
        error = candidate_inspector.BundleTreeError
        with tempfile.TemporaryDirectory() as directory:
            bundle = pathlib.Path(directory) / "Candidate.app"
            bundle.mkdir()
            payload = bundle / "payload"
            payload.write_bytes(b"before")
            original_digest = tree_helper._regular_file_digest
            changed = False

            def mutate_after_digest(directory_descriptor, name, expected):
                nonlocal changed
                result = original_digest(directory_descriptor, name, expected)
                if not changed:
                    changed = True
                    payload.write_bytes(b"after")
                return result

            with mock.patch.object(
                tree_helper,
                "_regular_file_digest",
                side_effect=mutate_after_digest,
            ):
                with self.assertRaises(error):
                    candidate_inspector.app_bundle_tree_digest(bundle)
            self.assertTrue(changed)

    @staticmethod
    def _devicectl_document(result: dict) -> dict:
        return {
            "info": {
                "arguments": [],
                "commandType": "devicectl",
                "environment": {},
                "jsonVersion": 5,
                "outcome": "success",
                "version": "500.0",
            },
            "result": result,
        }

    def test_install_receipt_binds_persistent_identifier_and_postinstall_identity(self) -> None:
        device_id = str(uuid.uuid4()).upper()
        database_id = str(uuid.uuid4()).upper()
        installation_url = "file:///private/var/containers/Bundle/Application/ABC/AppAttestConformance.app"
        persistent = base64.b64encode(b"launch-services-record").decode("ascii")
        receipt = self._devicectl_document({
            "deviceIdentifier": device_id,
            "installedApplications": [{
                "bundleID": "dev.latchway.conformance",
                "installationURL": installation_url,
                "launchServicesIdentifier": persistent,
                "databaseUUID": database_id,
                "databaseSequenceNumber": 42,
            }],
        })
        inventory = self._devicectl_document({
            "apps": [{
                "appClip": False,
                "builtByDeveloper": True,
                "bundleIdentifier": "dev.latchway.conformance",
                "bundleVersion": "42",
                "defaultApp": False,
                "hidden": False,
                "internalApp": False,
                "name": "Latchway Conformance",
                "removable": True,
                "url": installation_url,
                "version": "1.0.0",
            }],
            "defaultAppsIncluded": False,
            "deviceIdentifier": device_id,
            "hiddenAppsIncluded": False,
            "internalAppsIncluded": False,
            "matchingBundleIdentifier": "dev.latchway.conformance",
            "removableAppsIncluded": True,
        })
        with tempfile.TemporaryDirectory() as directory:
            receipt_path = pathlib.Path(directory) / "receipt.json"
            inventory_path = pathlib.Path(directory) / "inventory.json"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            inventory_path.write_text(json.dumps(inventory), encoding="utf-8")
            result = install_validator.validate_install(
                receipt_path,
                inventory_path,
                bundle_id="dev.latchway.conformance",
                version="1.0.0",
                build="42",
                installation_name="AppAttestConformance.app",
            )
            self.assertEqual(result, persistent)

            for mutation in ("ambiguous", "bundle", "path", "persistent"):
                with self.subTest(mutation=mutation):
                    changed_receipt = json.loads(json.dumps(receipt))
                    changed_inventory = json.loads(json.dumps(inventory))
                    if mutation == "ambiguous":
                        duplicate = dict(changed_receipt["result"]["installedApplications"][0])
                        duplicate["databaseUUID"] = str(uuid.uuid4())
                        changed_receipt["result"]["installedApplications"].append(duplicate)
                    elif mutation == "bundle":
                        changed_inventory["result"]["apps"][0]["bundleIdentifier"] = "dev.latchway.other"
                    elif mutation == "path":
                        changed_inventory["result"]["apps"][0]["url"] = (
                            "file:///private/var/containers/Bundle/Application/XYZ/Replacement.app"
                        )
                    else:
                        changed_receipt["result"]["installedApplications"][0]["launchServicesIdentifier"] = "not-base64"
                    receipt_path.write_text(json.dumps(changed_receipt), encoding="utf-8")
                    inventory_path.write_text(json.dumps(changed_inventory), encoding="utf-8")
                    with self.assertRaises(install_validator.InstallReceiptError):
                        install_validator.validate_install(
                            receipt_path,
                            inventory_path,
                            bundle_id="dev.latchway.conformance",
                            version="1.0.0",
                            build="42",
                            installation_name="AppAttestConformance.app",
                        )

    def test_runner_launches_only_the_strictly_validated_install_receipt(self) -> None:
        for marker in (
            '--json-output "$install_receipt"',
            'postinstall_inventory="$temporary_root/postinstall-apps.json"',
            "validate-devicectl-install.py",
            'launch_persistent_identifier="$(python3',
            '--launch-persistent-identifier "$launch_persistent_identifier"',
        ):
            self.assertIn(marker, self.runner)
        self.assertEqual(
            self.runner.count('--launch-persistent-identifier "$launch_persistent_identifier"'),
            2,
        )

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

    def test_final_observer_contract_includes_delegated_component_observation(self) -> None:
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
