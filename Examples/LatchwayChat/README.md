# LatchwayChat

A disposable native SwiftUI chat app demonstrating Firebase email/password
sign-up and login, real Apple App Attest, Secure Enclave DPoP, streamed chat,
and server-settled token quota against a deployed Latchway server.

## Current setup

- Gateway: `https://latchway.habitify.me`, running the private rich-Responses
  integration candidate over public server 1.0.1. Public server 1.0.2 includes
  the same Responses changes required by SDK 1.1.0.
- Separate application: `LatchwayChat (Disposable)` (`latchway-chat`).
- Application ID: `app_01M1RJ9GEX0RQ0J6VFRMVJYDZS`.
- Development environment: `env_01M1RJ9HVTXQQRV4QRD65NFRVS`.
- Features: `latchway-chat` (Chat Completions) and `latchway-foundation-models`
  (Responses); each has 100,000 total tokens/user/UTC day.
- Firebase project: `latchway`, matching the React Native example.
- iOS bundle: `dev.latchway`; Apple team: `PFK5S2E4H5`.
- Required development App Attest with any valid build version; no debug
  attestation or software-key fallback.
- Upstream/model: server-managed OpenRouter / `openai/gpt-5.6-luna`.

The project preserves the user's iOS 27 deployment target and automatic signing.
It links this repository's local Swift package and Firebase 12.15.0, the version
used by the React Native example. It exercises this repository's 1.1.0 adapter.
Installing it replaces the older React Native example on the same device because
both use `dev.latchway`.

## Build and run

1. Open `LatchwayChat/LatchwayChat.xcodeproj`.
2. Add the existing `GoogleService-Info.plist` for Firebase project `latchway`
   and iOS app `dev.latchway` to `LatchwayChat/LatchwayChat/`. This local client
   configuration is intentionally ignored by Git. Do not add a service-account
   JSON, upstream key, administrator token, or test password to the app.
3. Confirm Firebase Email/Password sign-in is enabled. Integration follows
   [Firebase's password-auth guide](https://firebase.google.com/docs/auth/ios/password-auth).
4. Select the connected physical iPhone and Debug configuration, then Run.
   App Attest cannot be demonstrated by replacing it with a simulator stub.

From this example directory:

```sh
xcodebuild -project LatchwayChat/LatchwayChat.xcodeproj \
  -scheme LatchwayChat -configuration Debug \
  -destination 'id=YOUR_DEVICE_UDID' \
  -derivedDataPath DerivedData -allowProvisioningUpdates build
```

Sign in or create an account, wait for the green device-verification status,
then ask about Latchway. Tap the shield for actual session/attestation/key-storage
diagnostics, quota, and the last correlation ID. Use the menu to clear the chat
or sign out. Sign-out revokes the active Latchway installation before clearing
Firebase identity; failed revocation leaves the user signed in to retry.

## Choose a chat engine

Open **Settings** from the chat toolbar or menu:

- **Foundation Models** uses Apple's `LanguageModelSession` and the optional
  Latchway executor. The model still runs remotely through the gateway, not on
  the device. Ask for weather in Singapore, then “What about Ho Chi Minh City?”
  The framework invokes the real `WeatherCheckTool`, preserves the complete
  call/result history, and asks the provider to finish the reply. Green lookup
  cards show only completed real Open-Meteo requests.
- **Custom URLSession** keeps the original direct streaming Chat Completions
  implementation. It does not expose a weather tool.

Switching engines clears the in-memory conversation without signing out.
Weather lookup sends a city name to Open-Meteo geocoding and coordinates to its
forecast API; the app never requests GPS access. No weather key is needed for
this disposable non-commercial demo. Results credit Open-Meteo and GeoNames.
See [the SDK guide](../../Documentation/FoundationModels.md) for guided output,
sampling, metadata, reasoning, and backend-dependent limits.
The demo requests non-reasoning mode because this server's strict text-based
quota profile cannot safely count encrypted reasoning history. It does not
disable quota enforcement or discard returned reasoning to get a test to pass.

The assistant uses the bundled `LatchwayKnowledge.md` reference, not live
browsing or administrative tools. It can explain architecture, integration,
configuration, deployment, routing, and quotas, but must acknowledge missing
information and may still make mistakes. The wire-format `model` is an untrusted
alias that the server rewrites, not a client-selected physical model.

## Privacy and limits

Chat messages remain in process memory only, with at most twenty displayed
messages and four previous turns in the next request. Clear/sign-out/relaunch
removes the conversation. No Firestore or chat-history storage is used.
Firebase and Latchway securely persist necessary authentication/session state.
The gateway stores redacted usage/request metadata; OpenRouter processes the
conversation according to its own policies. Each reply requests at most 1,024
output tokens. The gateway, not the client, enforces quotas and determines usage.

## Physical verification

Verified on a connected iPhone 16 Pro running iOS 27 on 2026-09-05:

- Actual Firebase email/password signup, sign-out, and password login succeeded.
- The server recorded an iOS installation with `app_attest` / `app_verified`;
  the SDK reported `secure_enclave` key storage.
- A streamed provider response completed and the server recorded one successful
  upstream attempt with 2,143 input + 209 output = 2,352 total tokens.
- The on-device quota snapshot also reported 2,352 used tokens.
- Logical request: `req_01M1RK8XNRB5NRAWJGDFYMKTYB`.
- An earlier missing-model request was correctly denied before provider dispatch;
  the example was corrected, and that diagnostic remains in the server history.

This proves the native **development** flow on this device and gateway. It is
not App Store/TestFlight production App Attest evidence, an extension proof,
Android evidence, or a comprehensive security/load certification.

The 1.1.0 candidate was subsequently exercised on the same phone through
VPS-local server `1.0.2-dev.fm110.3`. Foundation Models completed Singapore
then Ho Chi Minh City, with two real tool lookups and four successful Responses
requests totaling 11,200 provider-reported tokens. The final server request was
`req_01M1RRS4RH3Q4AQF46Q5MJWM45`. The Custom URLSession engine also completed
again after the upgrade. Both preserve real Firebase identity and App Attest
trust with Secure Enclave keys; no upstream secret is in the app.

Debug-only launch argument `--verify-demo` creates a unique disposable Firebase
email/password account, signs it out, signs it back in, and exercises the same
session/chat path as the UI. `--verify-chat` reuses the current Firebase identity
and tests the chat without creating another account. No fake provider, custom
identity-token bridge, attestation bypass, or hard-coded success is used.
These modes save only redacted verification metadata to
`Documents/device-verification.json`; no passwords, tokens, evidence, or chat
content are written. Normal app launches do not run the test or write this file.

`--verify-foundation-models` reuses the signed-in identity and runs the two-city
weather conversation. Its separate `foundation-models-verification.json`
receipt records success, lookup locations, correlation IDs, trust, and quota,
never chat or credentials. A failed run is not successful integration evidence.
When adding a feature to an existing component, its already-issued grant does
not gain that feature automatically. The one-time, Debug-only
`--renew-demo-grant` explicitly revokes this disposable installation; relaunch
after it completes to register again with the current feature allowlist.
Do not use that destructive diagnostic for ordinary engine switching.

## Cleanup later

Delete only the disposable `latchway-chat` application and its environment/secrets
through the Admin API or Console, plus its disposable test user in Firebase
project `latchway`. Do not delete the Firebase project, Apple bundle identifier,
or either real Habitify environment. Uninstalling `dev.latchway` removes this
demo from the device. Secure Keychain state may survive uninstall; use normal
sign-out/revocation first. The private operator verification record retains the
exact Firebase test UID and server resource IDs for scoped cleanup.
