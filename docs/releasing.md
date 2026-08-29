# Releasing the iOS SDK

Stable releases are created only from an annotated `vMAJOR.MINOR.PATCH` tag.
The tag, `LatchwayVersion.sdk`, podspec version, changelog section, and checked
out commit must agree. `contract.lock` must identify a published core contract
with an exact commit and deterministic bundle digest.

The protected `cocoapods-trunk` GitHub environment supplies
`COCOAPODS_TRUNK_TOKEN` and a fine-grained
`LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` with read-only repository Administration
permission; it should require an authorized reviewer. The latter preflights
GitHub's immutable-release setting before any draft or asset mutation. The release
workflow runs the complete SwiftPM build/test/consumer gate and a full CocoaPods
lint, then builds the source archive twice and compares it byte for byte. If the
coordinate is absent it publishes synchronously; if it already exists, the
workflow requires the entire CDN podspec JSON to equal the reviewed local
podspec before continuing. It also verifies the public version, Git source tag,
and all three subspecs. The exact CDN podspec, reviewed podspec, source-bound
verification record, and checksum manifest are retained beside the source
archive; every retained file receives a GitHub build-provenance attestation.

Swift Package Manager consumes the same tag locked by GitHub's immutable
release. The GitHub release is deliberately last: a failed CocoaPods
publication or public-registry check cannot leave a release page that claims
the cross-registry operation succeeded. An interrupted exact promotion is
safely resumable. All assets are attached to a draft, downloaded and compared
byte for byte, and only then published. The workflow requires the resulting
API record to be immutable; mismatched or incomplete releases are rejected
without overwrite. Finally, `gh release verify` and `gh release verify-asset`
cryptographically verify GitHub's automatic immutable-release attestation and
each exact local asset.

Physical App Attest completion is a separate release-evidence gate documented
in `real-device-conformance.md`; package publication cannot substitute for it.
