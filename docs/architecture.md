# iOS SDK Architecture

## Status

This document fixes the ownership and dependency boundaries for the planned
Swift SDK. It does not describe an existing implementation. Package manifests,
production targets, generated models, and contract.lock will be introduced only
after the core repository publishes an authoritative contract bundle.

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

## Planned target boundaries

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

LatchwayAppAttest and LatchwayFirebaseAuth depend inward on stable protocols
exposed by Latchway. The core target does not import Firebase. React Native
depends on this SDK for all Apple security behavior.

## Key and state boundary

The installation signer owns a P-256 private key. Secure Enclave is preferred;
a fallback is allowed only when policy permits and must be accurately surfaced.
Only a public JWK and its RFC thumbprint cross the process boundary. Refresh
tokens remain in non-synchronizable Keychain storage. Actor isolation protects
session mutation and refresh single flight.

App Attest has a separate key identity and lifecycle. Registration and later
assertions bind to the core-defined canonical challenge bytes. Invalid-key
recovery is bounded and cannot loop indefinitely.

## Transport boundary

Authorization mutates or produces ordinary URLRequest values so existing HTTP
and AI libraries remain usable. URLSession integration may recover from a
session failure only when Latchway explicitly guarantees that the request was
rejected before upstream dispatch. Once response bytes exist or dispatch is
uncertain, the SDK returns the failure without automatic replay.

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
