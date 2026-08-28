# Releasing the iOS SDK

Stable releases are created only from an annotated `vMAJOR.MINOR.PATCH` tag.
The tag, `LatchwayVersion.sdk`, podspec version, changelog section, and checked
out commit must agree. `contract.lock` must identify a published core contract
with an exact commit and deterministic bundle digest.

The protected `cocoapods-trunk` GitHub environment supplies
`COCOAPODS_TRUNK_TOKEN` and should require an authorized reviewer. The release
workflow runs the complete SwiftPM build/test/consumer gate and a full CocoaPods
lint, builds the source archive twice and compares it byte for byte, publishes
the pod synchronously, and then polls the CocoaPods CDN. It verifies the public
version, Git source tag, and all three subspecs before creating the GitHub
release. The source archive also receives a GitHub build-provenance attestation.

Swift Package Manager consumes the same immutable Git tag. The GitHub release
is deliberately last: a failed CocoaPods publication or public-registry check
cannot leave a release page that claims the cross-registry operation succeeded.

Physical App Attest completion is a separate release-evidence gate documented
in `real-device-conformance.md`; package publication cannot substitute for it.
