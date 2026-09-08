# Shared native apps and account logout — advanced compatibility API

New integrations should use [developer-supplied identity](SuppliedIdentity.md):
one-call configure, opaque account handles and no native auth bootstrap.
The authority-based API below remains for explicit custom/legacy ownership.
Shared mode requires released contract 1.1.0 / protocol 3 and an explicit
`sharedNativeCallers` policy. Legacy server 1.0.x does not provide this combination.

## Configure once, activate explicitly

The native process owns `LatchwayAppRegistry.shared`. Matching `configure`
returns the same backend and never fetches identity or signs in. Omitted
optional options inherit the first registration. Another name for the same
gateway/app/environment aliases it; conflicting security or identity settings
fail with `LatchwayLifecycleError.configurationConflict`.

```swift
let app = try await LatchwayApp.configure(
    .init(baseURL: gateway, applicationID: applicationID,
          environment: environment, rootKeychainAccessGroup: rootGroup,
          identity: .init(name: "host-firebase", issuer: issuer),
          exposeToReactNative: true),
    name: "production",
    authority: authority,
    attestationFactory: { accountScope in
        LatchwayAppAttestProvider(rootKeychainAccessGroup: rootGroup,
                                 storageNamespace: accountScope)
    }
)
// The application's accepted sign-in/restoration transition owns activation.
let generation = try await app.activate()
let client = try await app.makeClient()
```

Use one selected Firebase Auth instance with the optional
`FirebaseLatchwayIdentityAuthority` adapter, or implement `LatchwayIdentityAuthority`.
Its snapshot must contain consistent issuer, tenant, subject and current token;
return nil when signed out. The server, not this local binding, authenticates
the principal. Firebase remains outside the SDK core dependency graph.

The attestation factory must create account-scoped state; never return one global
provider for all users. A custom factory needs a stable `attestationPolicyID`.
Default hardware requirements remain in force.

## Logout and disposal

Stop app-owned tools/requests and fence UI callbacks first. Then:

```swift
try await app.logout(generationID: generation) // works without a live client
await client.close()
// Now sign out the selected Firebase Auth instance in application code.
```

`try await client.logout()` is the captured-generation convenience. It requires
an app-owned client; a legacy token-only client cannot claim account-aware
logout. Call logout before close. A first logout on a closed handle fails;
a completed logout remains idempotent. Old clients cannot follow a later login,
even for the same Firebase UID. Explicitly activate and obtain fresh clients.

Logout does not fetch identity, require network, reset quota, sign out Firebase
or revoke the server installation. Already dispatched work can still be billed
to its original user. Storage failure leaves the generation blocked and returns
`cleanupRequired`; retry the captured logout before activating another account.
Cleanup survives caller cancellation, and its bounded wait may require a retry.

`close()` cancels only that client's work. Closing an RN screen must not log out
the host or cancel its sibling native client. Buffered SDK response bytes are
also fenced after close/logout. Independently owned URLSession work is the
application's responsibility.

Observe `app.snapshots()` for an atomic initial snapshot and ordered redacted
changes. External Firebase sign-out/account changes must retire the captured old
generation and clear chat/model state before activation. Never resolve the
current generation from a delayed old-user callback.

## Embedded React Native

Register the native authority before RN starts. RN uses `Latchway.getApp(name)`
or equivalent configure; it supplies no second Firebase provider. Native/RN
clients share the actual session, refresh chain and account signer, while every
request has a distinct DPoP proof.

Use a single native SDK implementation. A host's separate SPM build and RN's
CocoaPods build are not a proven shared registry; align on the RN pod dependency
before claiming embedded support. Explicit `transferIdentityAuthority` retires
the old generation before replacing the provider and never activates it. Swift
rejects transfer during pending activation; finish/retire that operation and retry.

## Delegated extension handoff and local logout

The containing application provisions its approved iOS component, then supplies
only an opaque, non-secret account/generation descriptor to the extension:

```swift
let widget = LatchwayComponentConfiguration.widget(
    definitionID: "home_widget", keychainAccessGroup: widgetGroup,
    requestedFeatures: ["weekly-summary"])
// First native app registration must include:
// componentKeychainAccessGroups: [widgetGroup]
try await client.prepareComponents([widget])
let handoff = try await client.componentAccount()
let handoffData = try JSONEncoder().encode(handoff)
// Store handoffData in the authorized app-group container for this extension.
// Never copy identity tokens, root sessions, refresh tokens or root keys there.

// In the extension process, after reading the host's explicit handoff:
let account = try JSONDecoder().decode(LatchwayComponentAccount.self, from: handoffData)
let extensionClient = try LatchwayExtensionClient(
    configuration: extensionConfiguration, component: widget, account: account)
let transport = extensionClient.transport(feature: "weekly-summary")
```

