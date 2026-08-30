# App Attest conformance application

This Tuist-generated SwiftUI app is the physical production-evidence client.
It exercises registration, assertion reuse, session establishment, a bounded
stream, quota, exact DPoP replay rejection, and a tampered-proof rejection.

An unsigned compile is a useful static gate only:

```bash
tuist generate --path Examples/AppAttestConformance --no-open
xcodebuild \
  -project Examples/AppAttestConformance/AppAttestConformance.xcodeproj \
  -scheme AppAttestConformance \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The generated scheme uses Release. Production generation also requires a
team-owned bundle ID, Team ID, version, build, and production entitlement:

```bash
TUIST_LATCHWAY_CONFORMANCE_BUNDLE_ID=com.example.latchway.conformance \
TUIST_LATCHWAY_DEVELOPMENT_TEAM=YOURTEAMID \
TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT=production \
TUIST_LATCHWAY_CONFORMANCE_VERSION=1.0.0 \
TUIST_LATCHWAY_CONFORMANCE_BUILD=1 \
tuist generate --path Examples/AppAttestConformance --no-open
```

Use the protected workflow and `../../docs/real-device-conformance.md` for the
actual run. The app writes only `Documents/latchway-device-observation.json`.
The root-owned physical collector separately produces
`component-observation.json` from the signed host/Widget/Share/Action candidate;
the app never fabricates component lifecycle claims. Neither observation is a
pass until the external signature, profile, schema, redaction, and physical-run
validator accepts both exact files.
