# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and releases will follow Semantic
Versioning once package publication begins.

## [Unreleased]

### Changed

- Require a fully resolved private root Keychain access group, prove it is the
  signed default before root work, explicitly scope every root/App Attest
  Security query, and fail closed when known root records remain in declared
  extension-shared groups.

## Planned 1.0.0 candidate baseline (unreleased)

### Added

- Initial governance, contribution, security, and architecture documentation.
- Swift 6 package with iOS 15 deployment support and handwritten public APIs.
- Secure Enclave P-256 installation keys with explicit non-synchronizable
  Keychain software fallback policy.
- RFC 9449 DPoP, rotating sessions, actor single-flight refresh, authorization,
  quota, revocation, safe buffered retry, and redacted diagnostics.
- App Attest registration/assertion lifecycle with bounded invalid-key recovery.
- Optional Firebase token adapter, testing doubles, shared contract vectors,
  examples, and a physical-device conformance application.
- Paired native/React Native runtime identifiers plus nonce-aware authorization
  and single-flight forced refresh for safe caller-owned transport integration.
- Runtime-isolated native Keychain and App Attest namespaces, independently
  versioned client headers, and a build-linted CocoaPods App Attest subspec for
  React Native autolinking.
- Typed `operation_indeterminate` errors with their canonical audit correlation
  identifier preserved on the public problem value.
- A release-gated Swift Package and CocoaPods publication workflow, including
  a clean-tag/version preflight, nested consumer build, deterministic source
  archive, checksum, and optional credentialed CocoaPods publication.

### Changed

- Synchronized the source candidate with draft core contract 1.0.0 at commit
  `a59a2c1c807aec50093ae6346492a05148c72899` and deterministic bundle SHA-256
  `3a88fb69b911724da849229f34f735608e829bcfb0658087313c8d31441e9927`.
  New requests identify current wire protocol 2, while optional root metadata
  keeps compatible legacy wire-1 grant decoding fail-closed. The minimum server
  version is 1.0.0 and the maximum tested server series is 1.0.x.
- Hardened buffered and control-plane retries to require exact canonical,
  request-correlated pre-dispatch problems and one unambiguous printable-ASCII
  DPoP nonce; duplicate JSON members and ambiguous nonce headers fail closed.
- Expanded pre-session credential-leak rejection to the cross-SDK provider
  secret header/query alias set while retaining ordinary query parameters and
  cookie-free URLSession behavior.
- Closed an actor-reentrancy race that could make concurrent callers rotate an
  already-refreshed session a second time; scheduler-controlled regression
  coverage now proves one refresh and one persisted rotation per expiry.

- Previously synchronized the SDK with draft core contract 0.3.0 at commit
  `05f88b41813c210a23a459519abd3f7a9c3e45fa` and deterministic bundle SHA-256
  `ea265cfa750df8faeeaeac7bc60c04c4d907384205b5bf4d78a22a79dfc4d24c`.
  Wire protocol remains 1; the minimum server version is 0.3.0 and the maximum
  tested server series is 0.3.x.
- Previously synchronized the SDK with released core contract 0.5.1 at commit
  `2f5e5e67c824e270431f1232cc6dc2824848e380` and deterministic bundle SHA-256
  `52ebacd1e38c522b89bb14a1f34782176be32cdf91d22b7ab962003dbca2d754`.
  Wire protocol remains 1; the minimum server version is 1.0.0 and the maximum
  tested server series is 1.0.x.
