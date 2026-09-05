# Foundation Models through Latchway

Use Apple's `LanguageModelSession` with a remote, server-selected model while
Latchway retains ownership of Firebase identity, App Attest, Keychain sessions,
and Secure Enclave DPoP. This does **not** use Apple's on-device model, and it
requires a network connection.

## Requirements

- Xcode 27 / Swift 6.4 and iOS, macOS, visionOS, or watchOS 27 for the optional
  adapter. tvOS is unavailable. The core iOS SDK still supports iOS 15.
- The `LatchwayFoundationModels` Swift Package product, or the optional
  `Latchway/FoundationModels` CocoaPods subspec on iOS 27.
- An authenticated `LatchwayClient` (or delegated `LatchwayExtensionClient`).
- A feature using `openai_responses`, a compatible physical model, and the
  gateway version **1.0.2** or newer. Server 1.0.1 is insufficient.

Version **1.1.0** adds this expanded adapter. Install the `v1.1.0` Swift Package
release or CocoaPods `Latchway/FoundationModels`, version `1.1.0`.

## Start a session

After creating your normal authenticated `client`:

```swift
import FoundationModels
import LatchwayFoundationModels

let model = LatchwayLanguageModel(
    client: client,
    feature: "assistant",
    frameworkVersion: "27.0.0"
)
let session = LanguageModelSession(model: model, instructions: "Be concise.")
session.transcriptErrorHandlingPolicy = .revertTranscript

for try await snapshot in session.streamResponse(to: "What is Latchway?") {
    render(snapshot.content) // Each snapshot is accumulated text, not a delta.
}
let followUp = try await session.respond(to: "How does its device trust work?")
```

Reuse the session for multi-turn context. Do not start simultaneous generations
on the same session. Cancel the consuming task to stop streaming. The adapter
does not retry after receiving response bytes. If trimming history, remove
whole prompt/response/tool-call/tool-result turns; never orphan a tool result.

## Guided generation

```swift
@Generable
struct ProjectSummary {
    @Guide(description: "One-sentence description of the project.")
    var summary: String
    var caveat: String?
}

let response = try await session.respond(
    to: "Summarize Latchway.",
    generating: ProjectSummary.self
)
let summary: ProjectSummary = response.content
```

`GenerationSchema` is encoded as `text.format` JSON Schema, including nested
definitions and guides. Strict object schemas disallow extra properties;
optional properties become required nullable properties. Structured history is
sent as JSON text. Apple performs the framework-side typed decoding, including
partial snapshots when using `streamResponse(generating:)`.

`ContextOptions.includeSchemaInPrompt == true` also appends the schema to the
instructions. `false` does not append it, but the output schema is still sent.
The physical provider must support the schema's guides and root type. A schema
that a provider cannot enforce is not downgraded to an unconstrained prompt.

## Local tools and multiple turns

```swift
let session = LanguageModelSession(
    model: model,
    tools: [WeatherCheckTool(budget: WeatherToolBudget(), onLookup: { _ in })],
    instructions: "Always use weather_check for live weather. Cite Open-Meteo."
)
let first = try await session.respond(to: "What's the weather in Singapore?")
let second = try await session.respond(to: "What about Ho Chi Minh City?")
```

`WeatherCheckTool` is implemented in the
[LatchwayChat example](../Examples/LatchwayChat/LatchwayChat/LatchwayChat/WeatherCheckTool.swift).
The upstream model chooses the tool and its JSON arguments. Apple's framework
invokes the Swift `Tool`, appends its result, then asks Latchway for the next
generation. No hand-written text matcher or fabricated tool response is used.

Only `enabledToolDefinitions` is offered for new calls. Historical calls to a
now-disabled tool remain valid history. `allowed`, `required`, and `disallowed`
map to `auto`, `required`, and `none`. Parallel calls retain their distinct
call IDs. Tool arguments are bounded and validated before any call is emitted
to the framework; no tool runs from a failed or truncated stream.

