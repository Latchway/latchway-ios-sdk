# iOS component key, access-group, background, and refresh strategy

Date: 2026-08-30

Decision: accept the source architecture and local compile/unit evidence.
Apple does not make App Attest key generation available to ordinary iOS app
extensions, so those components are delegated-only rather than awaiting a
future direct-attestation device result. Do not treat entitlement isolation,
Secure Enclave operation, background signing, or lifecycle cleanup as release
evidence until the signed physical-device matrix passes.

## Installation-family boundary

One signed-in app installation is an Installation Family. The attested main app
is the root Client Component. Each WidgetKit, share, App Intent, notification,
or other executable is a separate component with its own P-256 key, component
credential/refresh chain, feature scope, audit identity, and revocation
boundary.

The containing app creates or replaces a component key and registers only its
public JWK. An extension opens the already provisioned component key with key
creation disabled. It cannot access the root key/session and cannot mint an
orphan component key. Component refresh/session state is bound to the family,
component definition/kind/platform/ID, key thumbprint, delegated feature set,
trust source/parent/delegation, and bounded expiry.

App Attest belongs only to the containing root app in this architecture. The
installed Apple SDK documents that `DCAppAttestService.generateKey` fails when
called from an ordinary iOS application extension (with a separate watchOS 9+
exception that this package does not implement). Therefore Widget, Share,
Action, App Intent, SSO, and notification extensions must use delegated trust:
the host attests itself, prepares each component's independent DPoP key and
delegated grant, and the extension uses only that component session. The host
must not attest on an extension's behalf, and ordinary iOS extension targets
must not carry the App Attest entitlement.

## Key and Keychain decision

- Prefer `SecureEnclave.P256.Signing.PrivateKey`; its persisted data is a
  restorable Secure Enclave representation, not raw P-256 private scalar
  material. Only signing and public-JWK operations are exposed.
- Software P-256 is allowed only by explicit configuration and is stored in
  Keychain. Tightening policy to disallow software rejects and clears an old
  software key rather than silently restoring it.
- Every Keychain operation sets `kSecAttrSynchronizable` false. New values use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which permits background
  access after the first device unlock and prevents migration through Keychain
  synchronization or backup.
- No user-presence or biometry access-control flag is requested, because an
  extension or background task cannot present an interaction prompt. This is a
  deliberate background-signing requirement, not an authentication UI.
- Assign one access group per component. The host and that component share the
  group; siblings do not. Runtime configuration requires the fully expanded
  signed value and rejects unresolved `$(...)` build-setting tokens.
- Key and component credential use a service namespace containing application,
  environment, and definition identifiers. The extension re-reads Keychain on
  use, so a long-lived process cannot continue with an in-memory key after the
  containing app replaces it.

## Refresh and failure strategy

`LatchwayExtensionClient` is an actor and publishes one `refreshTask` before
the shared Keychain read. Concurrent first-use or refresh callers await that
single flight. A caller canceled during the exchange receives no authorized
headers, while successful shared work may still populate the actor cache for a
later caller.

Initial provisioning grants and ordinary refresh tokens have different
persistence failure behavior:

- A one-time provisioning grant that was consumed but whose rotated result
  cannot be saved is cleared. The containing app must provision again.
- If an ordinary refresh response cannot be saved, the old refresh token stays
  stored. The next attempt sends the same refresh-token/component/key tuple so
  a server implementing the contract's bounded exact-tuple idempotency window
  can recover the same rotation result. It creates a new DPoP proof; it does not
  replay a data-plane request.
- A refresh-reuse, component-revoked, key-replaced, session-revoked, or family-
  revoked response retires the appropriate local state. Component and family
  APIs attempt all requested Keychain cleanup even when one group fails.

Data-plane requests reject foreign origins, effective-port differences,
redirects, paths outside the configured gateway `/v1` namespace, encoded path
escapes, provider credential aliases, and spoofed framework headers before any
secret header is added. Buffered replay is allowed at most once and only after
canonical pre-dispatch rejection evidence. Streaming and body streams are not
automatically replayed.

## Local proof

Apple Swift 6.4 / Xcode 27.0 validation on 2026-08-30:

```bash
swift test --scratch-path /tmp/latchway-ios-addendum-build
# LatchwayTests: 68 passed, including 9 component-session and 6 key tests
# LatchwayAppAttestTests: 19 passed
# ConformanceTests: 3 passed
# LatchwaySwiftOpenAITests: 5 passed
# LatchwayAppExtensionsTests: 3 passed
# Foundation Models availability test: skipped on macOS 14

pod lib lint Latchway.podspec --platforms=ios \
  --subspec=AppExtensions --fail-fast
# Latchway passed validation

tuist generate --path Examples/AppExtensionComponents --no-open
# Project generated

xcodebuild -quiet \
  -workspace Examples/AppExtensionComponents/AppExtensionComponents.xcworkspace \
  -scheme AppExtensionComponents -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/latchway-component-example-derived \
  CODE_SIGNING_ALLOWED=NO build
# Build succeeded
```

The tests cover a 24-caller single flight, cancellation before credential
return, exact-tuple refresh recovery, one-time grant persistence failure,
binding mismatch/reuse retirement, extension no-key-creation, fallback-policy
hardening, redacted diagnostics, unresolved access-group rejection, and
destination/credential/path/framework-header rejection.

Local readiness checks also found a paired, available iPhone 16 Pro through
`xcrun devicectl list devices` and one valid Apple Development identity through
`security find-identity -v -p codesigning`. Those checks prove only that a
device and signing identity are present; no signed conformance run was claimed.

## Pending physical evidence

A protected release run still needs real Admin API values and a deployed
gateway: canonical application/environment IDs, a `home_widget` component
definition and feature policy, signed host/extension bundle IDs, the resolved
component-specific access groups, and a fresh identity token supplied only to
the host process. Run from clean, reviewable source and retain machine-readable
evidence for:

- Secure Enclave creation/restoration and explicit software fallback reporting;
- host-to-intended-extension retrieval plus denial from at least one sibling;
- signing and refresh after backgrounding and while the device is locked after
  its first unlock, without an interaction prompt;
- slow streaming, cancellation, redirect rejection, and bounded memory;
- component replacement, component revocation, and complete family sign-out;
- reinstall migration behavior and uninstall cleanup; and
- App Attest root proof in the containing app followed by delegated-only
  component session establishment, with no extension `generateKey` attempt or
  host attestation on an extension's behalf.

An unsigned generic iOS build, a simulator test, a connected device, or a
present signing identity does not satisfy any of those physical claims.
