# Shared native apps and account logout

Current source uses supplied identity only. See
[configure and token lifetime](SuppliedIdentity.md) for the minimal API.
This source-breaking cleanup ships as version 2.0.0; older tags and receipts remain
unchanged. Server 1.1.1+, contract 1.1.0 / wire 3 and required host-policy
`sharedNativeCallers` are prerequisites.

## Configure in either order

`LatchwayAppRegistry.shared` owns the process-wide app. Matching configure
returns the existing backend without signing in or fetching identity.
Omitted optional settings inherit the first registration; conflicting explicit
identity/security settings fail with `configurationConflict`.

```swift
import Latchway
import LatchwayAppAttest

let app = try await LatchwayApp.configure(.init(
    baseURL: gateway,
    applicationID: applicationID,
    environment: environment,
    rootKeychainAccessGroup: rootGroup,
    suppliedIdentity: try .firebaseProject(projectID: projectID)
), name: "production")
let account = try await app.signIn { try await yourAuth.currentIDToken() }
let client = try await account.makeClient()
```

RN may configure first using equivalent public metadata. Native and RN share
one account, signer and refresh coordinator, while each request has a distinct
DPoP proof. No registration callback, startup coordinator or owner transfer is
required. Obtain another client without signing in again. Use one native SDK
implementation, not independent CocoaPods and SPM copies in the same host.

The App Attest module provides account-scoped defaults. A custom attestation
factory must retain its immutable policy identity and create state for the
provided account scope; never reuse one global provider for every user.

## Captured account lifetime

Stop application-owned tools and fence UI callbacks before logout:

```swift
try await account.logout()
await client.close()
// Application code signs out its external auth provider separately.
```

Logout is offline-capable, persists retirement and invalidates that account's
native/RN clients. Old handles cannot follow a later login, including the same
user signing in again. Failed storage cleanup remains blocked and retryable.
Cleanup survives cancellation; a bounded wait can still require another call.

Client close cancels only that client's work. Closing an RN screen must not
log out the host or cancel another surface. Buffered SDK response bytes are
also fenced after logout/close. Independently owned URLSession work and UI/tool
results remain the application's responsibility.

Observe `app.snapshots()` for atomic initial state and ordered safe updates.
The descriptor's `appInstanceID`, generation and revision identify lifecycle
state, not an authenticated subject. A delayed old-user callback must use its
captured account, never discover and retire a newer one.

Same-account `updateIdToken` is gateway-verified and preserves generation.
Expiry suspends protected work until refreshed; it is not logout.
`restore` cannot undo a persisted logout. Tokens stay in native memory only,
so the application must restore identity again after process restart.

## Delegated extension handoff

The containing application declares its current approved groups using
`componentKeychainAccessGroups` at first configuration. A component group must
differ from the private root group and be allowed by the signed entitlements.
Later equivalent configuration inherits the immutable allowlist.

Provision the component, then send only the non-secret account descriptor:

```swift
let widget = LatchwayComponentConfiguration.widget(
    definitionID: "home_widget",
    keychainAccessGroup: widgetGroup,
    requestedFeatures: ["weekly-summary"]
)
try await client.prepareComponents([widget])
let handoff = try await client.componentAccount()
let handoffData = try JSONEncoder().encode(handoff)
// Store this descriptor in the authorized container for this extension.
// Never copy ID tokens, root sessions, refresh tokens or keys into it.

// In the independently executing extension:
let account = try JSONDecoder().decode(
    LatchwayComponentAccount.self, from: handoffData)
let extensionClient = try LatchwayExtensionClient(
    baseURL: gateway,
    applicationID: applicationID,
    environment: environment,
    component: widget,
    account: account
)
let transport = extensionClient.transport(feature: "weekly-summary")
```

The extension initializer takes no root-private group or identity provider.
The explicit descriptor identifies the same gateway/application/environment and
account generation; opening it checks the current persistent fence. An old
handoff cannot open a new login, even for the same user.

The extension owns a component key, grant and rotating session in only its
approved group. iOS application extensions are delegated-only; the host does
not attest on their behalf. Wire 3 preserves the actual native/RN caller and
the gateway's component policy. WatchOS support is not inferred.

## Persistent component and root fences

The root journal records each component before provisioning or local mutation.
A component-group Keychain envelope includes its generation marker, key
reference and credential. Revision-matched writes prevent delayed writers from
overwriting retirement or a later rotated credential. Conflicts have bounded
retries; missing, corrupt or unavailable state fails closed.

Authorization, refresh, response completion and buffered bytes check the
persistent fence, including after a different process retires the account.
A suspended extension checks that fence when it resumes; JS need not run.

Logout removes delegated credentials while retaining permitted inactive
account-scoped keys. The bounded account-key eviction journal deletes exact
inactive coordinates; interrupted cleanup is retried before another account
can become active. Explicit component/family revocation also erases those
component keys. A failed component retirement leaves the root retiring and
blocks a new account until cleanup succeeds.

`await extensionClient.close()` releases that handle only. These are local
lifecycle guarantees, not a promise to terminate a suspended process, retract
an already exported request, reverse billing or revoke another device.

## Fresh storage and verification scope

There is no prior-store inventory, automatic session adoption or application
migration callback. Fresh account storage still requires real signed private
root/component groups, explicit allowlists and persistent retirement journals.
Uninstalling an application is not proof that Keychain data was erased.
Previous releases remain unchanged and are not rewritten by this source cleanup.

Test configure order, token acquisition cancellation, A → B → A, expiry,
offline logout, restart, failed cleanup and component revision races. Deterministic
tests are not signed Keychain or physical extension evidence. Record fresh
two-account, retained-key, entitlement and cross-process acceptance separately
before claiming the new source is verified in production.
