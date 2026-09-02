# MacPaw/OpenAI 0.5.1 transport spike

Date: 2026-08-30; stock transport fallback verified 2026-09-01;
replacement contribution and latest-tag check verified 2026-09-02

Decision: the stock 0.5.1 release remains blocked; no MacPaw adapter product or
Latchway conformance is shipped or advertised. A minimal upstream-ready patch
now proves that the injected `URLSession` configuration can cover both ordinary
and streaming dispatch, but it is not part of that release and has not been
represented as an external pull request or merge.

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

## Stock release executable gate

[`IntegrationTests/MacPawOpenAITransportSpike`](../../IntegrationTests/MacPawOpenAITransportSpike/README.md)
is a standalone executable package whose manifest pins the official dependency
with `exact: "0.5.1"`. Its resolved revision is
`a532be89be9a30ec003e4ba0974a52a88d26fc6d`.

The executable gives `OpenAI` an ephemeral `URLSession` with a custom
`URLProtocol`, and also registers that protocol process-wide. It sends only to
an isolated ephemeral loopback HTTP listener. Ordinary Chat Completions and
Responses requests both reach the injected protocol. Their streaming
equivalents do not: the stock internal factory constructs
`URLSession(configuration: .default)`, which ignores the custom session and the
globally registered protocol on the tested Darwin runtime. The gate additionally
requires both streams to reach the listener on their exact endpoint paths,
excluding a local pre-dispatch rejection as a false positive.

```bash
swift run --package-path IntegrationTests/MacPawOpenAITransportSpike \
  MacPawOpenAITransportSpike
# ordinary Chat Completions + Responses interception: covered
# streaming Chat Completions + Responses interception: unavailable
# MacPaw/OpenAI 0.5.1 full Latchway transport: BLOCKED
```

This closes the proposed custom-URLSession/custom-URLProtocol fallback. A
buffered adapter could authorize ordinary dispatch, but no public stock-0.5.1
hook can apply asynchronous session refresh and a fresh DPoP proof to streaming
dispatch or preserve cancellation through Latchway's transport. Shipping a
`LatchwayOpenAI` product for that partial surface would create a credential
bypass, so the product is intentionally absent.

## Upstream-ready contribution

[The contribution bundle](../upstream-contributions/macpaw-openai-0.5.1/README.md)
contains a plain `git apply` patch based on the exact official commit above. It
threads the caller's existing `URLSession.configuration` into MacPaw's three
internal streaming session kinds. This is the smallest upstream change that
lets a configured `URLProtocol` own ordinary and streaming dispatch without a
process-global hook or a fork of the package.

The patch SHA-256 is
`0d31b3b7a4afeaa5abc91e2deff42910efdfc9c94c479fcdb270a4e66472a44c`.
Applied to the official 0.5.1 base, `swift test` passes all 213 tests in the
patched checkout: 187 XCTest cases plus 26 Swift Testing cases. The executable
probe then proves Chat Completions and Responses use the injected protocol for
ordinary and streaming calls and that cancelling an active stream reaches
`URLProtocol.stopLoading`. Positive mode does not register the protocol
process-wide, so the injected configuration is the only available seam.

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

engineering/upstream-contributions/macpaw-openai-0.5.1/verify.sh
# 187 XCTest + 26 Swift Testing = 213 passed; 0 failed
# ordinary + streaming Chat/Responses interception: covered
# active stream cancellation reaches URLProtocol.stopLoading: covered
```

## Rejected alternatives

- A static DPoP or bearer header can expire, binds the wrong final URL, and
  exports native credentials.
- Blocking an async actor refresh inside synchronous middleware risks deadlock
  and violates structured concurrency/cancellation.
- A global `URLProtocol` registration is process-global and, as the executable
  gate demonstrates, is not consulted by the stock streaming session.
- A buffered-only facade would omit MacPaw's streaming path and must not be
  labeled transparent MacPaw support.

Applications may use Latchway's raw transport with their own Codable models or
the separately audited SwiftOpenAI adapter. MacPaw support requires a future
release that preserves injected session configuration for every streaming
surface, followed by a version-pinned `LatchwayOpenAI` URLProtocol bridge and
full common, hosted, release-image, and physical conformance. The bridge must
delegate authorization, refresh/safe retry, redirect rejection, and streaming
cancellation to `LatchwayFeatureTransport`; configuration propagation alone is
not a support claim.
