# Native iOS golden journey

`BasicURLSession.swift` is a compiled, complete integration source example.
Call `runLatchwayGoldenJourney` from a development- or production-signed iOS
application on a physical App Attest-capable device.

Supply setup-wizard values through application configuration, for example:

```swift
let deployment = LatchwayGoldenJourneyConfiguration(
    baseURL: URL(string: "https://gateway.example.com")!,
    applicationID: "app_01J00000000000000000000000",
    environment: "production",
    rootKeychainAccessGroup: "ABCDE12345.com.example.app",
    feature: "assistant-responses",
    model: "assistant-default",
    appVersion: "1.0.0"
)
```

The two Firebase closures should fetch a fresh ID token from the signed-in user
and perform ordinary application sign-out. The example never persists or logs
that token. It creates the real App Attest provider, streams `/v1/responses`
without buffering the response, captures the response and diagnostic request
IDs, verifies device trust, reads quota, revokes the installation exactly once,
and signs out Firebase on both success and failure.

When a quota or revocation operation returns a Latchway problem,
`LatchwayGoldenJourneyFailure.documentationURL` points to the stable public
error page. It deliberately excludes server detail and credentials.
