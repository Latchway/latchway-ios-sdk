# Framework-transparent Apple adapters

Latchway does not introduce prompt, chat, tool, agent, message, or model
abstractions. `LatchwayFeatureTransport` is the normative seam: it binds one
server-owned feature and optionally attaches an audited framework ID/version,
while the native client keeps every key and credential private.

## SwiftOpenAI 4.6.0

The `LatchwaySwiftOpenAI` product contains a real conformance to SwiftOpenAI's
public asynchronous `HTTPClient`. Version 4.6.0 is pinned exactly because that
version exposes request-time `data(for:)` and `bytes(for:)` hooks for ordinary
and streaming calls.

```swift
import LatchwaySwiftOpenAI
import SwiftOpenAI

let httpClient = LatchwaySwiftOpenAIHTTPClient(
    client: latchwayClient,
    feature: "habit-assistant"
)
let service = try httpClient.makeService()
```

Continue using SwiftOpenAI's own request and response models with `service`.
The factory supplies only the literal non-secret `latchway-managed` sentinel;
Latchway removes that exact placeholder and adds fresh DPoP authorization at
dispatch. Any other authorization, API-key header, or credential-like query
field is rejected.

The adapter preserves a configured gateway base path, forwards buffered
responses in SwiftOpenAI's native types, and converts URLSession bytes to its
native line stream with an oldest-preserving one-element buffer. A slow
consumer therefore bounds memory without dropping or reordering events.
Downstream termination cancels the producer and native URLSession task.

Requests carry:

```text
X-Latchway-Framework: swift-openai
X-Latchway-Framework-Version: 4.6.0
```

SwiftOpenAI's WebSocket Realtime implementation bypasses the injectable
`HTTPClient` in this version, so Realtime is not supported by this adapter.
Do not add static DPoP or authorization headers as a workaround.

## Apple Foundation Models

On Apple SDKs that expose custom `LanguageModel` executors, the
`LatchwayFoundationModels` product provides `LatchwayLanguageModel`. It maps a
Foundation Models transcript to a streaming Latchway Responses request while
retaining `LanguageModelSession` and transcript types in application code:

```swift
import FoundationModels
import LatchwayFoundationModels

if #available(iOS 27.0, *) {
    let model = LatchwayLanguageModel(
        client: latchwayClient,
        feature: "habit-assistant",
        frameworkVersion: "27.0.0"
    )
    let session = LanguageModelSession(model: model)
    // Use the ordinary Foundation Models session API.
}
```

The current translation is deliberately narrow and fail-closed:

- text instructions, prompts, and responses are supported;
- streaming text deltas and terminal token usage are forwarded;
- generation schemas, structured output, tools, reasoning transcript entries,
  attachments, and sampling modes fail explicitly instead of being silently
  approximated;
- availability begins with the Apple OS 27 SDK custom-executor API;
- the Xcode 27.0 / iOS 27.0 simulator suite passes all nine public-API cases:
  safe errors, single- and multi-turn transcripts, incremental text and usage,
  fail-closed schemas/tools, quota and feature errors, cancellation, safe
  session-refresh retry, and the public app-extension initializer boundary;
- simulator conformance does not establish physical app-extension/native-key
  behavior, a deployed production gateway, or exact release-image evidence.

The simulator result replaces the earlier compile-only evidence. Until the
remaining hosted, release-image, and physical gates pass, the canonical
compatibility registry remains the authority for its support state.

The app-extension initializer accepts an already provisioned delegated
`LatchwayExtensionClient`. It does not enable direct App Attest in an ordinary
iOS extension: `DCAppAttestService.generateKey` is unavailable there, so the
containing root app attests itself and delegates an independently keyed
component grant without attesting on the extension's behalf.

## MacPaw/OpenAI 0.5.1: stock release blocked

