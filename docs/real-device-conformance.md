# Physical App Attest release evidence

The v1 Apple gate is a production App Attest registration and assertion in the
signed containing application, plus independently keyed delegated Widget,
Share, and Action sessions on a supported physical Apple device. iOS App
Attest key generation is unavailable in application extensions, so no iOS
extension is described as directly attested. Simulator, fixture,
development-attestation, Debug, XCTest, debugger-attached, unsigned, and
unpinned runs are useful local checks but are never release evidence.

The dedicated workflow does not manufacture a verdict. It inspects an exact
signed `.app`, verifies its certificate and production entitlement, launches
it on one CoreDevice, retrieves only a redacted observation, validates the
checked-in JSON schema plus release policy, and retains JSON, JUnit, and
checksums. Any missing or mismatched field fails the job.

## What the device suite proves

One run resets the conformance app's isolated SDK state, then records:

- physical-device, Release-build, bundle, version, build, Team ID, certificate,
  source/core commit, contract, gateway image, and gateway configuration pins;
- a canonical, short-lived P-256-signed deployment statement fetched from the
  same gateway origin before and after the run, including the exact App Attest
  client policy and immutable gateway coordinates;
- App Attest support, a fresh production registration, Secure Enclave DPoP
  storage, and an active device-bound session;
- one authorized request, exact DPoP replay rejection as HTTP 401
  `dpop_replayed`, and a bit-tampered proof rejected as HTTP 401
  `dpop_invalid`;
- typed `LatchwayProblem` mapping of HTTP 404 `feature_not_found` for a
  protected nonexistent feature, an explicit refresh whose redacted pre/post
  access-credential hashes differ while its installation hash is stable,
  rejection of protocol version `0` as HTTP 426
  `protocol_version_unsupported`, and server enforcement of installation
  revocation as HTTP 403 `installation_revoked`;
- a bounded streamed request and quota response; and
- a second session using the same installation and an App Attest assertion;
- candidate-bound host, Widget, Share, and Action bundle/definition/executable
  identities, four independent redacted DPoP-key and session identifiers, and
  exact attestation modes (`root_app_attest` for the host and `delegated_only`
  for all three extensions);
- a successful delegated Action request using only the Action DPoP key,
  delegated grant/session, and `delegated_from_attested_root` trust source;
- a concrete HTTP 401 `component_key_invalid` denial when the Action attempts
  to use a Widget or Share sibling session; and
- independent observation that the delegated Action request ran with the containing host not
  running, in background execution, after host termination, and without a user
  presence prompt.

The report includes safe request IDs and app/device/toolchain metadata. It
never includes the identity/access/refresh token, DPoP JWT, App Attest key ID,
attestation/assertion object, private key, prompt response, or provider
credential. The validator rejects secret-shaped values and unknown fields.

## Protected runner contract

Create a GitHub environment named `app-attest-production` with reviewers. Its
self-hosted runner must be a newly booted repository-scoped JIT runner
registered with `--ephemeral`. It has the labels `self-hosted`, `macOS`,
`latchway-physical-ios`, and `latchway-ephemeral-jit`; its one-run name is
exactly `latchway-ios-<run-id>-<run-attempt>`. A reusable runner, a runner that
can accept a second job, or a host with a surviving workspace is ineligible.
The runner has one exclusively attached supported device, the pinned Xcode
identity, and read-only access to the exact signed app candidate.

Configure these protected non-secret variables:

