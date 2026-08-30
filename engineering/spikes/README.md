# iOS integration spike records

These records capture the source evidence and security decision behind each
framework or app-extension integration. They are engineering evidence, not a
compatibility or release declaration. The core compatibility registry and the
protected release evidence remain authoritative.

| Record | Decision |
| --- | --- |
| [SwiftOpenAI 4.6.0](swift-openai-4.6.0.md) | Accept ordinary and SSE request paths through the public asynchronous `HTTPClient`; WebSocket Realtime remains unsupported. |
| [Apple Foundation Models](foundation-models-xcode-27.md) | Keep the compiled OS 27 custom-executor adapter narrow and fail-closed; runtime and physical conformance remain pending. |
| [MacPaw/OpenAI 0.5.1](macpaw-openai-0.5.1.md) | Do not ship or advertise an adapter because the public seams cannot preserve fresh async DPoP and streaming dispatch. |
| [iOS component security strategy](ios-component-security-strategy.md) | Accept the source design and simulator/build evidence; require signed physical-device proof before release. |

Every record names the exact source or toolchain inspected, the commands used
for local proof, and evidence that is still missing. A later upstream release
requires a new record rather than silently extending a version claim.
