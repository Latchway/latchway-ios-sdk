# Latchway iOS SDK

Latchway lets an untrusted iOS application call AI infrastructure through a
self-hosted gateway without embedding an upstream provider key. This repository
will provide the Swift transport and platform-security integration for that
client boundary.

> **Project status:** Governance foundation only. No Swift package or supported
> release exists yet. Do not add this repository as a dependency.

## Planned scope

The SDK will:

- Use a P-256 installation key backed by Secure Enclave when available and a
  policy-approved Keychain fallback otherwise
- Produce RFC 9449 DPoP proofs
- Integrate Apple App Attest registration and assertions
- Exchange an existing application identity token for short-lived,
  device-bound Latchway sessions
- Authorize arbitrary URLRequest values and provide URLSession integration
- Store refresh state securely and coordinate refresh through Swift actors
- Expose quota, installation-revocation, and redacted diagnostic APIs
- Keep Firebase support optional and outside the core target

The canonical package identity will be **Latchway**, with iOS 15 as the planned
minimum deployment target unless an audited requirement changes it. Public APIs
will use current Swift strict-concurrency conventions.

## Protocol ownership

The Latchway core repository owns the client OpenAPI description, error
registry, protocol manifest, canonical attestation binding, DPoP vectors, and
compatibility rules. This SDK consumes a signed and checksummed contract bundle;
it does not define an independent wire protocol.

A contract lock is intentionally absent until the core repository publishes the
first bundle. See [Architecture](docs/architecture.md) for the dependency and
trust boundaries.

## Security model

The SDK holds an installation private key and short-lived Latchway session
state. It never receives an upstream AI-provider credential and does not replace
the application's identity provider. Native hardware capabilities are reported
accurately rather than silently upgraded or overstated.

Review [Security Policy](SECURITY.md) before reporting a vulnerability.

## Development

Build and test commands will be added with the Swift Package manifest. Until
then, changes in this repository are limited to reviewed governance,
architecture, and contract-consumption foundations.

Repository-local agent skill installations are developer tooling only. They are
ignored, are not package inputs, and are not distributed.

See [Contributing](CONTRIBUTING.md) and [Agent Instructions](AGENTS.md).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