```text
LATCHWAY_XCODE_IDENTITY
LATCHWAY_IOS_APP_BUNDLE_PATH
LATCHWAY_IOS_INSTALL_MODE          # must be install
LATCHWAY_IOS_BUNDLE_ID
LATCHWAY_IOS_WIDGET_BUNDLE_ID
LATCHWAY_IOS_SHARE_BUNDLE_ID
LATCHWAY_IOS_ACTION_BUNDLE_ID
LATCHWAY_HOST_COMPONENT_DEFINITION_ID
LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID
LATCHWAY_SHARE_COMPONENT_DEFINITION_ID
LATCHWAY_ACTION_COMPONENT_DEFINITION_ID
LATCHWAY_IOS_APP_VERSION
LATCHWAY_IOS_BUILD_NUMBER
LATCHWAY_IOS_TEAM_ID
LATCHWAY_IOS_APP_ID_PREFIX         # separate from Team ID when Apple assigns a legacy prefix
LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID
LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_UUID
LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_UUID
LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID
LATCHWAY_IOS_SIGNING_CERTIFICATE_SHA256
LATCHWAY_IOS_APP_BINARY_SHA256
LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256
LATCHWAY_IOS_WIDGET_BINARY_SHA256
LATCHWAY_IOS_SHARE_BINARY_SHA256
LATCHWAY_IOS_ACTION_BINARY_SHA256
LATCHWAY_IOS_DISTRIBUTION          # ad_hoc for the side-loaded physical candidate
LATCHWAY_IOS_SDK_VERSION
LATCHWAY_SOURCE_COMMIT             # exact 40-character candidate commit
LATCHWAY_CORE_COMMIT
LATCHWAY_CONTRACT_VERSION
LATCHWAY_CONTRACT_BUNDLE_SHA256
LATCHWAY_GATEWAY_IMAGE_DIGEST
LATCHWAY_GATEWAY_CONFIGURATION_SHA256
LATCHWAY_GATEWAY_ORIGIN
LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID
LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256
LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_PATH
LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256
LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL # must be app_verified for App Attest
LATCHWAY_BASE_URL
LATCHWAY_APPLICATION_ID
LATCHWAY_ENVIRONMENT
LATCHWAY_IDENTITY_PROVIDER
LATCHWAY_FEATURE
LATCHWAY_ERROR_MAPPING_FEATURE     # canonical feature ID guaranteed absent
LATCHWAY_MODEL
LATCHWAY_COLLECTOR_TRUST_ROOT_PEM
LATCHWAY_COLLECTOR_TRUST_ROOT_SHA256
LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256
LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256
```

`LATCHWAY_APPLICATION_ID` is the generated `app_` resource ID returned by
the Admin API (for example `app_01J00000000000000000000000`), not an
application name or slug.

Configure only these protected secrets:

```text
LATCHWAY_IOS_DEVICE_ID
LATCHWAY_REGISTRATION_DEVICE_GRANT
LATCHWAY_ASSERTION_DEVICE_GRANT
```

The two grants replace a reusable identity token. The provisioner mints both
after the workflow run ID and attempt exist. Registration uses audience
`latchway-physical-evidence/ios-app-attest/registration`; assertion
re-establishment uses the corresponding `/assertion` audience. The gateway
accepts each JWT once only. Each is bound to the source commit, run ID, run
attempt, Latchway application resource ID, environment, identity-provider
identifier, and its own `jti`; the two hashes and `jti` hashes must
be distinct. Their lifetime and the signed runner lease are at most one hour,
while each grant records `issued_at_unix` and `expires_at_unix` and remains
valid for at most five minutes. The workflow checks both protected SHA-256
values before the runner starts, and the runner verifies the signed lease and
both unexpired grant records immediately before the only grant-bearing launch.
Each in-app identity provider is a terminal single-slot actor. Registration,
the minimum replay check, and assertion re-establishment happen first; all
longer protocol/component checks use the already established assertion session.
At script entry the runner copies the two exported
secret values into non-exported shell-only slots and unsets their raw names
before starting any child process. It exports only the two
`DEVICECTL_CHILD_` values for the first host launch, then immediately clears
both child variables and shell-only slots before any extension, observer, or
second host process runs. The post-observer phase has an always-unavailable
identity provider and can only load the persisted assertion session. An organization token, PAT,
registry credential, cloud credential, reusable Firebase credential, or OIDC
authority is prohibited on the collector.

## Ephemeral collector and supervisor contract

Before a collector is eligible, the GitHub-hosted `authorize-source` job
checks out the candidate only as data, executes no repository code, records
the exact commit and Git tree for this run/attempt/audience, and creates a
GitHub Sigstore attestation. The collector verifies that bundle with
`--deny-self-hosted-runners` before checking out or executing candidate code.

