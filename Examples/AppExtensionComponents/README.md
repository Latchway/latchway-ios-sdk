# App-extension component example

This is a signed host-app plus WidgetKit extension scaffold, not simulated
proof. The containing app creates a component-specific P-256 key, registers
only its public JWK, and stores the resulting one-time grant in the access
group shared with this widget. The widget consumes that grant into its own
rotating session and sends a feature-bound request. It never receives the root
key, root refresh token, identity token, or an upstream-provider credential.

Generate and run an unsigned compile gate:

```bash
tuist generate --path Examples/AppExtensionComponents --no-open
xcodebuild \
  -project Examples/AppExtensionComponents/AppExtensionComponents.xcodeproj \
  -scheme AppExtensionComponents \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For a development-signed device build, set values that exist in the Latchway
Admin API and Apple Developer account before generation:

```bash
TUIST_LATCHWAY_COMPONENT_HOST_BUNDLE_ID=com.example.latchway.components \
TUIST_LATCHWAY_COMPONENT_GROUP_SUFFIX=com.example.latchway.components.widget \
TUIST_LATCHWAY_DEVELOPMENT_TEAM=YOURTEAMID \
TUIST_LATCHWAY_GATEWAY_URL=https://gateway.example.com \
TUIST_LATCHWAY_APPLICATION_ID=app_YOUR_CANONICAL_ID \
TUIST_LATCHWAY_ENVIRONMENT=development \
tuist generate --path Examples/AppExtensionComponents --no-open
```

Configure a `home_widget` component definition with the `weekly-summary`
feature. Add a current identity token only to the host scheme's
`LATCHWAY_IDENTITY_TOKEN` launch environment; never put it in source, the
widget, entitlements, or build settings. The host's private app-ID group is
first in its signed entitlements and the widget-shared group is second; the
widget carries only the shared group. Both runtime strings come from the
signed, expanded Info.plist and must look like
`TEAMID.com.example.latchway.components` and
`TEAMID.com.example.latchway.components.widget`; the SDK rejects the literal
`$(AppIdentifierPrefix)` token. The shared group is also supplied as an exact
legacy-scan boundary so a stale shared-first root record blocks without being
migrated or deleted.

The “Revoke family” action supplies the complete component descriptor list so
the server revokes the family and the host erases each root/component Keychain
record. A protected release claim additionally requires sibling-denial,
replacement, deletion, locked/background access, and uninstall checks on a
physical device. A successful local launch is not that evidence.
