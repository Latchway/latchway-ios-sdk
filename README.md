# Latchway iOS SDK

SDK **2.0.0** uses the fresh supplied-identity shared-account API. Configure
from either native or React Native first, provide your application's ID token,
and reuse the same native account/session. No Firebase dependency or native auth
bootstrap is required. App-level `try await app.signOut()` keeps the published
sign-out safeguards, including interrupted sign-in and cleanup retry.

This is a source-breaking release: old constructors, callback authorities and
automatic credential-adoption/migration APIs are removed. Older storage is not
imported or silently erased. Current account/session boundaries, signed private
Keychain validation and delegated-only extension restrictions remain.

Requires server 1.1.1+ with `supplied_identity_v1` and shared-native policy;
App Attest `any` acceptance requires server 1.1.3. See
[release notes](docs/release/v2.0.0.md) and
[identity setup](Documentation/SuppliedIdentity.md).

The SDK lets an iOS application call a self-hosted AI gateway without embedding
an upstream provider key. It owns native transport, Secure Enclave/Keychain,
App Attest, DPoP and account-scoped sessions. The application owns authentication
and the gateway owns identity verification, policy, routing and quota.

## Configure, sign in, use

```swift
import Latchway
import LatchwayAppAttest

let app = try await LatchwayApp.configure(.init(
    baseURL: URL(string: "https://gateway.example.com")!,
    applicationID: "app_01J00000000000000000000000",
    environment: "production",
    rootKeychainAccessGroup: "YOURPREFIX.com.example.app",
    suppliedIdentity: try .firebaseProject(projectID: "your-project-id")
))

// The application owns its auth SDK and obtains a current token.
let account = try await app.signIn { try await yourAuth.currentIDToken() }
let client = try await account.makeClient()
let transport = client.transport(feature: "assistant")

var request = URLRequest(url: try transport.endpoint(path: "v1/responses"))
request.httpMethod = "POST"
request.httpBody = requestBody
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
let response = try await transport.bytes(for: request)
do {
    for try await byte in response.bytes {
        consume(byte)
    }
    response.finish()
} catch {
    response.cancel()
    throw error
}
```

Use the actual resolved first Keychain group in the signed root application.
App ID prefixes can differ from Team IDs. Do not pass a build-setting expression
such as `$(AppIdentifierPrefix)` at runtime.

`firebaseProject` formats public issuer/audience metadata; it imports no Firebase
SDK and fetches no token. Generic issuers use
`LatchwaySuppliedIdentityConfiguration(providerID:issuer:audience:tenantID:)`.
The gateway must be configured to verify that provider.

```swift
try await account.updateIdToken { try await yourAuth.currentIDToken() }
try await account.logout() // Offline retirement shared by native and RN.
await client.close()      // Releases this client only.
```

Another surface can use `app.makeClient()` without signing in again.
Application-auth restoration uses `app.restore`; it cannot reverse recorded
logout. A new accepted login calls `signIn`. Expiry suspends protected work with
`identityRefreshRequired` until a valid same-account update. Tokens stay in
native memory only; the application must report external account/token changes.

Read [supplied identity](Documentation/SuppliedIdentity.md) and
[shared apps and extensions](Documentation/SharedNativeApps.md) for cancellation,
opaque account handles, current component handoff and restart behavior.

For local device builds and TestFlight against the same gateway environment,
see [App Attest development and distribution](docs/app-attest-environments.md).

## Requirements and package boundaries

- Swift 6 strict concurrency and iOS 15 or newer.
- Server 1.1.1 or later, contract 1.1.0 / wire 3, discovery
  `supplied_identity_v1` and explicit required-attestation shared-caller policy.
- Real App Attest requires a supported physical device and correctly signed
  application capability/profile. Simulators are not attestation evidence.

Products are `Latchway`, `LatchwayAppAttest`, `LatchwayAppExtensions`,
`LatchwaySwiftOpenAI`, `LatchwayFoundationModels` and `LatchwayTesting`.
The optional `LatchwayFirebaseAuth` token-reader helper remains independent of
Firebase's package graph; it is not a registered auth authority.