The JIT image must expose root-owned, non-writable files
`/etc/latchway/physical-collector/lease.json` and `lease.sig`, plus the
root-owned clients `/usr/local/libexec/latchway-physical-collector-finalize`
and `/usr/local/libexec/latchway-ios-component-evidence-observer`.
The ECDSA/SHA-256 lease is signed outside the candidate VM. It binds the exact
repository, commit, source-authorization hash, workflow run/attempt/job and
audience, runner name/image/boot identity, one-job JIT and fresh-workspace
flags, exact host/Widget/Share/Action executable digests, the deterministic
whole-application bundle-tree digest, and both one-use grant
audiences/application/environment/identity-provider bindings, hashes, `jti`
values, issuance, and expiry. Its exact candidate configuration separately
binds the same three tenant/auth values. It also
asserts that no long-lived, organization, administration, registry, or OIDC
credential exists in the collector.

The external lease provisioner must copy
`ios_app_bundle_tree_sha256` from the reviewed candidate manifest into the
exact `candidate.artifacts` object. It must also emit the exact
`candidate.configuration` object and include the same application,
environment, and identity-provider coordinates in both grant records. A
legacy issuer that omits any of those fields, or a lease containing only the
four executable digests, is rejected by the collector and fresh signer. The
external provisioner and observer therefore must be upgraded to this contract
before a physical v1 release run; repository code cannot update either
root-owned service.

The finalizer is a client for an authenticated privileged supervisor, not a
signing key or a general-purpose signing command. The private key and gateway
observer capability stay outside the candidate VM. The service ignores
caller-supplied claims, hashes the supplied source/evidence/wipe paths itself,
independently queries the device, independently verifies the component
observation, and checks the gateway's server-side run receipt,
allows one invocation for the signed lease, deregisters the runner, refuses a
second job, and schedules VM destruction within ten minutes. Candidate code
may cause a denial of service, but it cannot ask the service to sign arbitrary
hashes or a synthetic physical/provider verdict.

The component observer drives the signed candidate and records observations;
it does not accept lifecycle booleans, trust sources, key/session identities,
or pass claims from workflow inputs. Its run-bound
`component-observation.json` is hashed by the teardown supervisor, revalidated
against the protected candidate pins, and byte-compared with the component
runtime embedded in final evidence. If the observer cannot establish any
no-host/background/termination/no-presence fact, the release gate stays closed.
The observer contract must emit `attestation_mode` for all four identities,
the delegated Action request as `delegated_execution`, and
`host_process_running_during_action_request=false`. An older observer that
emits direct-step-up fields is incompatible and fails schema validation.

The supervisor also owns an out-of-band lease watchdog. Cancellation, timeout,
runner crash, network loss, or a missing finalizer receipt must revoke the JIT
registration, invalidate both one-use grants, wipe/reset the attached device, and
destroy the VM without relying on another workflow step.

Device uninstall and supervisor finalization are separate unconditional
`if: always()` steps. The app is uninstalled and absence is checked even after
a failed collection; finalization still runs if lease, source, toolchain,
grant, collection, or wipe validation fails. Only a signed teardown with
`evidence_eligible=true`, independent device/provider and gateway-receipt
verification, successful app-data wipe, JIT deregistration, no further jobs,
and bounded destruction scheduling can reach the signer. The unsigned
isolation handoff contains the source authorization, signed lease, wipe
receipt, signed teardown, and closed checksum manifests.

Also create a reviewed `physical-evidence-signing` environment. It contains
only the public collector trust root and non-secret expected hashes—no device,
identity, application, runner, provider, or supervisor credential. After the
protected JIT job has collected and validated the candidate, it uploads a
one-day `app-attest-physical-unsigned-<run>-<attempt>` handoff with only
repository-scoped `actions: read` and `contents: read`; that job has no OIDC, attestation, artifact-metadata,
authority. A fresh GitHub-hosted Ubuntu job behind the signing environment
downloads the handoff without checking out source, enforces the exact file set,
per-file and total size limits, `SHA256SUMS`, candidate commit, run/attempt,
platform, physical-device, production-provider, passing-test, and redaction
coordinates using fixed inline shell and `jq`, and only then requests OIDC and
creates the attestation. Protect this environment with independent reviewers
and restrict deployments to `main`.

