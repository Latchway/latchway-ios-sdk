# Latchway reference — 2026-09-05

Latchway is an Apache-2.0 self-hosted AI gateway for untrusted iOS, Android, web,
and React Native apps. It is not an identity provider or an AI model. Apps retain
their existing identity provider and ordinary HTTP formats. The gateway validates
users and app/device trust, creates device-bound sessions, authorizes features,
reserves quota, routes to the server-selected model, and settles actual usage.

## Identity, attestation, and the request path

The app signs in with Firebase Auth (or another configured identity provider).
The SDK supplies a current Firebase ID token on demand. The gateway validates
the signature, issuer, audience, expiry, and configured Firebase project.
Identity and attestation are separate: a signed-in user is not automatically a
trusted app. The SDK creates a non-exportable P-256 Secure Enclave key and answers
a server challenge using real Apple App Attest. The server validates certificate
trust, app/team identity, attestation environment, signature, canonical challenge
binding, and applicable build/signing policy. It grants a short-lived session
bound to the device's DPoP key. DPoP follows RFC 9449, binding proofs to request
method, URI, and token. Nonce and replay checks apply. A copied bearer token alone
does not suffice. Refresh credentials are securely persisted and refresh is
coordinated. Never replay a request after response bytes may have reached the app.

The client requests a feature, not privileged policy. Server configuration chooses
the user plan, physical model, upstream, prices, routes, and quota. Credentials
are injected only by the gateway; the client never contains an upstream or Admin
API key. The gateway streams provider responses and records authoritative usage.

## This demonstration

LatchwayChat uses Firebase project `latchway`, bundle `dev.latchway`, a separate
disposable LatchwayChat application, and a Development environment on
https://latchway.habitify.me. Feature `latchway-chat` uses real development App
Attest and Secure Enclave DPoP, without software-key or debug-attestation fallback.
The server chooses OpenRouter model `openai/gpt-5.6-luna`. Its allowance is 100,000
total input+output tokens per user per UTC day. Chat requests cap output at 1,024
tokens. The connection sheet shows actual SDK trust, session, quota, and request
ID metadata; configuration alone is not evidence that verification succeeded.
Chat messages are only in app memory. New conversation, sign-out, and process
restart clear them. Firebase/Latchway persist required session credentials
securely. The server stores redacted request/usage metadata, not production chat
bodies by default. Providers still process the conversation under their policies.

## Configuration and platform scope

Resources are organization → application → environment → configuration revisions.
Validate a revision before activating it; activation uses strong ETags to prevent
lost updates. Secrets are encrypted, environment-scoped, and write-only. Documents
contain secret references, not returned plaintext credentials. Development and
Production may use different Firebase projects, secrets, routes, and policies.
Only the chosen platforms need configuration: iOS-only, Android-only, web-only,
or any desired subset is supported. Enabling all platforms is not required.
Client Component Definitions describe root applications and delegated extensions.
iOS app extensions are delegated-only in v1, not directly App Attested. Wear OS
is reserved vocabulary, not enabled v1 support.

Platform verifiers include App Attest, Play Integrity, Firebase App Check, and
Turnstile. This app uses Firebase Auth for user identity and direct App Attest
for device trust, not Firebase App Check as a substitute. Android needs its
package, Play Integrity project number, signing-certificate SHA-256, and verifier
credentials. Its min/max version bounds of zero allow any version.
Server 1.0.1 adds App Attest `allowedBundleVersions: ["*"]` for any well-formed
build version. Existing exact allowlists still work; empty or mixed wildcard
lists are rejected. Bundle identity, signing category, root trust, environment,
signature, and replay checks are unchanged. No client wire change is required.

## Swift integration

