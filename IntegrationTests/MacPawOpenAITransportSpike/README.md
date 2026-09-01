# MacPaw/OpenAI 0.5.1 transport injection proof

This isolated executable pins the official MacPaw/OpenAI `0.5.1` release and
tests its two public dispatch paths without contacting OpenAI or Latchway.

It supplies a custom `URLSession` whose `protocolClasses` contains a probe and
also registers the same `URLProtocol` with Foundation. Ordinary Chat
Completions and Responses requests must reach the injected session. Their
streaming equivalents must not reach the probe: stock `0.5.1` constructs its
own `URLSession(configuration: .default)`, which ignores both the injected
session and process registration on the tested Darwin runtime.

Run the gate with:

```bash
swift run --package-path IntegrationTests/MacPawOpenAITransportSpike \
  MacPawOpenAITransportSpike
```

The executable exits nonzero if either ordinary endpoint stops using the
injected session or if either streaming endpoint starts reaching the probe.
It also runs an isolated ephemeral HTTP listener and requires each stream to
reach that listener on its exact path, so a request rejected before networking
cannot produce a false pass and no external service is contacted.
Its expected output is:

```text
ordinary Chat Completions + Responses interception: covered
streaming Chat Completions + Responses interception: unavailable
MacPaw/OpenAI 0.5.1 full Latchway transport: BLOCKED
```

This is negative conformance evidence, not a production adapter. Shipping a
buffered-only product would misrepresent coverage and permit streaming calls to
bypass request-time session refresh and fresh DPoP authorization.