The signer also verifies the GitHub-hosted source authorization, trust-root
signature on the lease and teardown, exact two-grant/artifact/run coordinates,
device-wipe receipt, evidence-manifest hash, independent supervisor verdict,
and destruction deadline. It attests a
`collector-isolation-validation.json` subject and retains the separate
`app-attest-collector-isolation-<run>-<attempt>` artifact for 30 days. The
observer-compatible physical artifact file set includes the exact component
observation as a separately attested subject.

The app candidate must be a non-debuggable Release build signed by the pinned
Team ID/certificate with
`com.apple.developer.devicecheck.appattest-environment=production`. Its bundle
ID, App ID prefix, version, build, executable SHA-256, whole-bundle tree
SHA-256, profile UUID, and application identifier must exactly match the
protected values. The candidate must also contain exactly one signed
Widget, Share, and Action extension with the protected bundle IDs and
executable hashes. All three extensions are delegated-only and must have no App
Attest entitlement. The runner removes any prior installation, verifies
absence, captures and strictly validates CoreDevice's install receipt, queries
the installed bundle/version/build/path independently, and launches both app
phases with that receipt's `launchServicesIdentifier` via
`--launch-persistent-identifier`. A stale or replacement registration cannot
receive either launch.

Build that installable candidate from a clean exact checkout with
`scripts/build-physical-app-attest-candidate.sh`. The script accepts existing
profile specifiers/UUIDs and signing identity pins from the environment, but
does not import or create Apple assets and never uses
`-allowProvisioningUpdates`. It verifies the host has its root Keychain group
plus all three component groups, while each extension has only its own group;
it rejects App Attest on Widget/Share/Action and requires production App Attest
only on the host. The staged canonical JSON and checksum are the source for the
protected candidate variables. Its `latchway.ios-app-bundle-tree.v1` digest
binds the root, every directory and regular file, canonical relative path,
permission mode, file size, and file content. The inspector rejects symbolic
links, special files, case-folding or NFC path collisions, more than 20,000
entries, more than 1 GiB of expanded regular-file data, and nesting deeper
than 64 components. ACLs, extended attributes, and resource forks are excluded
intentionally; `ditto --norsrc` removes them from the run snapshot. Traversal
uses descriptor-relative `openat`/`O_NOFOLLOW` semantics and verifies each
directory identity and mutation timestamps before and after its descendants,
including the root, so a queued path cannot be swapped to a link or another
directory while it is hashed. Every digest invocation performs two complete,
independent descriptor-relative traversals and accepts the bundle only when
both the digest and all reported tree counters are identical; a mutation that
lands after the first traversal therefore fails closed before the result is
returned.

The collector copies the caller path exactly once into a private `0700`
temporary snapshot, recomputes the protected tree digest before all candidate
inspection, recomputes it again immediately before installation, and installs
that same snapshot. The signed lease contains the exact tree digest in
`candidate.artifacts`, and both the collector and fresh signer require the
same five-field artifact object. Runtime grant values are explicitly rejected
by the builder and never appear in the app, archive metadata, or logs.
The finalized `app-attest-profile.json` exposes the digest as
`application_bundle_tree_sha256`, and `app-attest-evidence.json` repeats that
exact value under `artifacts`; the fresh signer compares both directly with
the protected variable before attesting them. The signed collector-isolation
validation also records the same digest instead of relying only on the lease
file's SHA-256.

### Current Apple provisioning blocker

The first-run Apple account currently has the root `dev.latchway` App ID and a
root profile. That is enough to identify the containing app, but it is not a
signable four-target release candidate. The three explicit child App IDs for
Widget, Share, and Action and their matching installable profiles are still
unavailable. A production App-Attest-entitled host profile, plus a compatible
distribution signing identity/private key, is also unavailable. Those assets
must be supplied
externally and match the builder's bundle, Team, App ID prefix, certificate,
and UUID pins. Until then, only the unsigned generic-device compile gate can
pass; no extension physical proof or release-evidence claim is valid.

