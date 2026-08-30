# AGENTS.md

These instructions apply to the entire Latchway iOS SDK repository.

## Mission and current phase

Build the Swift SDK that lets iOS applications authenticate to Latchway,
establish device-bound sessions, and authorize ordinary URL requests without
holding an upstream provider credential.

The version 1 Swift implementation is locked to draft contract checkpoint
1.0.0, current wire protocol 2, and the checksummed core revision recorded in
`contract.lock`. Compatible legacy root responses from server-supported wire 1
remain readable, but new SDK requests identify wire 2. The package remains
unpublished until the core contract is released and the protected physical
device, registry, provenance, and immutable-release evidence gates pass.
Package source, tests, examples, and internal handwritten wire DTOs may evolve
within the locked contract. A contract change must update the lock and shared
fixtures in the same reviewed change. Never invent a temporary wire contract,
fake production behavior, or describe an unpublished package as released.

## Authority and dependency boundaries

- The Latchway core repository is the sole owner of the client OpenAPI,
  protocol manifest, error codes, canonical attestation binding, DPoP vectors,
  and compatibility policy.
- Consume checksummed contract releases. Generated DTOs may be internal; public
  Swift APIs must remain handwritten and idiomatic.
- Planned targets are Latchway, LatchwayAppAttest, LatchwayFirebaseAuth, and
  LatchwayTesting. Firebase must not become a dependency of the core target.
- React Native must consume this SDK for Apple key and attestation behavior
  rather than reimplementing it.

## Security invariants

- Use a non-exportable P-256 Secure Enclave key when available.
- A software fallback must be explicit, policy-controlled, Keychain-backed, and
  accurately reported. Private keys must never be synchronizable.
- Follow RFC 9449 for DPoP and the core canonical binding for App Attest.
- Keep refresh tokens in Keychain and coordinate refresh as an actor-protected
  single flight.
- Never replay a request after response bytes may have reached the client.
  Retry only when Latchway proves rejection occurred before upstream dispatch.
- Never log identity tokens, session tokens, refresh tokens, DPoP proofs,
  attestation evidence, private key material, or provider credentials.
- The SDK must never accept an upstream AI-provider secret.

## Swift implementation rules

- Planned minimum deployment target is iOS 15 unless an audited API requirement
  is documented.
- Use current strict-concurrency conventions and prefer value types,
  Sendable boundaries, structured concurrency, and explicit cancellation.
- Do not use unchecked concurrency annotations to silence genuine isolation
  defects.
- Keep public APIs transport-oriented; do not add an AI framework.
- Keep test doubles in the testing target, never in a production path.
- No production TODO, FIXME, empty handler, hard-coded success, or placeholder
  response is acceptable.

## Testing and validation

When the package exists, every change must keep package builds and tests
passing. Security/protocol work requires shared vectors and core-container
conformance. Test actor races, cancellation, streaming, clock skew, key
lifecycle, redaction, refresh reuse, installation revocation, and retry safety.

Real App Attest completion requires a physical supported device. Missing Apple
credentials do not block fixture tests or unrelated work; record the exact
remaining device-validation command.

## Repository hygiene

- Do not commit secrets, signing assets, service-account files, local
  environments, build output, or machine-specific absolute paths.
- Preserve unrelated user changes and keep generated output reproducible.
- Update documentation with public behavior.
- Use focused conventional commits when explicitly asked to commit.

The existing .agents directory, .claude/skills links, and skills-lock.json are
developer-installed review tooling. They are intentionally ignored, are not SDK
source or contract inputs, must not be required by CI, and are not distributed.
Preserve them in place unless a task explicitly changes their disposition; do
not silently delete or vendor them.
