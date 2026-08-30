# MacPaw/OpenAI 0.5.1 transport spike

Date: 2026-08-30

Decision: blocked; no MacPaw adapter product or conformance is shipped or
advertised.

## Exact source inspected

- Repository: `https://github.com/MacPaw/OpenAI`
- Tag: `0.5.1`
- Commit: `a532be89be9a30ec003e4ba0974a52a88d26fc6d`

The public middleware at
`Sources/OpenAI/Public/Protocols/OpenAIMiddleware.swift` exposes
`intercept(request:) -> URLRequest` synchronously. Latchway authorization must
await a native actor, possibly rotate a session, validate the final method and
URL, and create a fresh DPoP proof immediately before dispatch. That cannot be
implemented safely in a synchronous interceptor.

The public initializer can accept a `URLSession` for buffered requests, but
`Sources/OpenAI/OpenAI.swift` constructs an
`ImplicitURLSessionStreamingSessionFactory` for streams. The underlying
`StreamingSessionFactory` in
`Sources/OpenAI/Private/Streaming/ServerSentEventsStreamingSessionFactory.swift`
is not public. An adapter therefore cannot own both ordinary and streaming
request dispatch through the required native security boundary.

## Local proof

The exact checkout was inspected with:

```bash
git describe --tags --exact-match HEAD
# 0.5.1
git rev-parse HEAD
# a532be89be9a30ec003e4ba0974a52a88d26fc6d

rg -n 'protocol OpenAIMiddleware|func intercept' Sources/OpenAI
# public intercept(request:) -> URLRequest is synchronous

rg -n 'StreamingSessionFactory|ImplicitURLSessionStreamingSessionFactory' \
  Sources/OpenAI
# StreamingSessionFactory is internal and OpenAI constructs the implicit
# URLSession streaming factory internally
```

## Rejected alternatives

- A static DPoP or bearer header can expire, binds the wrong final URL, and
  exports native credentials.
- Blocking an async actor refresh inside synchronous middleware risks deadlock
  and violates structured concurrency/cancellation.
- A global `URLProtocol` interception hook cannot provide a narrow,
  framework-owned streaming/cancellation boundary and is process-global.
- A buffered-only facade would omit MacPaw's streaming path and must not be
  labeled transparent MacPaw support.

Applications may use Latchway's raw transport with their own Codable models or
the separately audited SwiftOpenAI adapter. MacPaw support requires a future
public request-time asynchronous hook plus a public streaming transport
injection point, followed by a new version-specific spike and conformance run.
