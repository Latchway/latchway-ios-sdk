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
- a bounded streamed request and quota response; and
- a second session using the same installation and an App Attest assertion.

The report includes safe request IDs and app/device/toolchain metadata. It
never includes the identity/access/refresh token, DPoP JWT, App Attest key ID,
attestation/assertion object, private key, prompt response, or provider
credential. The validator rejects secret-shaped values and unknown fields.

## Protected runner contract

Create a GitHub environment named `app-attest-production` with reviewers. Its
self-hosted runner must have the labels `self-hosted`, `macOS`, and
`latchway-physical-ios`, an unlocked supported device, the pinned Xcode
identity, and access to the exact signed app candidate.

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
LATCHWAY_MODEL
```

`LATCHWAY_APPLICATION_ID` is the generated `app_` resource ID returned by
the Admin API (for example `app_01J00000000000000000000000`), not an
application name or slug.

Configure only these protected secrets:

```text
LATCHWAY_IOS_DEVICE_ID
LATCHWAY_IDENTITY_TOKEN
```

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
```

The workflow attests the accepted profile, evidence, and checksum manifest
with GitHub Sigstore and retains the bundle. The dispatch commit must equal the
protected commit and `GITHUB_SHA`.

Revalidate an extracted artifact offline:

```bash
python3 scripts/device-evidence.py verify \
  --schema Conformance/physical-device-evidence.schema.json \
  --profile /path/to/app-attest-profile.json \
  --evidence /path/to/app-attest-evidence.json \
  --junit /tmp/app-attest-junit.xml \
  --summary /tmp/app-attest-validation.json

python3 scripts/test-verify-gateway-deployment.py
```

The final cross-repository physical-device document is generated only after
this report, the Play Integrity report, and both React Native reports validate.
The deterministic adapter lives in the React Native repository; hand-written
`physical_devices.json` claims are not accepted as platform proof.

Until the protected environment, signed candidate, device, identity, and live
gateway exist, the exact remaining external action is to dispatch the workflow
and retain its accepted artifact. Local builds and schema tests do not satisfy
that gate.
