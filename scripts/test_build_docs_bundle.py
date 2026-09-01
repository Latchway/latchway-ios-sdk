from __future__ import annotations

import gzip
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("build_docs_bundle", ROOT / "scripts/build_docs_bundle.py")
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DocumentationBundleTests(unittest.TestCase):
    def test_full_source_references_and_catalog_contract_are_complete(self) -> None:
        config = json.loads((ROOT / "docs-bundle.config.json").read_text(encoding="utf-8"))
        release_notes = next(item for item in config["documents"] if item["kind"] == "release_notes")["source"]
        for source in (release_notes, *(item["source"] for item in config["examples"])):
            line_count = len((ROOT / source["file"]).read_text(encoding="utf-8").splitlines())
            self.assertEqual(source["start_line"], 1)
            self.assertEqual(source["end_line"], line_count)

        supported = {item["name"] for item in config["supported_versions"]}
        self.assertTrue({
            "SwiftPM product Latchway", "SwiftPM product LatchwayAppAttest",
            "SwiftPM product LatchwayAppExtensions", "SwiftPM product LatchwayFirebaseAuth",
            "SwiftPM product LatchwaySwiftOpenAI", "SwiftPM product LatchwayFoundationModels",
            "SwiftPM product LatchwayTesting", "CocoaPods Latchway/Core",
            "CocoaPods Latchway/AppAttest", "CocoaPods Latchway/AppExtensions",
            "CocoaPods Latchway/FirebaseAuth",
            "iOS", "macOS minimum (Swift Package)", "Swift language", "Swift tools",
            "SwiftOpenAI exact", "Foundation Models compiler minimum",
            "Foundation Models iOS availability", "Foundation Models macOS availability",
            "Foundation Models visionOS availability", "Foundation Models watchOS availability",
            "Foundation Models tvOS availability",
        } <= supported)
        source = (ROOT / "README.md").read_text(encoding="utf-8").splitlines()[25:58]
        product_text = "\n".join(source)
        for product in (
            "Latchway", "LatchwayAppAttest", "LatchwayAppExtensions", "LatchwayFirebaseAuth",
            "LatchwaySwiftOpenAI", "LatchwayFoundationModels", "LatchwayTesting",
            "Latchway/Core", "Latchway/AppAttest", "Latchway/AppExtensions",
            "Latchway/FirebaseAuth",
        ):
            self.assertIn(product, product_text)
        self.assertIn("1.0.0", product_text)

    def test_bundle_is_reproducible_self_describing_and_checksum_bound(self) -> None:
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            archives = []
            for output in (first, second):
                subprocess.run([
                    sys.executable, str(ROOT / "scripts/build_docs_bundle.py"),
                    "--output-dir", output, "--source-date-epoch", "0",
                ], cwd=ROOT, check=True, stdout=subprocess.PIPE, text=True)
                archives.append(Path(output, "docs-bundle-1.0.0.tar.gz"))
            self.assertEqual(archives[0].read_bytes(), archives[1].read_bytes())
            with tarfile.open(archives[0], "r:gz") as archive:
                members = archive.getmembers()
                self.assertEqual([item.name for item in members], sorted(item.name for item in members))
                self.assertTrue(all(item.isfile() and item.uid == item.gid == 0 and item.mode == 0o644 and item.mtime == 0 for item in members))
                payloads = {
                    item.name.split("/", 1)[1]: archive.extractfile(item).read()  # type: ignore[union-attr]
                    for item in members
                }
            manifest = json.loads(payloads["bundle-manifest.json"])
            self.assertEqual(manifest["schema_version"], MODULE.SCHEMA)
            self.assertEqual(manifest["release"]["version"], "1.0.0")
            foundation_models = payloads["frameworks/foundation-models.swift"].decode("utf-8")
            self.assertTrue(foundation_models.startswith(
                "/// A Foundation Models custom provider backed by a feature-bound Latchway\n"
            ))
            self.assertIn("public struct LatchwayLanguageModelExecutor", foundation_models)
            self.assertTrue(foundation_models.endswith(
                "        guard receivedTerminalEvent else {\n"
                "            throw LatchwayFoundationModelsError.invalidGatewayStream\n"
                "        }\n"
                "    }\n"
            ))
            self.assertEqual({item["kind"] for item in manifest["files"]} >= {
                "quickstart", "framework", "release_notes", "supported_versions",
                "public_symbols", "errors", "examples",
            }, True)
            for item in manifest["files"]:
                self.assertEqual(hashlib.sha256(payloads[item["path"]]).hexdigest(), item["sha256"])
                self.assertTrue(item["provenance"])
                for source in item["provenance"]:
                    self.assertEqual(source["repository"], manifest["repository"])
                    self.assertEqual(source["release"], manifest["release"]["tag"])
                    self.assertRegex(source["commit"], r"^[0-9a-f]{40}$")
                    self.assertLessEqual(source["region"]["start_line"], source["region"]["end_line"])
                    source_bytes = Path(ROOT, source["file"]).read_bytes()
                    source_lines = source_bytes.decode("utf-8").splitlines(keepends=True)
                    region = "".join(source_lines[
                        source["region"]["start_line"] - 1:source["region"]["end_line"]
                    ]).encode("utf-8")
                    self.assertEqual(hashlib.sha256(source_bytes).hexdigest(), source["source_sha256"])
                    self.assertEqual(hashlib.sha256(region).hexdigest(), source["region_sha256"])
            checksums = {}
            for line in payloads["SHA256SUMS"].decode("ascii").splitlines():
                digest, name = line.split("  ", 1)
                checksums[name] = digest
            self.assertEqual(set(checksums), set(payloads) - {"SHA256SUMS"})
            for name, digest in checksums.items():
                self.assertEqual(hashlib.sha256(payloads[name]).hexdigest(), digest)
            catalogs = {}
            for name, key in (("supported-versions.json", "versions"), ("public-symbols.json", "symbols"), ("errors.json", "errors"), ("examples.json", "examples")):
                catalogs[name] = json.loads(payloads[name])[key]
                self.assertTrue(catalogs[name])
            for name in ("public-symbols.json", "errors.json"):
                for row in catalogs[name]:
                    source = row["source"]
                    line = (ROOT / source["file"]).read_text(encoding="utf-8").splitlines()[
                        source["region"]["start_line"] - 1
                    ]
                    self.assertIn(row["name"], line)
            symbols = {row["name"] for row in catalogs["public-symbols.json"]}
            self.assertTrue({
                "latchwayFirebaseIdentityToken", "saveCount", "clearCount", "signatureCount",
                "challenges", "acceptedEvidence", "resetCount", "requests",
            } <= symbols)
            errors = {row["name"] for row in catalogs["errors.json"]}
            self.assertTrue({
                "componentGrantExpired", "keychainAccessGroupUnavailable",
                "componentKeyUnavailable", "directAttestationRequired",
            } <= errors)

    def test_path_validation_and_archive_verifier_reject_traversal(self) -> None:
        for value in ("/absolute", "../escape", "a/../escape", "a\\b"):
            with self.assertRaises(MODULE.BundleError):
                MODULE.safe_relative(value)
        with tempfile.TemporaryDirectory() as temporary:
            malicious = Path(temporary, "malicious.tar.gz")
            with malicious.open("wb") as output:
                with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
                    with tarfile.open(fileobj=compressed, mode="w") as archive:
                        payload = b"unsafe"
                        info = tarfile.TarInfo("../escape")
                        info.size = len(payload)
                        archive.addfile(info, io.BytesIO(payload))
            with self.assertRaises(MODULE.BundleError):
                MODULE.verify_archive(malicious, "docs-bundle-1.0.0")

    def test_provenance_commit_must_equal_the_checked_out_source(self) -> None:
        with tempfile.TemporaryDirectory() as output:
            with self.assertRaisesRegex(MODULE.BundleError, "checked-out source commit"):
                MODULE.build(MODULE.DEFAULT_CONFIG, Path(output), None, "0" * 40, 0, False)


if __name__ == "__main__":
    unittest.main()
