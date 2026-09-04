# Releasing the iOS SDK

Stable releases use an annotated `vMAJOR.MINOR.PATCH` tag created, or verified,
only by the evidence-gated `.github/workflows/release.yml` promotion. Operators
must not create or push the tag manually. The tag, `LatchwayVersion.sdk`,
podspec version, changelog section, and checked-out commit must agree.
`contract.lock` must identify a published core contract with an exact commit
and deterministic bundle digest.

## Single-maintainer v1 publication profile

`single-maintainer-release.yml` is the explicit lower-assurance launch path for
`1.0.0`. It accepts only the exact `main` commit, the released core lock, the
`single_maintainer_v1` profile, and the confirmation phrase
`publish-v1.0.0-with-deferred-assurance`. The complete Swift package, consumer,
offline security, dependency, and all-four-subspec CocoaPods gates run before
the public annotated tag is created. The workflow then builds the deterministic
tag archive, publishes the CocoaPods specification or adopts an existing
canonical JSON-identical specification, and
creates an exact GitHub release labeled as deferred assurance. It never claims
independent review, full evidence gating, or release-qualified status.

Create a `single-maintainer-v1` GitHub environment restricted to `main`, and
define its environment-only `LATCHWAY_RELEASE_CONTROL_POLICY_ID` variable as
exactly
`latchway-release-controls-v1:latchway-ios-sdk:single-maintainer-v1`. The first
step of every job that names this environment checks that sentinel before any
checkout, credential access, OIDC request, or mutation, so a missing environment
cannot be silently auto-created without the intended controls. If `Latchway
1.0.0` is absent from CocoaPods, that environment must contain only the
`COCOAPODS_TRUNK_TOKEN` secret needed by the protected publication job. A
working local `pod trunk me` session is not available inside GitHub Actions and
does not satisfy this requirement. If an authorized maintainer publishes the
already-gated exact pod locally instead, a later workflow run needs no token
only when the CDN specification is canonical JSON-identical to the reviewed
specification; it adopts rather than overwrites that immutable coordinate. Raw
registry formatting bytes may differ and are recorded separately.

The CocoaPods publisher is a fresh Linux job with no source checkout. The
macOS package job converts the Ruby podspec to inert reviewed JSON and seals an
exact seven-file manifest. Before the Trunk credential is referenced, the
publisher verifies the fixed file closure, sizes, hashes, commit/tag/version
binding, source coordinate, four subspecs, and absence of CocoaPods execution
hooks. If upload is needed, it writes the token to a temporary curl
configuration, unsets the environment variable, and posts only the reviewed
JSON bytes. Candidate scripts and Ruby podspec code never run while the token
exists. The final publisher validates an exact ten-file release closure before
requesting OIDC or attaching any asset.

```bash
gh workflow run single-maintainer-release.yml --ref main \
  -f release_profile=single_maintainer_v1 \
  -f release_commit="$(git rev-parse HEAD)" \
  -f release_version=1.0.0 \
  -f confirmation=publish-v1.0.0-with-deferred-assurance
```

The additive workflow treats one workflow run as the transaction owner. Its
intent hash binds the run ID and run attempt into the annotated tag. Before the
tag exists, the intent job rejects any pre-existing `v1.0.0` tag unless that
tag belongs to this exact transaction. Once the tag, CocoaPods coordinate, or
GitHub draft has been created, resume only with **Re-run failed jobs** on that
same workflow run. Never use **Re-run all jobs** and never start a new workflow
dispatch after a mutation: either action creates a different intent and the
early tag-owner guard fails closed. The prerequisite intent and package
artifacts are retained for 90 days so a same-run failed-job retry can adopt
only exact bytes. The GitHub publisher creates an empty draft, adopts any exact
partial draft asset-by-asset, downloads and byte-compares every asset, and
publishes the draft only after the remote closure is exact; it never overwrites
an existing asset.

Before any SDK tag or registry mutation, the workflow downloads the public core
`v1.0.0` release and requires the `single_maintainer_v1` core-publication record
to be exact. It verifies the candidate, vulnerability/license scans, SBOMs,
Sigstore attestations, annotated core tag, and image digest in the exact
registry-only 11-asset closure. The signed record must have
`deployment_evidence: {}` and the exact `cloud_deployments` deferred entry;
deployment archives and claims that Compose, Cloud Run, or another target
passed are rejected. The core commit locked by `contract.lock` must be an
ancestor of that public core release. Cloud deployments, devices, providers,
and independent review remain explicitly deferred; they are not silently
treated as passed.

This selected profile has no prepublication Administration-token job or
`single-maintainer-v1-administration` environment. The tag may therefore be
created before GitHub proves the repository's immutable-release setting; that
is an explicit assurance reduction, not evidence that the setting passed. The
final publisher still requires an unchanged release ETag, exact asset and tag
closure, `immutable: true`, and successful release and per-asset attestation
verification before it reports success.

## Strict full publication profile

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
protections; the first step in every job that names one of these protected
environments checks the environment-only
value and fails closed before any action or step uses a credential, requests an
OIDC token, or performs a mutation. `release-administration` supplies only a fine-grained
`LATCHWAY_GITHUB_RELEASE_ADMIN_TOKEN` with read-only repository Administration
permission. Its fresh no-checkout job proves GitHub immutable releases are
enabled and owner-enforced before either registry publication or release
mutation. `cocoapods-trunk` supplies only `COCOAPODS_TRUNK_TOKEN`, and
`github-release` protects both the evidence-gated promotion job that creates or
verifies the annotated tag and the final GitHub-token/OIDC publication job.
After the registry result is sealed, a second no-OIDC administration job
rechecks the
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
