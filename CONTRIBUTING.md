# Contributing to Latchway iOS SDK

Thank you for helping build Latchway. This repository is currently establishing
its governance and protocol boundary. It intentionally has no Swift package or
contract lock until the core repository publishes the first authoritative
contract bundle.

## Before making a change

1. Read AGENTS.md and docs/architecture.md.
2. Confirm which repository owns the behavior. Wire protocol changes begin in
   the Latchway core repository.
3. Keep the change to one reviewable concern and explain its security impact.
4. Never commit credentials, signing material, identity tokens, attestation
   evidence, device data, or local environment files.

## Design and implementation rules

- Public Swift APIs are handwritten, idiomatic, Sendable where appropriate,
  and designed for strict concurrency.
- Generated wire models, when introduced, remain internal.
- The core target must not depend on Firebase. Optional identity and
  attestation integrations live in separate targets.
- Private keys are non-exportable and never synchronizable.
- Automatic replay is allowed only when the server proves that the original
  request was rejected before upstream dispatch.
- Do not create a local wire format or contract.lock without a published core
  contract bundle.
- Do not leave production-path placeholders or hard-coded success behavior.

## Tests

Every functional change must include proportionate unit tests. Security or
protocol work also requires shared-vector and conformance coverage. Actor
coordination, cancellation, streaming, redaction, key persistence, and retry
safety must be tested explicitly.

Canonical commands will be documented when Package.swift and CI are introduced.
A contribution is not ready while its documented checks fail.

## Pull requests

Use focused commits with conventional subjects such as feat(ios), fix(session),
test(conformance), or docs(security). Describe compatibility impact, tests run,
and any external device validation still required. Generated changes must be
reproducible and reviewed with their source contract.

By contributing, you agree that your contribution is licensed under the
Apache License, Version 2.0.
