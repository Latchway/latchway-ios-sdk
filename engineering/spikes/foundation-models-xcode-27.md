# Apple Foundation Models custom-executor spike

Date: 2026-08-30

Decision: conditionally implemented for the Foundation Models custom
`LanguageModel`/`LanguageModelExecutor` API available in the OS 27 SDK. Keep the
adapter's compatibility state pending until runtime, gateway, and physical
conformance pass.

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
# LatchwayFoundationModels built; its availability test was skipped because
# the test process ran on macOS 14 rather than macOS 27.

swift build --disable-sandbox --configuration release \
  --scratch-path /tmp/latchway-ios-addendum-release
# LatchwayFoundationModels compiled; Build complete
```

This is compile evidence only. A runtime-skipped test is not treated as a
successful Foundation Models execution.

## Evidence still required

- Execute transcript translation, incremental delivery, usage, cancellation,
  and every fail-closed capability case on a supported OS 27 runtime.
- Run the adapter through a deployed Latchway Responses route with canonical
  request/stream fixtures and framework metadata enforcement.
- Run signed physical-device coverage for native key ownership, background
  behavior, memory bounds, and extension use where applicable.
- Establish and publish tested Apple framework version bounds in the core
  compatibility registry.

Until those gates pass, documentation must describe this as a narrow optional
adapter with pending runtime conformance, not as generally supported.
