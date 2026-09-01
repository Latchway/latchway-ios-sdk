# Releasing the iOS SDK

Stable releases use an annotated `vMAJOR.MINOR.PATCH` tag created, or verified,
only by the evidence-gated `.github/workflows/release.yml` promotion. Operators
must not create or push the tag manually. The tag, `LatchwayVersion.sdk`,
podspec version, changelog section, and checked-out commit must agree.
`contract.lock` must identify a published core contract with an exact commit
and deterministic bundle digest.

Three protected GitHub environments keep release authority disjoint. Each must
require an authorized reviewer, enable **Prevent self-review**, disable
administrator bypass where GitHub offers it, and allow deployments only from
the exact `main` branch. Each environment also owns the non-secret
`LATCHWAY_RELEASE_CONTROL_POLICY_ID` variable with its unique value:

```text
release-administration = latchway-release-controls-v1:latchway-ios-sdk:release-administration
cocoapods-trunk       = latchway-release-controls-v1:latchway-ios-sdk:cocoapods-trunk
github-release        = latchway-release-controls-v1:latchway-ios-sdk:github-release
```

Never define that reserved variable at repository or organization scope. A
missing referenced GitHub environment is otherwise auto-created without
protections; the first step in every privileged job checks the environment-only
value and fails closed before any action or step uses a credential, requests an
OIDC token, or performs a mutation. `release-administration` supplies only a fine-grained
`LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` with read-only repository Administration
permission. Its fresh no-checkout job proves GitHub immutable releases are
enabled and owner-enforced before either registry publication or release
mutation. `cocoapods-trunk` supplies only `COCOAPODS_TRUNK_TOKEN`, and
`github-release` protects the final GitHub-token/OIDC publication job. After the
registry result is sealed, a second no-OIDC administration job rechecks the
immutable-release policy before the final job validates the exact local asset
closure and requests an attestation. Both administration checks emit a
SHA-256-bound policy lease that names the repository, phase, workflow run, and
run attempt and expires in at most ten minutes. The consumer checks the exact
one-file closure, hash, complete binding, and expiry immediately before every
registry or GitHub mutation, including provenance attestation. If only a
downstream job needs retry after its policy producer succeeded, use
**Re-run all jobs**; a partial or single-job rerun deliberately rejects the
prior attempt's lease.

The privileged names `LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` and
`COCOAPODS_TRUNK_TOKEN` must exist only in their named environments. Never
define either name as a repository secret or as an organization secret visible
to this repository: GitHub secret lookup otherwise falls through to that broader
scope if an environment secret is missing. The central release-control
reconciler rejects that configuration using secret names and visibility only;
it never reads secret values.

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

The public `Latchway/latchway` release asset and attestation are read with the
SDK workflow's read-only `github.token`. Do not configure a sibling-repository
token for this public-core path.

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
