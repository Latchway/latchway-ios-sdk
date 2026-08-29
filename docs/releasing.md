# Releasing the iOS SDK

Stable releases are created only from an annotated `vMAJOR.MINOR.PATCH` tag.
The tag, `LatchwayVersion.sdk`, podspec version, changelog section, and checked
out commit must agree. `contract.lock` must identify a published core contract
with an exact commit and deterministic bundle digest.

The protected `cocoapods-trunk` GitHub environment supplies
`COCOAPODS_TRUNK_TOKEN` and should require an authorized reviewer. The release
workflow runs the complete SwiftPM build/test/consumer gate and a full CocoaPods
lint, then builds the source archive twice and compares it byte for byte. If the
coordinate is absent it publishes synchronously; if it already exists, the
workflow requires the entire CDN podspec JSON to equal the reviewed local
podspec before continuing. It also verifies the public version, Git source tag,
and all three subspecs. The source archive receives a GitHub build-provenance
attestation.

Swift Package Manager consumes the same immutable Git tag. The GitHub release
is deliberately last: a failed CocoaPods publication or public-registry check
cannot leave a release page that claims the cross-registry operation succeeded.
An interrupted exact promotion is safely resumable. GitHub release assets are
downloaded and compared byte for byte, only missing draft assets are attached,
and mismatched or incomplete final releases are rejected without overwrite.

Physical App Attest completion is a separate release-evidence gate documented
in `real-device-conformance.md`; package publication cannot substitute for it.