Products include Latchway, LatchwayAppAttest, LatchwayFirebaseAuth,
LatchwayAppExtensions, LatchwaySwiftOpenAI, LatchwayFoundationModels, and
LatchwayTesting. The core does not depend on Firebase. FirebaseLatchwayIdentityTokenProvider
accepts an async closure returning the current Firebase ID token. Configure
LatchwayAppAttestProvider and LatchwayConfiguration with the gateway URL,
server-generated application ID, environment slug, and fully resolved private
root Keychain access group. That group must be first in the signed app's Keychain
groups. Then construct LatchwayClient with the identity provider.
Use `client.transport(feature: "latchway-chat").bytes(for: request)` for a normal
POST `/v1/chat/completions` with messages and stream:true. The SDK owns session
authorization, DPoP, refresh, and proven-safe retries. Consume or cancel the
returned stream and finish successful responses. Use `diagnostics()` and
`quota(feature:)` to inspect actual state. Revoke the installation while Firebase
identity is available, then sign out of Firebase. Never embed provider keys,
identity tokens, signing secrets, or administrator credentials.

## Protocols, routing, and quotas

Implemented proxy families include OpenAI-compatible Chat Completions, Responses,
Embeddings, Anthropic Messages, and restricted opaque HTTP. Only configured
protocol capabilities and destinations are permitted. Routing includes priority,
weighted/sticky selection, fallback, and retries. Clients cannot supply arbitrary
destinations or authoritative policy, usage, model, or pricing choices.
Provider compatibility and extraction must be tested against the selected provider.
Accounting follows reserve → execute → settle. Never hold a database transaction
open while waiting for the upstream. Token counts and nano-USD amounts use integers.
Total tokens combine input and output. A per-user feature allowance may span
platforms in one environment; Development/Production usage is separate.
Conservative trusted input estimates can reserve more than the final reported
usage. Rate, concurrency, token, and cost limits are server policy, not client claims.

## Deployment and operations

PostgreSQL 15+ is v1's only required external infrastructure service. API/worker
roles can run together. Docker Compose can run a one-shot migrator and long-running
gateway using the same release image digest. Preserve the database URL and
base64-encoded 32-byte encryption master key across upgrades/backups.
LATCHWAY_PUBLIC_ORIGIN must be an absolute origin such as https://gateway.example.com
without credentials, path, query, fragment, or trailing slash. Migrator settings
must satisfy configuration validation too. Use a real PostgreSQL connection URI,
not a placeholder. Choose TLS appropriate for the database network. Caddy can
terminate HTTPS while the app's 8080 port is bound to localhost only.
`/healthz` shows process/build health; `/readyz` checks configuration, database,
keys, schema, completion capacity, and worker heartbeat. Migrator exit 0 is normal.
Back up the encryption key with the database: losing it makes encrypted provider
and signing secrets unusable. Do not expose database or administrative credentials.

The canonical Admin API supports configuration without the UI: applications,
environments, configuration revisions, identity/attestation policies, encrypted
secrets, model/pricing/routes/quotas, validation/activation/simulations, provider
diagnostics, request/usage/audit views, installation/session management, and
operations. The CLI/Console use that API, not direct database writes. A setup
key creates the first owner; it is not a mobile client key. Reconcile indeterminate
mutations with audit events instead of guessing whether a write committed.
Stable error codes/request IDs help debugging without logging credentials,
attestation evidence, DPoP proofs, or chat contents.

## Release boundaries and authoritative sources

Public server 1.0.1 is at https://github.com/Latchway/latchway/releases/tag/v1.0.1
and `ghcr.io/latchway/latchway:1.0.1` for Linux amd64/arm64. It retains frozen client
contract 1.0.0, wire protocols 1/2, and DB schema 29 without a new migration.
Public server 1.0.0 rejects the wildcard: activate exact build lists before
rolling back to it. Publication does not establish every cloud, physical-device,
resilience, or security claim; broader external evidence remains deferred.
A provider one-token diagnostic returned five completion tokens, while a 16-token
probe honored its cap. Do not call the one-token test passed or imply every
provider limit behavior has been proven. This bot has a bundled reference
snapshot, not live browsing, administrative tools, or account/log access.
For details and examples consult:
https://github.com/Latchway/latchway
https://github.com/Latchway/latchway-ios-sdk
https://github.com/Latchway/latchway-js
https://github.com/Latchway/latchway-android
https://github.com/Latchway/latchway-react-native-sdk
The core `api/` directory owns protocol and configuration definitions; `docs/`
contains architecture, integration, deployment, and evidence-based status.
