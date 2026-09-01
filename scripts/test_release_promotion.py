#!/usr/bin/env python3
"""Adversarial tests for SDK promotion verification and workflow reachability."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/verify-release-promotion.py"
SPEC = importlib.util.spec_from_file_location("verify_release_promotion", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

REPOSITORY_BY_DIRECTORY = {
    "latchway-js": "javascript",
    "latchway-ios-sdk": "ios",
    "latchway-android": "android",
    "latchway-react-native-sdk": "react_native",
}
REPOSITORY_ID = REPOSITORY_BY_DIRECTORY[ROOT.name]
REPOSITORY_VERSION = "1.2.3"
REPOSITORY_TAG = f"v{REPOSITORY_VERSION}"
CORE_TAG = "v1.0.0"
OCI_DIGEST = "ghcr.io/latchway/latchway@sha256:" + "a" * 64
NOW = datetime(2026, 8, 29, 12, 0, tzinfo=timezone.utc)


class PromotionVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="latchway-sdk-promotion-")
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.write_version()
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Latchway promotion test")
        self.git("config", "user.email", "promotion-test@latchway.invalid")
        self.git("add", ".")
        self.git("commit", "-m", "test: promotion source")
        self.commit = self.git("rev-parse", "HEAD")
        self.report = self.build_report()
        self.report_path = self.root / "promotion.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_version(self) -> None:
        if REPOSITORY_ID in ("javascript", "react_native"):
            self.write(
                self.source / "package.json",
                json.dumps({"name": "@latchway/test", "version": REPOSITORY_VERSION})
                + "\n",
            )
        elif REPOSITORY_ID == "ios":
            self.write(
                self.source / "Sources/Latchway/LatchwayVersion.swift",
                'public enum LatchwayVersion {\n  public static let sdk = "1.2.3"\n}\n',
            )
        else:
            self.write(
                self.source
                / "latchway-core/src/main/kotlin/dev/latchway/core/LatchwayApi.kt",
                'public const val LATCHWAY_SDK_VERSION: String = "1.2.3"\n',
            )

    def build_report(self) -> dict[str, object]:
        repositories = []
        for index, repository_id in enumerate(MODULE.REPOSITORY_IDS):
            version = "1.0.0" if repository_id == "core" else (
                REPOSITORY_VERSION if repository_id == REPOSITORY_ID else f"1.{index}.0"
            )
            commit = self.commit if repository_id == REPOSITORY_ID else f"{index + 1:x}" * 40
            repositories.append(
                {
                    "id": repository_id,
                    "commit": commit,
                    "version": version,
                    "intended_tag": f"v{version}",
                }
            )
        domains = []
        for identifier in (
            "local_source",
            "local_promotion",
            "local_release",
            "live_sdk_conformance",
            "public_tags",
            "public_registries",
            "physical_devices",
            "live_provider",
            "cloud_deployments",
            "operational_resilience",
            "supply_chain",
        ):
            if identifier in MODULE.PROMOTION_DOMAINS:
                domains.append(
                    {
                        "id": identifier,
                        "required": True,
                        "status": "passed",
                        "started_at": "2026-08-29T10:30:00Z",
                        "finished_at": "2026-08-29T11:30:00Z",
                        "document_sha256": hashlib.sha256(
                            identifier.encode("utf-8")
                        ).hexdigest(),
                        "oci_image_digest": OCI_DIGEST,
                        "artifact_sha256": [
                            hashlib.sha256(f"artifact:{identifier}".encode()).hexdigest()
                        ],
                    }
                )
            else:
                required = identifier in ("local_source", "local_promotion")
                domains.append(
                    {
                        "id": identifier,
                        "required": required,
                        "status": "passed" if required else "unverified",
                        "started_at": None,
                        "finished_at": None,
                        "document_sha256": None,
                        "oci_image_digest": None,
                        "artifact_sha256": [],
                    }
                )
        return {
            "schema_version": 1,
            "kind": "latchway_cross_repository_conformance_evidence",
            "scope": "promotion",
            "verdict": "passed",
            "source_conformance_passed": True,
            "promotion_ready": True,
            "release_ready": False,
            "contract": {
                "version": "1.0.0",
                "status": "released",
                "released_at": "2026-08-29T10:00:00Z",
                "wire_protocol": 2,
                "bundle_file_name": "latchway-contract-1.0.0.tar.gz",
                "bundle_sha256": "b" * 64,
                "core_release": CORE_TAG,
                "oci_image_digest": OCI_DIGEST,
            },
            "repositories": repositories,
            "evidence_window": {
                "started_at": "2026-08-29T10:30:00Z",
                "finished_at": "2026-08-29T11:30:00Z",
                "maximum_age_seconds": 604800,
            },
            "evidence_domains": domains,
            "checks": [
                {
                    "id": f"promotion.{domain}",
                    "domain": domain,
                    "required": True,
                    "status": "passed",
                    "summary": f"{domain} evidence passed.",
                }
                for domain in sorted(MODULE.REQUIRED_DOMAINS)
            ]
            + [
                {
                    "id": f"promotion.{domain}",
                    "domain": domain,
                    "required": False,
                    "status": "unverified",
                    "summary": f"{domain} evidence is not part of promotion.",
                    "reason": "not_required_before_publication",
                }
                for domain in sorted(MODULE.UNVERIFIED_DOMAINS)
            ],
        }

    def verify(
        self,
        report: dict[str, object] | None = None,
        *,
        expected_sha256: str | None = None,
        report_url: str | None = None,
        repository_version: str = REPOSITORY_VERSION,
        repository_tag: str = REPOSITORY_TAG,
        workflow_commit: str | None = None,
    ) -> dict[str, str]:
        value = report if report is not None else self.report
        self.write(self.report_path, json.dumps(value, sort_keys=True) + "\n")
        digest = hashlib.sha256(self.report_path.read_bytes()).hexdigest()
        return MODULE.verify(
            self.report_path,
            self.source,
            report_url=report_url
            or (
                "https://github.com/Latchway/latchway/releases/download/"
                f"{CORE_TAG}/latchway-cross-repository-promotion.json"
            ),
            report_sha256=expected_sha256 or digest,
            repository_id=REPOSITORY_ID,
            repository_commit=self.commit,
            repository_version=repository_version,
            repository_tag=repository_tag,
            workflow_commit=workflow_commit or self.commit,
            core_tag=CORE_TAG,
            oci_image_digest=OCI_DIGEST,
            now=NOW,
        )

    def test_accepts_exact_attested_report_binding(self) -> None:
        result = self.verify()
        self.assertEqual(result["release_commit"], self.commit)
        self.assertEqual(result["release_tag"], REPOSITORY_TAG)
        self.assertEqual(result["core_tag"], CORE_TAG)
        self.assertEqual(result["oci_image_digest"], OCI_DIGEST)

    def test_rejects_hash_url_or_default_branch_substitution(self) -> None:
        cases = (
            {
                "expected_sha256": "f" * 64,
                "reason": "promotion_report_sha256_mismatch",
            },
            {
                "report_url": "https://example.invalid/promotion.json",
                "reason": "promotion_report_url_invalid",
            },
            {
                "workflow_commit": "f" * 40,
                "reason": "promotion_dispatch_coordinate_invalid",
            },
        )
        for case in cases:
            reason = case.pop("reason")
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(MODULE.PromotionVerificationError, reason):
                    self.verify(**case)

    def test_rejects_report_shape_coordinate_core_or_digest_substitution(self) -> None:
        mutations = (
            (
                lambda value: value.update(unexpected=True),
                "promotion_report_fields_invalid",
            ),
            (
                lambda value: next(
                    item
                    for item in value["repositories"]
                    if item["id"] == REPOSITORY_ID
                ).update(commit="f" * 40),
                "promotion_repository_binding_mismatch",
            ),
            (
                lambda value: value["contract"].update(core_release="v1.0.1"),
                "promotion_contract_invalid",
            ),
            (
                lambda value: value["contract"].update(
                    oci_image_digest="ghcr.io/latchway/latchway@sha256:" + "f" * 64
                ),
                "promotion_contract_invalid",
            ),
        )
        for mutate, reason in mutations:
            report = deepcopy(self.report)
            mutate(report)
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(MODULE.PromotionVerificationError, reason):
                    self.verify(report)

    def test_rejects_incomplete_domains_failed_checks_and_future_window(self) -> None:
        cases = []
        missing = deepcopy(self.report)
        missing["evidence_domains"] = missing["evidence_domains"][:-1]
        cases.append((missing, "promotion_evidence_domains_invalid"))
        failed = deepcopy(self.report)
        failed["checks"][0]["status"] = "failed"
        cases.append((failed, "promotion_required_check_failed"))
        future = deepcopy(self.report)
        future["evidence_window"]["finished_at"] = "2026-08-29T12:00:01Z"
        cases.append((future, "promotion_evidence_window_invalid"))
        for report, reason in cases:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(MODULE.PromotionVerificationError, reason):
                    self.verify(report)

    def test_rejects_payload_or_local_version_mismatch(self) -> None:
        with self.assertRaisesRegex(
            MODULE.PromotionVerificationError, "promotion_local_version_mismatch"
        ):
            self.verify(repository_version="9.9.9", repository_tag="v9.9.9")

    def test_rejects_dirty_source_duplicate_json_and_symlinked_report(self) -> None:
        self.write(self.source / "untracked.txt", "not part of promoted source\n")
        with self.assertRaisesRegex(
            MODULE.PromotionVerificationError, "promotion_local_worktree_dirty"
        ):
            self.verify()

        duplicate = self.root / "duplicate.json"
        self.write(duplicate, '{"schema_version":1,"schema_version":1}\n')
        with self.assertRaisesRegex(
            MODULE.PromotionVerificationError, "promotion_report_duplicate_key"
        ):
            MODULE.load_json(duplicate)

        regular = self.root / "regular.json"
        self.write(regular, "{}\n")
        symlink = self.root / "symlink.json"
        symlink.symlink_to(regular)
        with self.assertRaisesRegex(
            MODULE.PromotionVerificationError, "promotion_report_file_invalid"
        ):
            MODULE.sha256_file(symlink)

    def test_rejects_inconsistent_or_non_schema_check_evidence(self) -> None:
        cases = []
        missing_required_domain = deepcopy(self.report)
        missing_required_domain["checks"] = [
            check
            for check in missing_required_domain["checks"]
            if check["domain"] != "supply_chain"
        ]
        cases.append((missing_required_domain, "promotion_checks_invalid"))

        invalid_details = deepcopy(self.report)
        invalid_details["checks"][0]["details"] = {"nested": {"too": {"deep": True}}}
        cases.append((invalid_details, "promotion_checks_invalid"))

        premature_publication = deepcopy(self.report)
        public_check = next(
            check
            for check in premature_publication["checks"]
            if check["domain"] == "public_tags"
        )
        public_check["status"] = "passed"
        cases.append((premature_publication, "promotion_checks_invalid"))

        not_ready = deepcopy(self.report)
        not_ready["promotion_ready"] = False
        cases.append((not_ready, "promotion_report_not_ready"))

        stale_contract = deepcopy(self.report)
        stale_contract["contract"]["released_at"] = "2026-08-20T10:00:00Z"
        cases.append((stale_contract, "promotion_contract_invalid"))

        for report, reason in cases:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(MODULE.PromotionVerificationError, reason):
                    self.verify(report)

    def git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.source), *arguments],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    @staticmethod
    def write(path: Path, contents: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")


class ReleaseWorkflowTests(unittest.TestCase):
    def test_only_attested_core_dispatch_can_reach_tag_and_publication(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("repository_dispatch:", workflow)
        self.assertIn("latchway_release_promoted", workflow)
        self.assertNotIn("\n  push:", workflow)
        self.assertNotIn("\n    tags:", workflow)
        self.assertIn("github.event.client_payload.repository.commit", workflow)
        self.assertIn("test \"$GITHUB_SHA\" = \"$SDK_COMMIT\"", workflow)
        self.assertIn(
            "https://github.com/Latchway/latchway/releases/download/$CORE_TAG/"
            "latchway-cross-repository-promotion.json",
            workflow,
        )
        self.assertIn("--proto-redir '=https'", workflow)
        self.assertIn("--max-filesize 2097152", workflow)
        self.assertIn("LATCHWAY_SIBLING_REPOSITORIES_READ_TOKEN || github.token", workflow)
        self.assertIn("latchway-core-release-auth", workflow)
        self.assertIn("trap 'rm -f -- \"$auth_config\"' EXIT", workflow)
        self.assertIn("--config \"$auth_config\"", workflow)
        self.assertIn("rm -f -- \"$auth_config\"", workflow)
        self.assertNotIn('--header "Authorization: Bearer $CORE_READ_TOKEN"', workflow)
        self.assertIn("sha256sum --check --strict", workflow)
        self.assertIn(
            "report_artifact_name: ${{ steps.coordinates.outputs.report_artifact_name }}",
            workflow,
        )
        self.assertIn(
            "name: ${{ steps.coordinates.outputs.report_artifact_name }}", workflow
        )
        self.assertIn(
            "name: ${{ needs.authorize-promotion.outputs.report_artifact_name }}",
            workflow,
        )
        self.assertNotIn(
            "name: sdk-core-promotion-${{ github.run_id }}-${{ github.run_attempt }}",
            workflow,
        )
        self.assertIn(
            "--signer-workflow Latchway/latchway/.github/workflows/"
            "cross-repository-conformance.yml",
            workflow,
        )
        self.assertIn("--source-ref refs/heads/main", workflow)
        self.assertIn("--deny-self-hosted-runners", workflow)
        self.assertIn(
            f"--repository-id {REPOSITORY_ID}",
            workflow,
        )
        self.assertIn(f'test "$SDK_ID" = {REPOSITORY_ID}', workflow)
        self.assertIn("attestations: read", workflow)
        self.assertIn('{tag: $tag, message: $message, object: $object, type: "commit"', workflow)
        self.assertNotIn("git tag ", workflow)
        self.assertNotIn("git push", workflow)
        download = workflow.index("Download and hash the exact core promotion report")
        attestation = workflow.index("Verify the core workflow artifact attestation")
        verifier = workflow.index("python3 scripts/verify-release-promotion.py")
        tag = workflow.index("Create or verify evidence-gated annotated SDK tag")
        self.assertLess(download, attestation)
        self.assertLess(attestation, verifier)
        self.assertLess(verifier, tag)
        publication_markers = {
            "javascript": 'npm publish "$RELEASE_TARBALL"',
            "ios": "https://trunk.cocoapods.org/api/v1/pods?allow_warnings=false",
            "android": "scripts/publish-central.sh",
            "react_native": "node scripts/publish-or-verify.mjs",
        }
        self.assertLess(tag, workflow.index(publication_markers[REPOSITORY_ID]))
        self.assertIn("persist-credentials: false", workflow)
        if REPOSITORY_ID == "javascript":
            self.assertIn("needs: [promote, verify]", workflow)
        elif REPOSITORY_ID in ("ios", "android"):
            self.assertIn("needs: promote", workflow)

    def test_promotion_credentials_never_share_a_runner_with_candidate_code(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        authorization = workflow.split("\n  authorize-promotion:\n", 1)[1].split(
            "\n  verify-promotion:\n", 1
        )[0]
        verification = workflow.split("\n  verify-promotion:\n", 1)[1].split(
            "\n  promote:\n", 1
        )[0]
        following_job = {
            "javascript": "verify",
            "react_native": "locked-sources",
            "ios": "authorize-release",
            "android": "publish",
        }[REPOSITORY_ID]
        tag_mutation = workflow.split("\n  promote:\n", 1)[1].split(
            f"\n  {following_job}:\n", 1
        )[0]

        self.assertNotIn("actions/checkout", authorization)
        self.assertNotIn("scripts/", authorization)
        self.assertNotIn("python3 ", authorization)
        self.assertNotIn("node ", authorization)
        self.assertIn("LATCHWAY_SIBLING_REPOSITORIES_READ_TOKEN", authorization)
        self.assertIn("gh attestation verify", authorization)

        self.assertIn("actions/checkout", verification)
        self.assertIn("python3 scripts/verify-release-promotion.py", verification)
        self.assertNotIn("secrets.", verification)
        self.assertNotIn("GH_TOKEN:", verification)

        self.assertNotIn("actions/checkout", tag_mutation)
        self.assertNotIn("scripts/", tag_mutation)
        self.assertNotIn("python3 ", tag_mutation)
        self.assertNotIn("node ", tag_mutation)
        self.assertIn("GH_TOKEN: ${{ github.token }}", tag_mutation)
        self.assertIn("gh api", tag_mutation)
        self.assertNotIn("GIT_TAG_READ_TOKEN", workflow)
        self.assertNotIn("git_with_auth()", workflow)

    def test_react_native_publication_still_waits_for_all_dependency_releases(self) -> None:
        if REPOSITORY_ID != "react_native":
            self.skipTest("React Native-only dependency ordering")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        dependency = workflow.index("node scripts/verify-published-dependencies.mjs --all")
        publish = workflow.index("node scripts/publish-or-verify.mjs")
        self.assertLess(dependency, publish)
        self.assertIn("needs: [promote, verify, android, ios]", workflow)

    def test_ios_release_is_resumable_without_overwriting_public_state(self) -> None:
        if REPOSITORY_ID != "ios":
            self.skipTest("iOS-only release recovery")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        package = workflow.index("Seal the closed CocoaPods publication candidate")
        transfer = workflow.index(
            "Transfer the closed candidate to the no-checkout CocoaPods publisher"
        )
        registry = workflow.index(
            "Upload the reviewed JSON podspec directly without executing package hooks"
        )
        public_verification = workflow.index(
            "Wait for and retain the exact immutable CocoaPods metadata"
        )
        closure = workflow.index("Validate exact iOS asset closure before OIDC attestation")
        attestation = workflow.index(
            "Attest exact source archive and CocoaPods evidence without candidate checkout"
        )
        reconciliation = workflow.index(
            "Reconcile, publish, and verify immutable release with fixed API calls"
        )
        self.assertLess(package, transfer)
        self.assertLess(transfer, registry)
        self.assertLess(registry, public_verification)
        self.assertLess(public_verification, reconciliation)
        self.assertLess(closure, attestation)
        self.assertLess(attestation, reconciliation)
        self.assertNotIn("--clobber", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("cocoapods-release-evidence.json", workflow)
        self.assertIn("cocoapods-published-podspec.json", workflow)
        self.assertIn("cocoapods-reviewed-podspec.json", workflow)
        self.assertIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", workflow)
        self.assertIn("gh release verify --help", workflow)
        self.assertIn("gh release verify-asset --help", workflow)
        self.assertIn("repos/$GITHUB_REPOSITORY/immutable-releases", workflow)
        self.assertNotIn("python3 scripts/reconcile-github-release.py", workflow)
        trusted = workflow.split("\n  github-release:\n", 1)[1]
        self.assertNotIn("actions/checkout", trusted)
        self.assertNotIn("scripts/", trusted)
        self.assertNotIn("python3 ", trusted)
        self.assertNotIn("node ", trusted)
        self.assertIn("RELEASE_TOKEN:", trusted)
        self.assertIn("gh api", trusted)
        self.assertIn("needs: [promote, publish-cocoapods, github-release-policy]", trusted)
        administration = workflow.split("\n  authorize-release:\n", 1)[1].split(
            "\n  package:\n", 1
        )[0]
        self.assertNotIn("actions/checkout", administration)
        self.assertNotIn("scripts/", administration)
        self.assertNotIn("python3 ", administration)
        self.assertNotIn("node ", administration)
        self.assertNotIn("id-token: write", administration)
        self.assertNotIn("attestations: write", administration)
        self.assertIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", administration)
        self.assertIn("repos/$GITHUB_REPOSITORY/immutable-releases", administration)
        final_policy = workflow.split("\n  github-release-policy:\n", 1)[1].split(
            "\n  github-release:\n", 1
        )[0]
        self.assertNotIn("actions/checkout", final_policy)
        self.assertNotIn("scripts/", final_policy)
        self.assertNotIn("python3 ", final_policy)
        self.assertNotIn("node ", final_policy)
        self.assertNotIn("id-token: write", final_policy)
        self.assertNotIn("attestations: write", final_policy)
        self.assertIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", final_policy)
        self.assertIn("repos/$GITHUB_REPOSITORY/immutable-releases", final_policy)
        self.assertIn("needs: [promote, publish-cocoapods]", final_policy)
        self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", trusted)
        candidate = workflow.split("\n  package:\n", 1)[1].split(
            "\n  publish-cocoapods:\n", 1
        )[0]
        publisher = workflow.split("\n  publish-cocoapods:\n", 1)[1].split(
            "\n  github-release-policy:\n", 1
        )[0]
        self.assertIn("actions/checkout", candidate)
        self.assertIn("scripts/verify-package.sh", candidate)
        self.assertNotIn("secrets.", candidate)
        self.assertNotIn("COCOAPODS_TRUNK_TOKEN", candidate)
        self.assertNotIn("id-token: write", candidate)
        self.assertNotIn("attestations: write", candidate)
        self.assertNotIn("actions/checkout", publisher)
        self.assertNotIn("scripts/", publisher)
        self.assertNotIn("python3 ", publisher)
        self.assertNotIn("pod trunk push", publisher)
        self.assertNotIn("tar -", publisher)
        self.assertNotIn("swift ", publisher)
        self.assertIn("--data-binary", publisher)
        self.assertIn("cocoapods-reviewed-podspec.json", publisher)
        self.assertIn('has("prepare_command")', publisher)
        self.assertIn('has("script_phase")', publisher)
        self.assertIn('has("script_phases")', publisher)
        self.assertIn("COCOAPODS_TRUNK_TOKEN", publisher)
        self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", publisher)
        self.assertNotIn("id-token: write", publisher)
        self.assertNotIn("attestations: write", publisher)
        self.assertIn("latchway-ios-release-${{ needs.promote.outputs.version }}", publisher)
        self.assertIn('find "$root" -mindepth 1 -print', publisher)
        self.assertIn('actual=("$asset_root"/*)', trusted)
        self.assertIn('test "${#actual[@]}" = "${#expected[@]}"', trusted)
        self.assertIn("python3 scripts/build_docs_bundle.py", candidate)
        self.assertIn(
            "latchway-ios-docs-bundle-${{ needs.promote.outputs.version }}",
            candidate,
        )
        self.assertGreaterEqual(
            workflow.count('docs-bundle-$RELEASE_VERSION.tar.gz'),
            3,
        )
        self.assertIn(
            'test "$(sort -u "$RUNNER_TEMP/expected-assets.txt" | wc -l | tr -d \' \')" = 7',
            trusted,
        )
        self.assertIn(
            'cmp --silent "$RUNNER_TEMP/expected-assets.txt" "$RUNNER_TEMP/actual-assets.txt"',
            trusted,
        )
        reconciler = (ROOT / "scripts/reconcile-github-release.py").read_text(encoding="utf-8")
        self.assertIn("repos/{repository}/immutable-releases", reconciler)
        self.assertIn("repos/{repository}/git/ref/tags/{encoded_tag}", reconciler)
        self.assertIn("repos/{repository}/git/tags/{tag_object['sha']}", reconciler)
        self.assertIn('os.environ.pop("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", "")', reconciler)
        self.assertIn("_validate_release_attestation", reconciler)
        self.assertIn("Published GitHub release is mutable", reconciler)
        verifier = (ROOT / "scripts/verify-cocoapods-release.sh").read_text(encoding="utf-8")
        for curl_constraint in (
            "--proto '=https'",
            "--proto-redir '=https'",
            "--tlsv1.2",
            "--connect-timeout 15",
            "--max-time 60",
            "--max-filesize 1048576",
        ):
            self.assertIn(curl_constraint, verifier)
        for retained in (
            "cocoapods-published-podspec.json",
            "cocoapods-reviewed-podspec.json",
            "cocoapods-release-evidence.json",
            "cocoapods-release-evidence.SHA256SUMS",
        ):
            self.assertIn(retained, verifier)
        self.assertIn("source_commit", verifier)
        self.assertIn("reviewed_spec_sha256", verifier)

    def test_ios_cocoapods_surface_is_exact_and_every_subspec_is_consumer_checked(self) -> None:
        if REPOSITORY_ID != "ios":
            self.skipTest("iOS-only CocoaPods surface")
        workflow = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        podspec = (ROOT / "Latchway.podspec").read_text(encoding="utf-8")
        verifier = (ROOT / "scripts/verify-cocoapods-release.sh").read_text(
            encoding="utf-8"
        )
        publisher = (ROOT / "scripts/publish-or-verify-cocoapods.sh").read_text(
            encoding="utf-8"
        )
        package_gate = (ROOT / "scripts/verify-package.sh").read_text(
            encoding="utf-8"
        )
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        consumer_package = (
            ROOT / "IntegrationTests/Consumer/Package.swift"
        ).read_text(encoding="utf-8")
        consumer_source = (
            ROOT / "IntegrationTests/Consumer/Sources/Consumer/main.swift"
        ).read_text(encoding="utf-8")

        expected = {"AppAttest", "AppExtensions", "Core", "FirebaseAuth"}
        declared = set(re.findall(r"spec\.subspec '([^']+)'", podspec))
        self.assertEqual(declared, expected)
        expected_json = '["AppAttest", "AppExtensions", "Core", "FirebaseAuth"]'
        expected_ruby = "%w[AppAttest AppExtensions Core FirebaseAuth]"
        self.assertEqual(workflow.count(expected_json), 2)
        self.assertIn(expected_ruby, verifier)
        self.assertIn(expected_ruby, publisher)
        self.assertIn(expected_ruby, package_gate)
        self.assertIn(
            "for subspec in AppAttest AppExtensions Core FirebaseAuth; do",
            package_gate,
        )
        self.assertIn('--subspec="$subspec"', package_gate)
        for subspec in sorted(expected):
            self.assertIn(f"`Latchway/{subspec}`", readme)
        self.assertIn(
            '.product(name: "LatchwayAppExtensions", package: "Latchway")',
            consumer_package,
        )
        self.assertIn("import LatchwayAppExtensions", consumer_source)

    def test_oidc_permissions_are_confined_to_no_checkout_fixed_jobs(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        headers = list(re.finditer(r"(?m)^  ([a-z0-9_-]+):\n", workflow))
        oidc_jobs: list[tuple[str, str]] = []
        for index, header in enumerate(headers):
            end = headers[index + 1].start() if index + 1 < len(headers) else len(workflow)
            block = workflow[header.start():end]
            if "id-token: write" in block or "attestations: write" in block:
                oidc_jobs.append((header.group(1), block))

        self.assertGreaterEqual(len(oidc_jobs), 1)
        for job_name, block in oidc_jobs:
            self.assertNotIn("actions/checkout", block, job_name)
            self.assertNotIn("scripts/", block, job_name)
            self.assertNotIn("working-directory:", block, job_name)
            self.assertNotIn("python3 ", block, job_name)
            self.assertNotIn("node ", block, job_name)
            self.assertNotIn("./gradlew", block, job_name)
            self.assertNotIn("LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN", block, job_name)
            self.assertNotIn("secrets.", block, job_name)

if __name__ == "__main__":
    unittest.main()
