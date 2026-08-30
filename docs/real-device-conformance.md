# Physical App Attest release evidence

The v1 Apple gate is a production App Attest registration and assertion on a
supported physical Apple device. Simulator, fixture, development-attestation,
Debug, XCTest, debugger-attached, unsigned, and unpinned runs are useful local
checks but are never release evidence.

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
- a second session using the same installation and an App Attest assertion.

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
LATCHWAY_IOS_APP_VERSION
LATCHWAY_IOS_BUILD_NUMBER
LATCHWAY_IOS_TEAM_ID
LATCHWAY_IOS_SIGNING_CERTIFICATE_SHA256
LATCHWAY_IOS_APP_BINARY_SHA256
LATCHWAY_IOS_DISTRIBUTION          # ad_hoc, testflight, or app_store
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
LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL # device_verified or strong_device_verified
LATCHWAY_BASE_URL
LATCHWAY_APPLICATION_ID
LATCHWAY_ENVIRONMENT
LATCHWAY_IDENTITY_PROVIDER
LATCHWAY_FEATURE
LATCHWAY_ERROR_MAPPING_FEATURE     # canonical feature ID guaranteed absent
LATCHWAY_MODEL
LATCHWAY_COLLECTOR_TRUST_ROOT_PEM
LATCHWAY_COLLECTOR_TRUST_ROOT_SHA256
LATCHWAY_DEVICE_GRANT_SHA256
```

`LATCHWAY_APPLICATION_ID` is the generated `app_` resource ID returned by
the Admin API (for example `app_01J00000000000000000000000`), not an
application name or slug.

Configure only these protected secrets:

```text
LATCHWAY_IOS_DEVICE_ID
LATCHWAY_ONE_TIME_DEVICE_GRANT
```

`LATCHWAY_ONE_TIME_DEVICE_GRANT` replaces a reusable identity token. The
provisioner mints it after the workflow run ID and attempt exist. The gateway
must accept it once only and bind its audience to
`latchway-physical-evidence/ios-app-attest`, the source commit, run ID, run
attempt, application, and a unique `jti`; its lifetime and the signed runner
lease are at most one hour, while the grant itself records `issued_at_unix` and
`expires_at_unix` and remains valid for at most five minutes. The protected
SHA-256 is checked before the grant
is exposed to the app. An organization token, PAT, registry credential, cloud
credential, reusable Firebase credential, or OIDC authority is prohibited on
the collector.

## Ephemeral collector and supervisor contract

Before a collector is eligible, the GitHub-hosted `authorize-source` job
checks out the candidate only as data, executes no repository code, records
the exact commit and Git tree for this run/attempt/audience, and creates a
GitHub Sigstore attestation. The collector verifies that bundle with
`--deny-self-hosted-runners` before checking out or executing candidate code.

The JIT image must expose root-owned, non-writable files
`/etc/latchway/physical-collector/lease.json` and `lease.sig`, plus the
root-owned client `/usr/local/libexec/latchway-physical-collector-finalize`.
The ECDSA/SHA-256 lease is signed outside the candidate VM. It binds the exact
repository, commit, source-authorization hash, workflow run/attempt/job and
audience, runner name/image/boot identity, one-job JIT and fresh-workspace
flags, exact app digest, and the one-use grant hash/`jti`/issuance/expiry. It also
asserts that no long-lived, organization, administration, registry, or OIDC
credential exists in the collector.

The finalizer is a client for an authenticated privileged supervisor, not a
signing key or a general-purpose signing command. The private key and gateway
observer capability stay outside the candidate VM. The service ignores
caller-supplied claims, hashes the supplied source/evidence/wipe paths itself,
independently queries the device and the gateway's server-side run receipt,
allows one invocation for the signed lease, deregisters the runner, refuses a
second job, and schedules VM destruction within ten minutes. Candidate code
may cause a denial of service, but it cannot ask the service to sign arbitrary
hashes or a synthetic physical/provider verdict.

The supervisor also owns an out-of-band lease watchdog. Cancellation, timeout,
runner crash, network loss, or a missing finalizer receipt must revoke the JIT
registration, invalidate the one-use grant, wipe/reset the attached device, and
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
signature on the lease and teardown, exact grant/artifact/run coordinates,
device-wipe receipt, evidence-manifest hash, independent supervisor verdict,
and destruction deadline. It attests a
`collector-isolation-validation.json` subject and retains the separate
`app-attest-collector-isolation-<run>-<attempt>` artifact for 30 days; the
observer-compatible physical artifact file set remains unchanged.

The app candidate must be a non-debuggable Release build signed by the pinned
Team ID/certificate with
`com.apple.developer.devicecheck.appattest-environment=production`. Its bundle
ID, version, build, executable SHA-256, and application identifier must exactly
match the protected values. The runner always installs that inspected bundle
immediately before launch; preinstalled applications are rejected.

The gateway must run the exact pinned OCI digest and configuration revision,
reject development/debug attestation, require the expected bundle and Team ID,
and expose a test feature with a bounded model and quota. The supplied identity
is a dedicated non-production user and is passed only in the launched process
environment.

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
reset, one-use gateway grant issuer, post-job VM-destruction log, protected
environments, signed candidate, physical device, and live gateway. The final
artifact plus the external destruction log must refer to the same lease/run.
None of that infrastructure exists merely because this workflow is checked in;
local builds and schema tests never satisfy the physical gate.