The demo's tool queries two fixed Open-Meteo HTTPS endpoints, uses city names
rather than GPS, and limits each turn to six lookups. Weather data is attributed
to Open-Meteo, location data to GeoNames. The free endpoint is for this
non-commercial demonstration; review Open-Meteo's terms before production use.

## Request-field mapping and backend limits

| Foundation Models field | Responses mapping |
| --- | --- |
| `id` | `metadata.latchway_generation_id`; separate from Latchway's request ID |
| `transcript` | Instructions, messages, structured JSON text, function calls/results, reasoning |
| `enabledToolDefinitions` | Local `function` tools with strict parameter schemas |
| `schema` | `text.format` with `type: json_schema` |
| `temperature`, `maximumResponseTokens` | `temperature`, `max_output_tokens`; server output cap still applies |
| Greedy / unseeded random top-p / top-k | Temperature zero / `top_p` / `top_k` |
| `toolCallingMode` | `tool_choice` |
| Reasoning light / moderate / deep / custom | Effort low / medium / high / supplied value |
| `metadata` | Up to 15 application pairs plus the generation ID; non-string values become JSON strings |

Metadata keys are at most 64 UTF-8 bytes; values at most 512. It is sent to the
upstream, not used as identity, routing, pricing, or quota policy. Do not put
secrets in it. The SDK rejects oversized metadata instead of truncating it.

Known limits are explicit:

- A seed has no portable Responses representation. Seeded sampling throws
  `unsupportedSamplingMode`. Top-k and custom reasoning effort depend on the
  configured provider/model; the adapter does not invent equivalent semantics.
- Image attachments are not advertised or translated by this route. Audio,
  embeddings, hosted tools, provider conversations, and remote file references
  are not Foundation Models capabilities supplied by this adapter.
- Visible reasoning summaries and opaque UTF-8 Responses signatures round-trip.
  Encrypted reasoning cannot use the gateway's text byte-BPE quota proof.
- Trusted input quotas count inline tool/schema bytes, framing, and bounded
  local reference expansion. Recursive or unresolved schemas fail closed under
  that accounting method; they need a suitable provider accounting strategy.
- SSE is limited to 16 MiB per response, 1 MiB per line/tool argument, and 2 MiB
  per event. `[DONE]` alone is not successful completion. Incomplete/refused
  output is never reported as a successful guided result.

These are remote backend limits, not a claim that every Foundation Models
feature is universally available on every upstream model.

## Verify with LatchwayChat

Open the example, sign in, then choose **Settings → Foundation Models**. Ask for
weather in one city, then ask “What about [another city]?” The green weather
lookup cards reflect completed real HTTP lookups. **Custom URLSession** retains
the original direct Chat Completions implementation. Changing engines starts a
new conversation without signing out or changing device trust.

The simulator suite exercises Apple's real framework against deterministic
HTTP fixtures. A physical-device run separately proves authentication,
attestation, gateway execution, provider usage, and the live weather tool.

On 2026-09-05 the iPhone 16 Pro / iOS 27 development run completed Singapore
then Ho Chi Minh City with two actual weather lookups. Four Responses requests
settled 11,200 provider-reported total tokens. The URLSession engine also passed
after the gateway upgrade. All 17 simulator tests and the optional CocoaPods
subspec validation pass. The demo explicitly requests reasoning effort `none`:
this gateway's strict text quota profile cannot account opaque encrypted
reasoning returned by the model's automatic mode. This limitation is not bypassed
or hidden by the example. These are development integration results, not
production/extension certification.

References: [Apple custom executors](https://developer.apple.com/documentation/foundationmodels/languagemodelexecutor),
[OpenRouter Responses](https://openrouter.ai/docs/api/api-reference/responses/create-responses),
[Open-Meteo weather](https://open-meteo.com/en/docs),
[Open-Meteo geocoding](https://open-meteo.com/en/docs/geocoding-api).
