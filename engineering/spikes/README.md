# iOS integration spike records

These records capture the source evidence and security decision behind each
framework or app-extension integration. They are engineering evidence, not a
compatibility or release declaration. The core compatibility registry and the
protected release evidence remain authoritative.

| Record | Decision |
| --- | --- |
| [SwiftOpenAI 4.6.0](swift-openai-4.6.0.md) | Accept ordinary and SSE request paths through the public asynchronous `HTTPClient`; WebSocket Realtime remains unsupported. |
| [Apple Foundation Models](foundation-models-xcode-27.md) | Keep the OS 27 custom-executor adapter narrow and fail-closed; all nine Xcode 27 / iOS 27 simulator cases pass, while hosted, exact-image, and physical conformance remain pending. |
| [MacPaw/OpenAI 0.5.1](macpaw-openai-0.5.1.md) | Do not ship or advertise a stock-0.5.1 adapter; the pinned executable proves that its internal streaming session bypasses custom URLSession/URLProtocol injection for Chat Completions and Responses. A minimal upstream patch propagates the injected session configuration to streams, passes all 213 upstream tests, and passes a positive interception/cancellation probe, but is not merged or released. |
| [iOS component security strategy](ios-component-security-strategy.md) | Treat ordinary iOS extensions as delegated-only because `DCAppAttestService.generateKey` is unavailable there; require signed physical proof of the delegated component design. |

Every record names the exact source or toolchain inspected, the commands used
for local proof, and evidence that is still missing. A later upstream release
requires a new record rather than silently extending a version claim.