The extension uses its own component Keychain group, signer, grant and session,
never the private root group. Configuration must identify the same gateway,
application and environment as the handoff. Wire 3 declares `native` with the
actual iOS/RN caller; required host policy and existing component grants still
apply. No watchOS or legacy RN component platform is implicitly converted.
The native owner explicitly approves component groups in immutable
`componentKeychainAccessGroups`; omission on first registration means none.
Matching native/RN registration inherits those groups. A group cannot equal the
private root group, and actual signed entitlement access is enforced by Keychain.

The root journal records each component before any provisioning/local mutation.
In its authorized group, one Keychain envelope contains the generation marker,
component key reference and rotating component credential. Revision-matched
updates prevent a delayed writer from overwriting retirement or a newer rotating
credential. This uses Apple's documented attribute-matching
[SecItemUpdate behavior](https://developer.apple.com/documentation/security/secitemupdate(_:_:)).
Revision conflicts have bounded retries; missing, corrupt or unavailable markers
fail closed. Authorization, refresh, response completion and buffered streaming
bytes check the persistent fence, including after another process retires it.
An extension resumes from suspension into that fence; it never needs JS to run.

Logout erases delegated credentials but retains inactive account-scoped component
keys. The same eight-account eviction journal removes these retained keys using
a root-private, non-secret coordinate index. Explicit component/family revocation
also erases the revoked component's keys. A failed component-store retirement
keeps the root `retiring`, blocks another account and is retried after restart.
An old handoff cannot open the new login, even when the Firebase UID is unchanged.

`await extensionClient.close()` releases that extension handle only. Already
exported requests and work dispatched before logout are not remotely revoked.
The SDK does not promise to terminate a suspended process or reverse billing.

## Legacy migration inventory

Activation first drains legacy native and RN root owners and clears their exact
session/key coordinates. Permanent root/component markers stop updated legacy
constructors across restart. Never downgrade to an older binary after migration;
older SDKs do not implement these markers. No old refresh chain is imported.

For a legacy application, register the complete inventory in native bootstrap:

```swift
options.legacySharedKeychainAccessGroups = [oldSharedRootGroup]
options.legacyComponents = [oldWidget, oldShareExtension]
options.legacyAttestationNamespaces = ["my-explicit-old-namespace"]
options.legacyMigration = LatchwayLegacyMigration(id: "old-custom-store-v1") {
    try await eraseMyOldSDKCredentialStore() // idempotent, offline, throws on failure
}
```

Use `legacyComponents: []` explicitly if the old app never provisioned components.
A pre-registry root with no declared inventory fails with
`rootKeychainMigrationRequired`; an omitted inventory is not evidence of none.
Default/custom App Attest namespaces are cleared only when exactly inventoried;
the SDK does not indiscriminately erase a global `default` namespace that another
app might own. Arbitrary custom stores cannot be discovered automatically: the
native cleanup callback owns their inventory and must not report success early.

Inventory settings are immutable registration policy. Omitted options inherit
the owner; correcting an already registered inventory requires app restart.
The durable migration marker includes the inventory fingerprint, so adding
explicit coordinates on a later launch reruns cleanup safely. Partial erasure
retains pending state; it is not an instruction to adopt whatever legacy state
survives. The callback must not call Latchway authorization or depend on Firebase.

## Acceptance limits

The root account implementation retains at most eight inactive/current key
scopes, journaling eviction before deleting exact inactive local keys. Interrupted
cleanup is retried before activation. This is not remote key revocation.

Unit tests exercise independent transactional-store coordinators, stale refresh
responses, cached authorization/bytes, incomplete cleanup and restart recovery.
They are not signed Keychain, App Attest or physical extension-process evidence.
Real entitlement/access-group, two-account App Attest and retained-key eviction
acceptance must be recorded on a supported device before production enablement.
Published dependency pins and release-contract locks are separate release work.
The native LatchwayChat now uses this lifecycle; its older device receipts remain
historical legacy evidence and do not prove this new mode.
