# SwiftOpenAI 4.6.0 transport spike

Date: 2026-08-30

Decision: accepted for SwiftOpenAI's buffered HTTP and line-streaming HTTP
paths, using framework ID `swift-openai`. WebSocket Realtime is explicitly out
of scope.

## Exact source inspected

- Repository: `https://github.com/jamesrochabrun/SwiftOpenAI`
- Tag: `4.6.0`
- Commit: `b61ac3cce8018595412e5aa84275d1253645aab1`
- Package dependency: pinned with `.exact("4.6.0")`; `Package.resolved` records
  the same revision.

At that revision,
`Sources/OpenAI/Private/Networking/HTTPClient.swift` declares a public
`HTTPClient` with asynchronous `data(for:)` and `bytes(for:)` requirements.
`OpenAIServiceFactory.service` accepts an injected implementation. Both
ordinary Responses calls and HTTP streaming can therefore reach Latchway at
request time without giving SwiftOpenAI a Latchway access token, refresh token,
private key, or provider credential.

SwiftOpenAI's WebSocket Realtime path does not use this injected HTTP client.
The adapter must not attach a static authorization header or install a global
protocol hook to claim Realtime support.

## Implemented boundary

`LatchwaySwiftOpenAIHTTPClient` is a value-type `HTTPClient` adapter. It:

- binds one Latchway feature and emits framework ID/version metadata;
- gives SwiftOpenAI only the literal, non-secret `latchway-managed` placeholder;
- preserves a configured gateway base path when constructing the service;
- delegates final destination validation, session refresh, fresh DPoP signing,
  redirect rejection, and dispatch to the native Latchway actor;
- converts the native byte stream to SwiftOpenAI lines through a one-element,
  oldest-preserving buffer, waiting and retrying a value when the consumer is
  slower rather than dropping or reordering it; and
- cancels the producer when downstream streaming terminates.

## Local proof

The inspected checkout was verified with:

```bash
git describe --tags --exact-match HEAD
# 4.6.0
git rev-parse HEAD
# b61ac3cce8018595412e5aa84275d1253645aab1
rg -n 'protocol HTTPClient|func data\(|func bytes\(' Sources/OpenAI
```

Repository validation on Apple Swift 6.4 / Xcode 27.0:

```bash
swift test --scratch-path /tmp/latchway-ios-addendum-build \
  --filter LatchwaySwiftOpenAITests
# 5 tests passed

swift build --disable-sandbox --configuration release \
  --scratch-path /tmp/latchway-ios-addendum-release
# Build complete
```

The five adapter tests compile against the exact dependency and prove public
HTTP shapes, the explicit pin/placeholder, buffered dispatch without credential
export, a 64-line slow-consumer stream with order and no loss, and service
factory preservation of `/latchway/v1/responses`.

## Evidence still required

- Common gateway conformance against a deployed server and the canonical
  framework registry.
- Cancellation and slow-consumer evidence on supported iOS hardware.
- A new spike before supporting any SwiftOpenAI version other than 4.6.0.
- A new public, injectable asynchronous seam before WebSocket Realtime can be
  considered.

Passing this local spike does not by itself change the canonical compatibility
status or make the package released.
