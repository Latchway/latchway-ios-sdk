# iOS SDK Architecture

## Status

This document fixes the ownership and dependency boundaries for the Swift SDK.
The implementation consumes draft contract 1.0.0/current wire protocol 2 at the
exact core revision and bundle digest in `contract.lock`. Its root grant decoder
retains the optional family/component fields needed to read legacy wire-1
installation/session responses; all requests emitted by this source identify
wire 2.

## System boundary

The customer application supplies an identity token from its existing identity
provider and an HTTP request intended for its configured Latchway gateway. The
SDK proves possession of an installation key, obtains a short-lived Latchway
session, and adds transport authorization. The gateway authenticates,
authorizes, meters, and injects the upstream provider credential.

The SDK never receives the upstream credential and never decides server-owned
facts such as user ID, plan, attestation level, organization, route, upstream,
price, or usage.

## Contract ownership

The Latchway core repository exclusively owns:

- Client session OpenAPI
- Error-code registry and retry guidance
- Protocol-version and compatibility manifest
- Canonical attestation-binding encoding
- DPoP and attestation test vectors
- Canonical request examples
- The checksummed contract release bundle

This repository consumes those artifacts. A contract update must verify the
bundle checksum, update contract.lock, regenerate internal wire DTOs
reproducibly, run shared vectors, and pass conformance against the exact core
image. Generated wire DTOs must not become the public Swift API.

## Target boundaries

~~~text
Customer application
    |
    +-- Latchway
    |     Public API, session coordination, DPoP, HTTP authorization,
    |     Keychain state, quota, diagnostics, revocation
    |
    +-- LatchwayAppAttest
    |     Optional DCAppAttestService key lifecycle and evidence provider
    |
    +-- LatchwayFirebaseAuth
    |     Optional adapter implementing the identity-token provider
    |
    +-- LatchwayTesting
          Test signers, identity providers, attestation providers, clocks,
          storage, transports, and fixtures; never a production dependency
~~~

`LatchwayAppAttest` and `LatchwayFirebaseAuth` depend inward on stable protocols
exposed by Latchway. The core target does not import Firebase. React Native
depends on this SDK for all Apple security behavior.

The Firebase adapter accepts an async token operation or a small source
protocol. This avoids pinning Firebase in the package graph while still keeping
Firebase-specific integration outside the core target.

## Key and state boundary

The installation signer owns a P-256 private key. Secure Enclave is preferred;
a fallback is allowed only when policy permits and must be accurately surfaced.
Only a public JWK and its RFC thumbprint cross the process boundary. Refresh
tokens remain in non-synchronizable Keychain storage. Actor isolation protects
session mutation and refresh single flight.

App Attest has a separate key identity and lifecycle. The server constructs the
canonical RFC 8785 binding and supplies its 32-byte SHA-256 as
`client_data_hash`; the SDK validates its exact size and gives those bytes
directly to App Attest. Registration state changes to assertions only after a
successful session exchange. Invalid-key recovery performs at most one key
rotation per operation.

Installation keys, refresh sessions, and App Attest accepted-key state are all
namespaced by application, environment, and client runtime. This prevents a
native iOS client and a React Native client in the same host application from
sharing a platform-bound grant or refresh-token rotation state.

Every root Keychain read, update, add, and delete includes the caller's fully
resolved private `rootKeychainAccessGroup`. Before identity, attestation, key,
or session work, a random sentinel written through the signed default group is
read only through that exact explicit group. Extension-shared groups are
provided separately in `legacySharedKeychainAccessGroups` and scanned only at
known Latchway root service/account coordinates, including when the private
group correctly passes the sentinel. A stale shared-first record fails with
`rootKeychainMigrationRequired`; v1 does not perform an implicit migration or
destructive cleanup. The sentinel itself is the only group-less Keychain item,
and its random coordinate is deleted immediately after the check.

## Transport boundary

Authorization mutates ordinary `URLRequest` values so existing HTTP
and AI libraries remain usable. URLSession integration may recover from a
session failure only when Latchway explicitly guarantees that the request was
rejected before upstream dispatch. Once response bytes exist or dispatch is
uncertain, the SDK returns the failure without automatic replay.

The buffered `send` integration withholds a rejected response from application
code and retries once only for the contract's pre-dispatch session-expiry or
DPoP-nonce errors. Retry eligibility is a fail-closed protocol boundary: the
problem body must contain exactly the seven canonical RFC 9457 members with the
registry's fixed values, the response request ID must match the original
request, session expiry must not carry a nonce, and a nonce challenge must
carry one unambiguous printable-ASCII value. Strict JSON validation rejects
duplicate and Unicode-escaped duplicate members before decoding. The same
nonce grammar protects the public caller-owned authorization API and internal
control-plane retry. `LatchwayFeatureTransport.bytes(for:)` applies that exact
one-retry policy before exposing response bytes: it buffers only a candidate
401 problem body up to 64 KiB and leaves successful and post-retry bodies as
native `URLSession.AsyncBytes`. Requests backed by `httpBodyStream` are never
replayed. Each streaming dispatch owns an independently cancellable URL
session; the response's `finish()` and `cancel()` methods release it.

Before session or transport work, authorization rejects the shared SDK list of
provider-secret header and decoded query names. It includes bearer/proxy auth,
OpenAI/Anthropic/API-key aliases, access tokens, AWS credential/security-token/
signature fields, Google credential/signature fields, and cookies. Ordinary
non-credential query parameters remain supported. SDK-owned URL sessions also
disable cookie acceptance and persistence.

React Native uses the public feature transport so native code owns strict
problem validation, request-identifier preservation, bounded replay, and URL
session cancellation without exporting stored credentials. Lower-level
caller-owned transports may still use public nonce-aware authorization and
forced-refresh operations after independently validating a same-origin
problem. A typed runtime configuration pairs the React Native iOS installation
platform with its protocol SDK identifier so the two cannot drift
independently.

Cancellation and streaming flow end to end. Errors expose stable safe fields
and request identifiers, never tokens or raw attestation evidence.

## Verification boundary

Unit tests own deterministic cryptographic, storage, actor, cancellation, and
retry cases. Shared vectors prove wire-level agreement. Fixture tests cover App
Attest without credentials. Cross-repository tests run the SDK against
PostgreSQL and the exact core container. A physical-device application provides
the final App Attest evidence without displaying secrets.

## Non-goals

This repository does not own server policy, provider routing, quota
enforcement, user-authentication UI, upstream secrets, AI request modeling, or
React Native bridge behavior.

## Local developer tooling

The existing .agents tree, .claude/skills links, and skills-lock.json are local
review and testing aids installed from third-party skill packages. They are
intentionally ignored, are not package or contract inputs, are not required in
CI, and are excluded from release artifacts.
