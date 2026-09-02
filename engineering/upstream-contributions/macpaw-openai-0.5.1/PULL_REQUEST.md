# Fix: Reuse injected URLSession configuration for streams

## What

Reuse the configuration of the `URLSession` supplied to `OpenAI` when creating
the SDK's internal streaming sessions. The change covers Chat Completions,
Responses, and audio streaming without changing the public initializer or the
default behavior.

## Why

The public initializer currently uses the supplied session only for buffered
requests. Streaming always creates a session from `.default`, so caller
configuration such as `protocolClasses`, cache/cookie policy, proxy settings,
and request/resource timeouts is silently lost. This also prevents applications
from applying one custom transport consistently to buffered and streaming
requests.

## Affected Areas

- `OpenAI` public initializer wiring
- internal streaming session factories
- `FoundationURLSessionFactory`
- one configuration-preservation unit test

## More Info

The patch is source-compatible: callers that use the default/shared session
still receive its default configuration, and the SDK continues to own the
delegate required by its streaming parser.

Verification against tag `0.5.1` (`a532be89be9a30ec003e4ba0974a52a88d26fc6d`):

```text
swift test: 187 XCTest + 26 Swift Testing = 213 passed
external transport probe: Chat + Responses buffered/streaming interception passed
external cancellation probe: URLProtocol.stopLoading reached for an active stream
```

The external probe uses only an isolated loopback listener and an injected
`URLProtocol`; it makes no OpenAI request.
