# Installation Families and iOS app extensions

Latchway models one signed-in app installation as an Installation Family. The
main app is the attested root Client Component; every widget, share extension,
App Intent extension, or notification service that uses Latchway is a separate
Client Component with its own P-256 key, feature scope, refresh chain, usage,
audit identity, and revocation boundary.

The root token and root key are never copied into an extension. A containing
app registers only a component public JWK and stores the returned one-time
provisioning grant beside that component's native key reference. The extension
can then establish and rotate only its own session. If that key is absent, the
extension fails closed instead of minting an orphan replacement; only the
containing app creates or replaces component keys.

## Entitlements and runtime configuration

Give each executable component a distinct Keychain access group. Put the same
group in the containing app and the intended extension, and do not add it to a
sibling extension:

```xml
<key>keychain-access-groups</key>
<array>
  <string>$(AppIdentifierPrefix)com.example.myapp.weekly-widget</string>
</array>
```

Xcode expands `$(AppIdentifierPrefix)` while signing. The Swift runtime value
must already be fully resolved, for example
`ABCDE12345.com.example.myapp.weekly-widget`. Passing the literal build-setting
token fails closed. Do not use one broad group for every extension.

Define the descriptor identically in both processes:

```swift
let weeklyWidget = LatchwayComponentConfiguration.widget(
    definitionID: "weekly_widget",
    keychainAccessGroup: resolvedAccessGroup,
    requestedFeatures: ["weekly-summary"]
)
```

The Admin API owns the component definition, kind, allowed feature ceiling,
delegation policy, and direct-attestation requirements. Client configuration
can request less authority but cannot expand server policy.

## Containing-app provisioning

After the root client has authenticated and attested, prepare the complete
component set:

```swift
let diagnostics = try await rootClient.prepareComponents([weeklyWidget])
```

Preparation is safe to call again. The SDK reuses state only when the family,
component key, configured request scope, trust lifetime, and rotating grant are
still valid. A family change or explicit replacement erases the prior local
key and obtains a new component key and grant.

To replace only one compromised or reinstalled component:

```swift
_ = try await rootClient.replaceComponent(weeklyWidget)
```

Replacement invalidates that component's prior session family without sharing
or exporting either private key.

## Extension use

The extension creates its own actor from the same descriptor and public
Latchway configuration. It has no identity-provider or root-attestation API:

```swift
let componentClient = try LatchwayExtensionClient(
    configuration: configuration,
    component: weeklyWidget
)
let transport = componentClient.transport(feature: "weekly-summary")

var request = URLRequest(url: try transport.endpoint(path: "v1/responses"))
request.httpMethod = "POST"
request.httpBody = requestBody
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
let response = try await transport.send(request)
```

The native actor owns Keychain access, P-256 signing, DPoP creation, session
rotation, and dispatch. It coalesces concurrent first use and refresh into one
single flight. If a rotated component response cannot be persisted, retrying
uses the same old-token/component/key tuple so a server implementing the
contract's 30-second exact-tuple idempotency window can return the same result.
A consumed initial provisioning grant is different: persistence failure clears
it and requires the containing app to prepare the component again.

Authorization rejects all of the following before a token or proof is added:

- a different scheme, host, effective port, or configured base path;
- control-plane or non-`/v1` paths;
- user information or a redirect target;
- provider credential names in headers or multiply encoded query fields;
- unknown framework IDs or malformed framework versions.

Buffered dispatch retries at most once and only after a canonical Latchway
problem proves rejection occurred before upstream dispatch. Body streams are
never replayed. Streaming uses the cookie-free, redirect-rejecting native
session, is incrementally consumed, and propagates cancellation without
exporting credentials.

## Revocation and sign-out

Revoke one component and erase its local credential and key while leaving
siblings active:

```swift
try await rootClient.revokeComponent(weeklyWidget)
```

For sign-out, pass the same complete descriptor set used during preparation:

```swift
try await rootClient.revokeCurrentInstallationFamily(
    retiring: [weeklyWidget, shareExtension]
)
```

The server revokes the family first. The SDK then attempts every root and
component cleanup even if one Keychain group is unavailable, and returns a
cleanup error after the remaining erasures have been attempted. The no-argument
family revocation API retires root state only because Keychain access groups
cannot be enumerated safely; use the descriptor overload whenever delegated
components exist.

## Recovery and diagnostics

`LatchwayComponentDiagnostics` reports only identifiers, key-storage class,
grant/session availability, trust provenance and expiry, and whether the
containing app must act. It never contains an access token, refresh token,
grant, DPoP proof, identity token, or private-key representation.

Common recovery behavior:

| Condition | Required action |
| --- | --- |
| Containing app not prepared / component not provisioned | Open the containing app, authenticate, and prepare the component. |
| Parent trust or delegation expired | Reattest or reauthenticate the root, then prepare again. |
| Component revoked or key replaced | Prepare the component again; immediate extension retry is not useful. |
| Family revoked or identity changed | Authenticate the current user and establish a new family. |
| Keychain access group unavailable | Correct both signed entitlements and reinstall; opening the app alone cannot repair signing. |
| Direct attestation required | Use a component/runtime that can provide the configured proof, or change server policy. |

React Native must call these native actors through its iOS bridge. Component
keys, grants, refresh tokens, access tokens, and DPoP proofs must not cross the
JavaScript bridge. The React Native containing app keeps
`clientRuntime: .reactNativeIOS`; a WidgetKit, App Intent, or other native
extension is a separate iOS executable and constructs its extension-side
configuration with `clientRuntime: .iOS`. Configure that component definition
for the `ios` platform on the server.

## Physical-device evidence

Simulator tests and unsigned builds do not prove entitlement isolation or
Secure Enclave behavior. Release evidence must run a signed containing app and
at least two extension access groups on physical hardware and prove intended
retrieval, sibling denial, replacement, family/component revocation, deletion,
locked/background access, reinstall migration, and uninstall cleanup. The
compile-oriented project in `Examples/AppExtensionComponents` is the source
scaffold; it is not itself release evidence.
