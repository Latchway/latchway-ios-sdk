# MacPaw/OpenAI 0.5.1 transport spike

Date: 2026-08-30; contribution verified 2026-08-31

Decision: the stock 0.5.1 release remains blocked; no MacPaw adapter product or
Latchway conformance is shipped or advertised. An upstream-ready patch now
demonstrates the asynchronous seam against the official 0.5.1 source, but it is
not part of that release and has not been represented as an external pull
request or merge.

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

## Upstream-ready contribution

[The contribution bundle](../upstream-contributions/macpaw-openai-0.5.1/README.md)
contains a mail-formatted patch based on the exact official commit above. It
adds `OpenAIAsyncRequestInterceptor`, ordered asynchronous middleware
execution, and cancellation bridging across callback, async/await, Combine,
and streaming clients while preserving the existing synchronous fast path.

The patch commit is `4fab05ce89ef6c454caa8ec9f1f4cfba0581cc3d` and the
patch SHA-256 is
`8035958648cc19a3ce9dae7e86f2d872cd3353c7f16adf06359330c413f53411`.
Applied to the official 0.5.1 base, `swift test` passes all 217 tests in the
patched checkout: 187 XCTest cases plus 30 Swift Testing cases. Five Swift
Testing cases are new coverage for ordering, callback, async/await, streaming,
and cancellation.

This proves a viable upstream change; it does not retroactively add a public
seam to the released 0.5.1 package. Latchway can implement and claim a MacPaw
adapter only after a suitable upstream release is pinned and the adapter passes
Latchway common, hosted, release-image, and physical conformance.

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

git am /absolute/path/to/0001-Add-asynchronous-request-interception.patch
swift test
# 187 XCTest + 30 Swift Testing = 217 passed; 0 failed
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
release containing a safe request-time asynchronous hook for every client
surface, followed by a new version-specific spike and Latchway conformance run.