SwiftPM is the canonical distribution; CocoaPods exposes corresponding
`Latchway/Core`, `Latchway/AppAttest`, `Latchway/AppExtensions`,
`Latchway/FirebaseAuth` and optional `Latchway/FoundationModels` subspecs.
CocoaPods compiles them into module `Latchway`;
SwiftPM keeps separate modules. The Foundation Models executor requires OS 27
and its matching Xcode toolchain.

Use SwiftPM version 2.0.0 or CocoaPods `pod 'Latchway/AppAttest', '2.0.0'`.
Pair embedded integrations with React Native 2.0.0. Keep one native implementation in
an embedded RN app; adding an independent SPM copy beside the RN pod creates
separate registries and is not supported shared-session setup.

## Storage, logout and extensions

Current source starts in account-scoped storage. It does not adopt previous SDK
sessions or invoke custom migration callbacks. Deny-only extension safety markers
remain checked; they never adopt old credentials. Existing
published tags are not rewritten. This is a fresh model, not an automatic
upgrade/reset of an application's existing Keychain.

Root keys, refresh state and App Attest state remain in the explicitly signed
root-private Keychain group. Current component groups form an immutable,
explicit allowlist. Each extension receives its own key/grant/session and a
non-secret account handoff; it never receives root credentials.

Account logout persists retirement and fences native/RN requests, asynchronous
identity acquisition and response bytes. Cleanup failure remains blocked and
retryable. Component revision checks also prevent a delayed extension process
from reviving retired state. Closing one client releases that client only.
Logout does not call Firebase sign-out, reset per-user quota or revoke another
device. Previously dispatched requests may still be billed.

iOS app extensions remain delegated-only: they cannot generate App Attest keys,
and the containing app must not attest on their behalf. See
[components and app extensions](docs/components-and-app-extensions.md).

## Transport and security

The SDK signs ordinary gateway `URLRequest` values. Feature-bound transport
rejects foreign origins, redirects, provider-secret headers/query parameters
and mismatched feature routes. Access/refresh tokens, evidence and private keys
are never exported as application diagnostics.

Buffered responses are limited to 1 MiB. Streaming remains incremental and
cancellable; call `finish()` after EOF or `cancel()` when stopping. Native
transport retries at most once only for a canonical rejection proving the
request was rejected before upstream dispatch. Duplicate/malformed problems,
ambiguous nonce metadata, partial responses and streamed request bodies are
not replayed. Classification of a retry-candidate problem is capped at 64 KiB.

Keep safe request IDs and canonical error documentation links for diagnostics.
An `operation_indeterminate` operation ID requires reconciliation, not blind
retry. See [architecture](docs/architecture.md) and [SECURITY.md](SECURITY.md).

## Examples and verification

- [Basic URLSession](Examples/BasicURLSession/README.md): supplied identity,
  App Attest and streamed Responses using application-owned auth.
- [LatchwayChat](Examples/LatchwayChat/README.md): temporary chat with native
  URLSession or Foundation Models, Firebase login and weather tools.
- [Foundation Models](Documentation/FoundationModels.md): executor requests,
  schema/tool translation and backend-dependent capabilities.
- [App extensions](Examples/AppExtensionComponents/README.md): current
  account-scoped delegated component scaffold.

```sh
scripts/verify-package.sh
scripts/check-contract.sh ../latchway/api
```

Run matching package, native consumer and contract checks for source changes.
Physical App Attest and extension checks retain their separate
[device runbook](docs/real-device-conformance.md). Historical release/device
receipts do not automatically validate this cleanup. Release procedures are in
[releasing](docs/releasing.md); automatic verification CI remains a separate
repository policy.

Apache License 2.0. See [LICENSE](LICENSE), [NOTICE](NOTICE) and
[CONTRIBUTING.md](CONTRIBUTING.md).
