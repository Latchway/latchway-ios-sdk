# Apple Foundation Models custom-executor spike

Date: 2026-08-30

> Historical spike: the capability and nine-test descriptions below describe
> the initial implementation, not SDK 1.1.0. As of 2026-09-05,
> the adapter translates guided schemas, local tools/results, unseeded
> sampling, context options, metadata, and reasoning. Seventeen iOS 27
> simulator tests and the optional CocoaPods subspec validation pass. Follow
> [the current adapter guide](../../Documentation/FoundationModels.md) for
> supported behavior and explicit backend limits.

Decision: conditionally implemented for the Foundation Models custom
`LanguageModel`/`LanguageModelExecutor` API available in the OS 27 SDK. The
narrow adapter passes its Xcode 27 / iOS 27 simulator runtime suite. Keep the
compatibility state pending until hosted-gateway, exact release-image, and
physical conformance pass.

## Exact SDK inspected

The local toolchain reported:

```text
Apple Swift version 6.4 (swiftlang-6.4.0.30.4 clang-2100.3.30.1)
Xcode 27.0 (27A5237l)
```

The Xcode 27 iPhoneOS SDK's generated FoundationModels Swift interface exposes
public `LanguageModel` and `LanguageModelExecutor` protocols. The implementation
is compiled only when FoundationModels can be imported and the compiler is at
least Swift 6.4, and every public adapter type is guarded by OS 27 availability.
This preserves the package's iOS 15 baseline for applications that do not use
the optional product.

## Implemented boundary

`LatchwayLanguageModel` retains Apple's `LanguageModelSession` and transcript
surface while its executor sends a Responses API stream through a
feature-bound native Latchway transport. The current capability declaration is
intentionally empty. The adapter supports text instructions/prompts, streaming
text deltas, and terminal usage. It fails explicitly for schemas and guided
generation, tools, sampling modes, invalid transcripts, malformed streams, and
gateway failure events.

Keys, access/refresh tokens, DPoP proofs, identity tokens, and provider
credentials remain in native Latchway ownership. Framework metadata is added at
native dispatch, and the same destination, redirect, cancellation, and stream
bounds apply as for raw Latchway transport.

## Local proof

```bash
swift --version
# Apple Swift 6.4 (swiftlang-6.4.0.30.4 clang-2100.3.30.1)
xcodebuild -version
# Xcode 27.0 / Build version 27A5237l

swift test --scratch-path /tmp/latchway-ios-addendum-build
# LatchwayFoundationModels built. The macOS process remains below macOS 27, so
# it does not provide the simulator runtime evidence described below.

swift build --disable-sandbox --configuration release \
  --scratch-path /tmp/latchway-ios-addendum-release
# LatchwayFoundationModels compiled; Build complete
```

The retained `Latchway-Package` Xcode result ran
`LatchwayFoundationModelsTests/FoundationModelsPublicAPITests` on an arm64
iPhone 17 simulator with iOS 27.0. Its summary reports 9 passed, 0 failed, and
0 skipped. The cases prove:

1. safe public error descriptions;
2. single-turn Responses streaming through `LanguageModelSession`;
3. multi-turn instruction/user/assistant transcript preservation;
4. incremental text snapshots and terminal token usage;
5. fail-closed guided generation and tool calling without dispatch;
6. truthful quota and unavailable-feature error mapping;
7. cancellation reaching the native URL-loading stream;
8. one canonical pre-dispatch session-refresh retry with a fresh
   authorization value; and
9. the app-extension client initializer as a first-class public compilation
   boundary.

The suite uses a protocol-valid local HTTP fixture through Apple's public
Foundation Models session/executor APIs. It is real simulator runtime evidence,
not merely compilation, but it does not prove a deployed gateway, physical
device/native-key behavior, or release-image identity.

The ninth case establishes only the initializer's public API boundary. An
ordinary iOS extension cannot call `DCAppAttestService.generateKey`; a real
Foundation Models extension must receive a separately keyed delegated
component grant from its attested containing app.

## Evidence still required

- Run the adapter through a deployed Latchway Responses route with canonical
  request/stream fixtures and framework metadata enforcement.
- Run signed physical-device coverage for native key ownership, background
  behavior, memory bounds, and delegated extension use where applicable.
- Repeat the same nine-case suite from the exact signed release candidate and
  retain its machine-readable result bundle.
- Establish and publish tested Apple framework version bounds in the core
  compatibility registry.

Until those gates pass, documentation must describe this as a narrow optional
adapter with passing local simulator conformance, not as generally supported.
