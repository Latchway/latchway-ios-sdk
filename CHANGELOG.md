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
