# iOS SDK Architecture

## Status

This document fixes the ownership and dependency boundaries for the Swift SDK.
The implementation consumes contract 0.1.0/wire protocol 1 at the exact core
revision and bundle digest in `contract.lock`.

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

## Transport boundary

Authorization mutates ordinary `URLRequest` values so existing HTTP
and AI libraries remain usable. URLSession integration may recover from a
session failure only when Latchway explicitly guarantees that the request was
rejected before upstream dispatch. Once response bytes exist or dispatch is
uncertain, the SDK returns the failure without automatic replay.

The buffered `send` integration withholds a rejected response from application
code and retries once only for the contract's pre-dispatch session-expiry or
DPoP-nonce errors. It rejects streaming request bodies from retry. The
`makeURLSession` streaming path never automatically replays.

For caller-owned transports such as React Native fetch, public nonce-aware
authorization and forced-refresh operations expose no stored credentials. The
bridge must first validate a same-origin problem response, preserve the request
identifier, and cap replay to one attempt. A typed runtime configuration pairs
the React Native iOS installation platform with its protocol SDK identifier so
the two cannot drift independently.

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
