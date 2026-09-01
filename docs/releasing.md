# Releasing the iOS SDK

Stable releases use an annotated `vMAJOR.MINOR.PATCH` tag created, or verified,
only by the evidence-gated `.github/workflows/release.yml` promotion. Operators
must not create or push the tag manually. The tag, `LatchwayVersion.sdk`,
podspec version, changelog section, and checked-out commit must agree.
`contract.lock` must identify a published core contract with an exact commit
and deterministic bundle digest.

Three protected GitHub environments keep release authority disjoint and should
each require an authorized reviewer. `release-administration` supplies only a
fine-grained `LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` with read-only repository
Administration permission. Its fresh no-checkout job proves GitHub immutable
releases are enabled before either registry publication or release mutation.
`cocoapods-trunk` supplies only `COCOAPODS_TRUNK_TOKEN`, and `github-release`
protects the final GitHub-token/OIDC publication job. After the registry result
is sealed, a second no-OIDC administration job rechecks the immutable-release
policy before the final job validates the exact local asset closure and requests
an attestation.

Before promotion, make `Latchway/latchway-ios-sdk` publicly fetchable. The
podspec resolves its source from the public HTTPS Git tag, and advertised
Swift Package Manager consumers resolve the same repository and tag. A private
source repository is therefore not a supported stable-publication state. Also
install an active repository ruleset for `refs/tags/v*`: allow creation only
through the GitHub Actions integration used by the release workflow, and deny
tag updates, deletion, and non-fast-forward changes. These public-visibility
and server-side ruleset controls are external release prerequisites.

The credential-free candidate job runs the complete SwiftPM
build/test/consumer gate and full CocoaPods lint, builds the source archive
twice, compares it byte for byte, and converts the reviewed Ruby podspec to a
closed JSON artifact. A fresh no-checkout publisher validates the exact file
set, sizes, hashes, commit/tag/version binding, source coordinates, subspecs,
and the recursive absence of CocoaPods `prepare_command` and script-phase
hooks. It never extracts or builds the source archive and posts only the
reviewed JSON bytes directly to the Trunk API. Thus downloaded package content
cannot execute while the Trunk token exists. If the coordinate already exists,
the publisher requires the entire CDN podspec JSON to equal the reviewed JSON
before adopting it. The retained CDN fetch permits HTTPS redirects only,
requires TLS 1.2 or newer, and enforces connection, total-time, and
response-size bounds. The exact CDN podspec, reviewed podspec, source-bound
verification record, and checksum manifest are retained beside the source
archive; every retained file receives a GitHub build-provenance attestation in
a separate fresh no-checkout job.

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
