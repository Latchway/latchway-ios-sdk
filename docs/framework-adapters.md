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
- simulator compilation does not establish physical app-extension, native-key,
  or production-gateway conformance.

Until those version and physical gates pass, the canonical compatibility
registry remains the authority for its support state.

## MacPaw/OpenAI 0.5.1: blocked, no adapter shipped

Latchway intentionally does not ship an `OpenAIMiddleware` conformance for
MacPaw/OpenAI 0.5.1. Its public request interceptor is synchronous
(`intercept(request:) -> URLRequest`), so it cannot await native session refresh
and create a fresh DPoP proof for the final method/URL. Its public initializer
accepts a URLSession for buffered work, but streaming constructs an internal
`ImplicitURLSessionStreamingSessionFactory`; the safe streaming transport
factory is not public.

A static header, stale proof, global URLProtocol hook, or non-streaming-only
facade would not preserve request-time DPoP, redirect rejection, cancellation,
streaming, and bounded safe-retry semantics. Such a facade must not be labeled
MacPaw support. Applications can use Latchway's raw transport directly while
retaining their own Codable models, or use SwiftOpenAI's audited async client
seam.

The capability decision was reproduced against:

| Framework | Exact source | Result |
| --- | --- | --- |
| SwiftOpenAI | tag `4.6.0`, commit `b61ac3cce8018595412e5aa84275d1253645aab1`; public [`HTTPClient`](https://github.com/jamesrochabrun/SwiftOpenAI/blob/4.6.0/Sources/OpenAI/Private/Networking/HTTPClient.swift) | Buffered and line-stream hooks are injectable; compiled adapter and order/backpressure tests exist. |
| MacPaw/OpenAI | tag `0.5.1`, commit `a532be89be9a30ec003e4ba0974a52a88d26fc6d`; public [`OpenAIMiddleware`](https://github.com/MacPaw/OpenAI/blob/0.5.1/Sources/OpenAI/Public/Protocols/OpenAIMiddleware.swift) and [`OpenAI` initializer](https://github.com/MacPaw/OpenAI/blob/0.5.1/Sources/OpenAI/OpenAI.swift) | Missing async request interception plus public streaming transport injection; blocked. |
| FoundationModels | Xcode 27.0 SDK custom `LanguageModelExecutor` interfaces | Adapter compiles, but runtime/version/physical conformance remains pending. |

Adding a target or compiling a sample is not sufficient to change a framework's
compatibility status. Tested version bounds, common conformance, security
evidence, and the canonical registry must agree before a release claim.
