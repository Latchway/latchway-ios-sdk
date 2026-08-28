# Changelog

All notable changes to this project will be documented in this file.

The format follows Keep a Changelog, and releases will follow Semantic
Versioning once package publication begins.

## [Unreleased]

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

### Changed

- Hardened buffered and control-plane retries to require exact canonical,
  request-correlated pre-dispatch problems and one unambiguous printable-ASCII
  DPoP nonce; duplicate JSON members and ambiguous nonce headers fail closed.
- Expanded pre-session credential-leak rejection to the cross-SDK provider
  secret header/query alias set while retaining ordinary query parameters and
  cookie-free URLSession behavior.

- Synchronized the SDK with draft core contract 0.3.0 at commit
  `05f88b41813c210a23a459519abd3f7a9c3e45fa` and deterministic bundle SHA-256
  `ea265cfa750df8faeeaeac7bc60c04c4d907384205b5bf4d78a22a79dfc4d24c`.
  Wire protocol remains 1; the minimum server version is 0.3.0 and the maximum
  tested server series is 0.3.x.
- Synchronized the SDK with draft core contract 0.4.0 at commit
  `c9347421fac4c729f20ea87f9205c66c15fa983f` and deterministic bundle SHA-256
  `39d32a2c9e4b0381ff815a40d87d75b51e4f37d6de55121b7bb0beef690c5c59`.
  Wire protocol remains 1; the minimum server version is 0.4.0 and the maximum
  tested server series is 0.4.x.
