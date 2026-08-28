# Real-device App Attest conformance

The final Apple gate requires a supported physical iPhone or iPad. Simulator,
macOS, fixture, and debug-attestation runs do not satisfy it.

## Prerequisites

- Apple Developer team with App Attest enabled for a unique application ID
- Development provisioning profile containing the App Attest entitlement
- Physical supported device registered to the team
- Reachable Latchway environment configured for that exact bundle ID, team ID,
  App Attest `development` environment, identity provider, and feature
- Non-production test identity and an identity token acquired immediately
  before the run

Production evidence must use the separate production entitlement and a server
policy that rejects development attestations. Never allow development evidence
in a production environment.

## Build-only verification

Generate the deployable sample application, then check its complete iOS graph
without signing or claiming App Attest success:

```bash
tuist generate --path Examples/AppAttestConformance --no-open

xcodebuild \
  -project Examples/AppAttestConformance/AppAttestConformance.xcodeproj \
  -scheme AppAttestConformance \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Physical-device run

Generate the project with a bundle identifier owned by the Apple Developer
team and that team's identifier:

```bash
TUIST_LATCHWAY_CONFORMANCE_BUNDLE_ID=com.example.your-conformance-app \
TUIST_LATCHWAY_DEVELOPMENT_TEAM=YOURTEAMID \
TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT=development \
tuist generate --path Examples/AppAttestConformance --no-open
```

Open `Examples/AppAttestConformance/AppAttestConformance.xcodeproj` in Xcode,
select the `AppAttestConformance` scheme and the physical device, then verify:

- the generated bundle identifier and development team;
- the App Attest capability and development provisioning profile;
- these scheme environment values:
  `LATCHWAY_BASE_URL`, `LATCHWAY_APPLICATION_ID`, `LATCHWAY_ENVIRONMENT`,
  `LATCHWAY_IDENTITY_PROVIDER`, `LATCHWAY_IDENTITY_TOKEN`, and
  `LATCHWAY_FEATURE`.

Run the application and select **Run conformance** for the registration pass.
After it succeeds, select **Run assertion pass**. That action clears only the
stored Latchway session, preserving the App Attest and Secure Enclave keys so a
fresh challenge must use an assertion. Capture redacted screens showing
identity configured, Secure Enclave storage, App Attest supported, the
attestation and assertion results, active sessions, streamed request passes,
quota passes, and installation ID. The app never renders the identity, access,
refresh, or DPoP tokens.

For a production-only verification, regenerate with
`TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT=production`; the manifest selects the
separate production entitlement. Never point that build at a policy that
accepts development attestations.

The exact remaining credential-dependent validation is:

```text
Run AppAttestConformance on the provisioned physical device against the exact
core image for contract 0.2.0, complete one real App Attest registration and a
streamed /v1/chat/completions request, then use Run assertion pass to prove
assertion mode with the same App Attest key.
```