Apple App Attest Verification Resources are gateway runtime secrets only.
They must never be passed to the candidate builder, workflow variables, app
process environment, archive metadata, logs, or evidence artifacts.

The gateway must run the exact pinned OCI digest and configuration revision,
reject development/debug attestation, require the expected bundle and Team ID,
and expose a test feature with a bounded model and quota. The supplied identity
belongs to a dedicated non-production user and is represented only by the two
lease-bound, one-use grants passed to the initial launched process environment.

The current cross-repository identity-grant contract does not define a
candidate-bundle-tree claim. Consequently, the signed lease binds each grant
hash and the candidate tree in the same run, but this repository alone cannot
prove that the gateway would reject that grant if a different candidate stole
and consumed it first. Before production release, the external grant issuer
and gateway verifier must define, sign, and enforce the exact
`application_bundle_tree_sha256` claim for both audiences, and the privileged
supervisor receipt must independently attest that enforcement. Until that
issuer/verifier contract exists, candidate-specific grant binding remains an
external release blocker rather than a property claimed by this workflow.

The gateway publishes canonical
`/.well-known/latchway/deployment-statement-v1.json` and its detached DER
ECDSA/SHA-256 signature at the same path ending in `.sig`. The statement is
valid for at most 24 hours and binds the origin, environment, core/contract,
image/configuration, and exact iOS client policy. The runner pins the P-256
public-key SPKI and statement digests, verifies both fetches without redirects,
and rejects any mid-run change.

## Run and verify

Dispatch `Physical App Attest evidence` at the full candidate commit. Do not
rerun this suite casually: it deliberately creates a fresh App Attest key for
the dedicated conformance installation so registration and assertion are both
observed.

The retained artifact contains:

```text
app-attest-evidence.json
app-attest-junit.xml
app-attest-observation.json
app-attest-profile.json
app-attest-validation.json
component-observation.json
device-inventory.json
gateway-client-policy.json
gateway-deployment-public-key.pem
gateway-deployment-statement.json
gateway-deployment-statement.sig
gateway-deployment-verification.json
SHA256SUMS
github-attestation.sigstore.json
```

The final `app-attest-physical-<run>-<attempt>` artifact is produced only by
the isolated signing job. It attests the accepted profile, evidence, and
checksum manifest with GitHub Sigstore and retains the bundle at exactly
`github-attestation.sigstore.json`, as required by the core observer. The
dispatch must run from `main`, and its commit must equal the protected commit,
the dispatch input, and `GITHUB_SHA`.

Revalidate an extracted artifact offline:

```bash
python3 scripts/device-evidence.py verify \
  --schema Conformance/physical-device-evidence.schema.json \
  --profile /path/to/app-attest-profile.json \
  --evidence /path/to/app-attest-evidence.json \
  --component-observation /path/to/component-observation.json \
  --junit /tmp/app-attest-junit.xml \
  --summary /tmp/app-attest-validation.json

python3 scripts/test-verify-gateway-deployment.py
python3 scripts/test-physical-evidence-workflow.py
```

The final cross-repository physical-device document is generated only after
this report, the Play Integrity report, and both React Native reports validate.
The deterministic adapter lives in the React Native repository; hand-written
`physical_devices.json` claims are not accepted as platform proof.

Repository code enforces the signed lease/receipt shapes and refuses evidence
without them, but it does not provision hardware or prove that a hypervisor
actually destroyed a VM after the job ended. Before this is a release gate,
operators must supply and independently audit the JIT registration service,
root supervisor, isolated signing key and observer capability, USB/device
reset, two-audience one-use gateway grant issuer, post-job VM-destruction log, protected
environments, signed candidate, physical device, and live gateway. The final
artifact plus the external destruction log must refer to the same lease/run.
None of that infrastructure exists merely because this workflow is checked in;
local builds and schema tests never satisfy the physical gate.
