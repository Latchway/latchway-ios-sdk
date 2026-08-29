# Releasing the iOS SDK

Stable releases are created only from an annotated `vMAJOR.MINOR.PATCH` tag.
The tag, `LatchwayVersion.sdk`, podspec version, changelog section, and checked
out commit must agree. `contract.lock` must identify a published core contract
with an exact commit and deterministic bundle digest.

The protected `cocoapods-trunk` GitHub environment supplies
`COCOAPODS_TRUNK_TOKEN` and a fine-grained
`LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` with read-only repository Administration
permission; it should require an authorized reviewer. The latter preflights
GitHub's immutable-release setting before any CocoaPods publication, draft, or
asset mutation. This preflight also requires a GitHub CLI version that supports
automatic immutable-release and asset verification. During reconciliation, the
administration token is consumed only by the settings request and removed from
the environment before later GitHub subprocesses run. The release workflow runs
the complete SwiftPM build/test/consumer gate and a full CocoaPods lint, then
builds the source archive twice and compares it byte for byte. If the coordinate
is absent it publishes synchronously; if it already exists, the workflow
requires the entire CDN podspec JSON to equal the reviewed local podspec before
continuing. The retained CDN fetch permits HTTPS redirects only, requires TLS
1.2 or newer, and enforces connection, total-time, and response-size bounds. It
also verifies the public version, Git source tag, and all three subspecs. The
exact CDN podspec, reviewed podspec, source-bound verification record, and
checksum manifest are retained beside the source archive; every retained file
receives a GitHub build-provenance attestation.

If the core repository is private, configure
`LATCHWAY_SIBLING_REPOSITORIES_READ_TOKEN` as a fine-grained Contents: read
credential for `Latchway/latchway`. It authenticates only the pinned promotion
asset download and attestation verification, is never persisted by checkout,
and is unnecessary when the core repository is public.

Swift Package Manager consumes the same tag locked by GitHub's immutable
release. The GitHub release is deliberately last: a failed CocoaPods
publication or public-registry check cannot leave a release page that claims
the cross-registry operation succeeded. An interrupted exact promotion is
safely resumable. All assets are attached to a draft, downloaded and compared
byte for byte, and only then published. The workflow requires the resulting
API record to be immutable; mismatched or incomplete releases are rejected
without overwrite. Finally, `gh release verify` and `gh release verify-asset`
cryptographically verify GitHub's automatic immutable-release attestation and
each exact local asset. The reconciler resolves the remote annotated tag object
and requires its target to equal the promoted commit immediately before draft
creation and again immediately before finalization. It parses the signed release
statement and requires that same commit plus every exact asset digest. Automatic
attestation propagation is retried for a bounded interval; a successful command
with empty, malformed, or unexpected JSON is rejected immediately.

Physical App Attest completion is a separate release-evidence gate documented
in `real-device-conformance.md`; package publication cannot substitute for it.