Latchway intentionally does not ship an `OpenAIMiddleware` conformance for
MacPaw/OpenAI 0.5.1. Its public request interceptor is synchronous
(`intercept(request:) -> URLRequest`), so it cannot await native session refresh
and create a fresh DPoP proof for the final method/URL. Its public initializer
accepts a URLSession for buffered work, but streaming constructs an internal
`ImplicitURLSessionStreamingSessionFactory`; the safe streaming transport
factory is not public.

The [exact-0.5.1 executable gate](../IntegrationTests/MacPawOpenAITransportSpike/README.md)
tests the remaining custom-URLSession/custom-URLProtocol fallback against both
Chat Completions and Responses. Ordinary calls reach the injected protocol.
Both streaming calls bypass it because the internal factory creates its own
default session. The executable is pinned to tag `0.5.1` and resolved revision
`a532be89be9a30ec003e4ba0974a52a88d26fc6d`; it exits nonzero if the observed
dispatch boundary changes.

A static header, stale proof, global URLProtocol hook, or non-streaming-only
facade would not preserve request-time DPoP, redirect rejection, cancellation,
streaming, and bounded safe-retry semantics. Such a facade must not be labeled
MacPaw support. Applications can use Latchway's raw transport directly while
retaining their own Codable models, or use SwiftOpenAI's audited async client
seam.

### Verified upstream contribution

Latchway carries an [upstream-ready patch](../engineering/upstream-contributions/macpaw-openai-0.5.1/README.md)
against the official 0.5.1 source. It reuses the caller's injected
`URLSession.configuration` for Chat Completions, Responses, and audio streaming
sessions. This 12-addition production change makes a configured `URLProtocol`
available to ordinary and streaming paths without adding a new public API.
Applied to base commit `a532be89be9a30ec003e4ba0974a52a88d26fc6d`,
the complete patched checkout passes 213 tests: 187 XCTest cases and 26 Swift
Testing cases. The executable contribution probe additionally covers ordinary
and streaming Chat/Responses interception plus active-stream cancellation into
`URLProtocol.stopLoading`.

That patch is contribution evidence, not part of the published 0.5.1 release.
No external pull request or merge is claimed, and Latchway still ships no
MacPaw adapter. A released upstream seam plus Latchway adapter/common
conformance would be required before the compatibility state can change.

The capability decision was reproduced against:

| Framework | Exact source | Result |
| --- | --- | --- |
| SwiftOpenAI | tag `4.6.0`, commit `b61ac3cce8018595412e5aa84275d1253645aab1`; public [`HTTPClient`](https://github.com/jamesrochabrun/SwiftOpenAI/blob/4.6.0/Sources/OpenAI/Private/Networking/HTTPClient.swift) | Buffered and line-stream hooks are injectable; compiled adapter and order/backpressure tests exist. |
| MacPaw/OpenAI | tag `0.5.1`, commit `a532be89be9a30ec003e4ba0974a52a88d26fc6d`; public [`OpenAIMiddleware`](https://github.com/MacPaw/OpenAI/blob/0.5.1/Sources/OpenAI/Public/Protocols/OpenAIMiddleware.swift) and [`OpenAI` initializer](https://github.com/MacPaw/OpenAI/blob/0.5.1/Sources/OpenAI/OpenAI.swift) | Stock release lacks a safe whole-transport seam. The pinned executable proves injected URLSession coverage for ordinary Chat Completions and Responses, and proves that both streaming paths bypass it. The minimal configuration-propagation patch passes 213 upstream tests and the positive transport/cancellation probe, but is not merged or shipped. |
| FoundationModels | Xcode 27.0 SDK custom `LanguageModelExecutor` interfaces on an iOS 27.0 simulator | All nine narrow public-API cases pass; hosted, exact-image, and physical conformance remain pending. |

Adding a target or compiling a sample is not sufficient to change a framework's
compatibility status. Tested version bounds, common conformance, security
evidence, and the canonical registry must agree before a release claim.
