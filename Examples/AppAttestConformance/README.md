# App Attest conformance application

This Tuist project is the source-owned physical production-evidence candidate.
One Release scheme builds the SwiftUI host plus exactly one WidgetKit, Share,
and Action extension. The host exercises registration, assertion reuse,
session establishment, a bounded stream, quota, exact DPoP replay rejection,
and a tampered-proof rejection. It also prepares three independent delegated
component keys and grants. Widget and Share consume delegated sessions only;
Action also consumes only its independently keyed delegated session. Apple
does not support `DCAppAttestService.generateKey` in iOS application
extensions, so only the containing app carries the App Attest entitlement.
The host's private app-ID Keychain group is first, followed by the three
component groups; each extension carries exactly its own shared group. The
resolved groups are read from the signed Info.plist. Before any identity,
App Attest, installation-key, or session operation, the SDK proves the private
group is the signed default and rejects stale root state at the explicit
component groups without migrating or deleting it.

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

The generated scheme uses Release. An unsigned build uses harmless development
defaults. A signed candidate must be produced with the fail-closed staging
script; do not hand-edit the generated project or pass signing secrets through
source:

```bash
scripts/build-physical-app-attest-candidate.sh /absolute/empty-output-parent
```

The builder requires externally supplied host/Widget/Share/Action bundle IDs,
profile specifiers and UUID pins, Team ID, App ID prefix, signing identity and
certificate SHA-256, Release version/build, HTTPS gateway/application/component
configuration, the exact source commit, and the pinned Xcode identity. It
accepts ad hoc distribution only because `run-physical-app-attest.sh`
side-loads the inspected `.app`. It never imports or creates a certificate or
profile, never enables Xcode-managed profile updates, and rejects runtime
identity/device grants in its environment. The staged JSON contains only safe
profile UUIDs, executable/profile/entitlement/certificate hashes, the
deterministic whole-`.app` tree digest and bounds metadata, source coordinates,
and the exact candidate-derived protected workflow-variable values. The tree
profile binds every directory, regular file, canonical path, permission mode,
file size, and file content while rejecting links, special files, case/NFC
collisions, excessive depth/count, and more than 1 GiB expanded data. ACLs,
extended attributes, and resource forks are intentionally outside the digest.
Gateway deployment, lease, device, and grant pins remain separate runtime
inputs.

For the current first-device setup, the root `dev.latchway` App ID and root
profile exist, but the three child extension App IDs/profiles, a qualifying
production App-Attest host profile, and a compatible
distribution signing identity/private key are not yet available. The unsigned
compile can pass without them; signed or physical extension evidence cannot.
App Attest Verification Resources remain gateway runtime secrets and are never
candidate-builder inputs.

The physical suite requires two distinct server-minted, lease-bound,
single-use identity grants: one audience ends in `/registration` and the other
ends in `/assertion`. The runner removes their exported raw names before any
child process, exposes them only as `DEVICECTL_CHILD_` values for the first
host launch, and clears all shell/child copies immediately afterward. Each
in-app provider returns its grant once and then becomes terminal. The app
consumes the assertion grant immediately after registration and its minimum
replay check; the longer conformance/component phase runs on the established
assertion session. After
component observation, the runner relaunches the host without either grant;
that phase can only load the persisted assertion session and fails closed
instead of attempting another identity establishment. The collector copies
the protected `.app` once into a private snapshot, validates the whole-tree
digest twice, and installs that same snapshot. The final profile and evidence
surface the same tree digest directly, and the fresh signer compares both to
the protected workflow value before attestation.
The runner strictly validates CoreDevice's install receipt and an independent
post-install inventory, then uses the receipt's Launch Services persistent
identifier for both launches. The signed Info.plist, launch environment,
collector lease, protected profile, and final evidence must all agree on the
Latchway application resource ID, environment, and identity-provider ID.

Use the protected workflow and `../../docs/real-device-conformance.md` for the
actual run. The app's only evidence document is
`Documents/latchway-device-observation.json`; it also writes bounded,
non-evidence coordination files for the independent component observer.
The root-owned physical collector separately produces
`component-observation.json` from the signed host/Widget/Share/Action candidate;
the app never fabricates component lifecycle claims. A safe, run-bound ready
marker coordinates host termination and extension activation, and a minimal
completion marker permits the no-identity relaunch to finish the root
revocation test. Neither marker is evidence or contains a pass claim. Neither observation is a
pass until the external signature, profile, schema, redaction, and physical-run
validator accepts both exact files.

The external observer must report `root_app_attest` only for the host,
`delegated_only` for Widget/Share/Action, a successful Action
`delegated_execution`, and the no-host/background/termination/no-presence
lifecycle. An observer that expects direct Action App Attest is incompatible
with iOS and cannot produce v1 evidence. The external lease issuer must also
emit the candidate application/environment/identity-provider configuration
and repeat those coordinates in both grant records; older root-owned issuer
and observer services must be upgraded before the physical gate can pass.
