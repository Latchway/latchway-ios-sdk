# App Attest conformance application

This is a deployable SwiftUI application, generated with Tuist 4.200 or newer,
for the physical-device gate. It is not an App Attest simulator and cannot turn
fixture or debug evidence into a production success claim.

Generate an unsigned build project with:

```bash
tuist generate --path Examples/AppAttestConformance --no-open
```

For a signed run, pass a team-owned bundle identifier and development team as
documented in `../../docs/real-device-conformance.md`. The default manifest
selects the development App Attest entitlement; production is an explicit,
separate generation setting.

After the registration run succeeds, **Run assertion pass** clears only the
Latchway refresh session. It preserves the Secure Enclave and App Attest keys,
forcing the next session challenge to exercise App Attest assertion mode.
