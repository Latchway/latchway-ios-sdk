#!/bin/bash
set +x
set -euo pipefail

# GitHub injects the two one-use grants as exported variables. Move them into
# shell-only slots and remove the exported names before even command
# substitution, tool discovery, candidate inspection, or gateway capture can
# start a child process.
latchway_registration_grant="${LATCHWAY_REGISTRATION_IDENTITY_TOKEN:-}"
latchway_assertion_grant="${LATCHWAY_ASSERTION_IDENTITY_TOKEN:-}"
unset LATCHWAY_REGISTRATION_IDENTITY_TOKEN
unset LATCHWAY_ASSERTION_IDENTITY_TOKEN
export -n latchway_registration_grant latchway_assertion_grant

for environment_name in "${!DEVICECTL_CHILD_@}"; do
  echo "pre-existing CoreDevice child environment is forbidden" >&2
  exit 2
done
for environment_name in "${!LATCHWAY_@}"; do
  case "$environment_name" in
    LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256|LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256)
      ;;
    *TOKEN*|*GRANT*)
      echo "unexpected ambient identity or device grant is forbidden" >&2
      exit 2
      ;;
  esac
done

# This runner intentionally operates only on a caller-supplied signed app and
# one explicitly selected CoreDevice. It does not create signing credentials,
# deploy a gateway, or turn a local/debug run into release evidence.

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
schema_path="$repository_root/Conformance/physical-device-evidence.schema.json"

required_variables=(
  LATCHWAY_EVIDENCE_OUTPUT_DIR
  LATCHWAY_IOS_DEVICE_ID
  LATCHWAY_IOS_APP_BUNDLE_PATH
  LATCHWAY_IOS_INSTALL_MODE
  LATCHWAY_BUNDLE_ID
  LATCHWAY_IOS_WIDGET_BUNDLE_ID
  LATCHWAY_IOS_SHARE_BUNDLE_ID
  LATCHWAY_IOS_ACTION_BUNDLE_ID
  LATCHWAY_HOST_COMPONENT_DEFINITION_ID
  LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID
  LATCHWAY_SHARE_COMPONENT_DEFINITION_ID
  LATCHWAY_ACTION_COMPONENT_DEFINITION_ID
  LATCHWAY_APP_VERSION
  LATCHWAY_BUILD_NUMBER
  LATCHWAY_TEAM_ID
  LATCHWAY_APP_ID_PREFIX
  LATCHWAY_SIGNING_CERTIFICATE_SHA256
  LATCHWAY_APP_BINARY_SHA256
  LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256
  LATCHWAY_IOS_WIDGET_BINARY_SHA256
  LATCHWAY_IOS_SHARE_BINARY_SHA256
  LATCHWAY_IOS_ACTION_BINARY_SHA256
  LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID
  LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256
  LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256
  LATCHWAY_COLLECTOR_TRUST_ROOT_PATH
  LATCHWAY_COLLECTOR_TRUST_ROOT_SHA256
  LATCHWAY_DISTRIBUTION
  LATCHWAY_SOURCE_COMMIT
  LATCHWAY_CORE_COMMIT
  LATCHWAY_SDK_VERSION
  LATCHWAY_CONTRACT_VERSION
  LATCHWAY_CONTRACT_BUNDLE_SHA256
  LATCHWAY_GATEWAY_IMAGE_DIGEST
  LATCHWAY_GATEWAY_CONFIGURATION_SHA256
  LATCHWAY_GATEWAY_ORIGIN
  LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID
  LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256
  LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_PATH
  LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256
  LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL
  LATCHWAY_BASE_URL
  LATCHWAY_APPLICATION_ID
  LATCHWAY_ENVIRONMENT
  LATCHWAY_IDENTITY_PROVIDER
  LATCHWAY_FEATURE
  LATCHWAY_ERROR_MAPPING_FEATURE
  LATCHWAY_MODEL
  LATCHWAY_RUN_ID
)

for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "required environment variable is missing: $variable_name" >&2
    exit 2
  fi
done

# shellcheck source=scripts/gateway-deployment-evidence.sh
source "$repository_root/scripts/gateway-deployment-evidence.sh"
for tool in cmp curl ditto install openssl python3 security shasum; do
  command -v "$tool" >/dev/null || { echo "required tool is unavailable: $tool" >&2; exit 2; }
done
component_observer_hook=/usr/local/libexec/latchway-ios-component-evidence-observer
if [[ ! -f "$component_observer_hook" || -L "$component_observer_hook" || ! -x "$component_observer_hook" ]]; then
  echo "the root-owned iOS component evidence observer is unavailable" >&2
  exit 2
fi

[[ "$LATCHWAY_IOS_INSTALL_MODE" == install ]] || {
  echo "physical evidence requires installing the pinned app bundle" >&2
  exit 2
}
case "$LATCHWAY_DISTRIBUTION" in
  ad_hoc|testflight|app_store) ;;
  *) echo "LATCHWAY_DISTRIBUTION is not release eligible" >&2; exit 2 ;;
esac
[[ "$LATCHWAY_APP_ID_PREFIX" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "invalid protected Apple App ID prefix" >&2
  exit 2
}
[[ "$LATCHWAY_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || {
  echo "invalid protected Apple Team ID" >&2
  exit 2
}
if [[ "$latchway_registration_grant" == "$latchway_assertion_grant" \
   || ${#latchway_registration_grant} -lt 16 \
   || ${#latchway_registration_grant} -gt 65536 \
   || ${#latchway_assertion_grant} -lt 16 \
   || ${#latchway_assertion_grant} -gt 65536 ]]; then
  echo "registration and assertion grants must be distinct bounded values" >&2
  exit 2
fi
for identifier in \
  "$LATCHWAY_BUNDLE_ID" \
  "$LATCHWAY_IOS_WIDGET_BUNDLE_ID" \
  "$LATCHWAY_IOS_SHARE_BUNDLE_ID" \
  "$LATCHWAY_IOS_ACTION_BUNDLE_ID"; do
  [[ "$identifier" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{2,254}$ ]] || {
    echo "invalid protected component bundle identifier" >&2
    exit 2
  }
done
[[ "$LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "invalid protected application bundle-tree hash" >&2
  exit 2
}
if [[ "$(printf '%s\n' \
  "$LATCHWAY_BUNDLE_ID" \
  "$LATCHWAY_IOS_WIDGET_BUNDLE_ID" \
  "$LATCHWAY_IOS_SHARE_BUNDLE_ID" \
  "$LATCHWAY_IOS_ACTION_BUNDLE_ID" | LC_ALL=C sort -u | wc -l | tr -d ' ')" != 4 ]]; then
  echo "protected component bundle identifiers must be distinct" >&2
  exit 2
fi
for definition in \
  "$LATCHWAY_HOST_COMPONENT_DEFINITION_ID" \
  "$LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID" \
  "$LATCHWAY_SHARE_COMPONENT_DEFINITION_ID" \
  "$LATCHWAY_ACTION_COMPONENT_DEFINITION_ID"; do
  [[ "$definition" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || {
    echo "invalid protected component definition identifier" >&2
    exit 2
  }
done
for digest in \
  "$LATCHWAY_APP_BINARY_SHA256" \
  "$LATCHWAY_IOS_WIDGET_BINARY_SHA256" \
  "$LATCHWAY_IOS_SHARE_BINARY_SHA256" \
  "$LATCHWAY_IOS_ACTION_BINARY_SHA256"; do
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid protected component executable hash" >&2
    exit 2
  }
done
[[ "$LATCHWAY_BASE_URL" == "$LATCHWAY_GATEWAY_ORIGIN" ]] || {
  echo "application base URL must exactly match the signed gateway origin" >&2
  exit 2
}
[[ "$LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256" =~ ^[0-9a-f]{64}$ && "$LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "invalid gateway deployment hash pin" >&2
  exit 2
}
[[ "$LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL" == app_verified ]] || {
  echo "App Attest gateway policy requires exact app_verified trust" >&2
  exit 2
}
[[ "$LATCHWAY_APPLICATION_ID" =~ ^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$ ]] || {
  echo "invalid protected Latchway application resource ID" >&2
  exit 2
}
for configuration_value in "$LATCHWAY_ENVIRONMENT" "$LATCHWAY_IDENTITY_PROVIDER"; do
  [[ "$configuration_value" =~ ^[a-z][a-z0-9_-]{0,62}$ ]] || {
    echo "invalid protected Latchway environment or identity provider" >&2
    exit 2
  }
done
for grant_sha256 in \
  "$LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256" \
  "$LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256"; do
  [[ "$grant_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "invalid protected one-use grant hash" >&2
    exit 2
  }
done
[[ "$LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256" != "$LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256" ]] || {
  echo "one-use grant hashes must be distinct" >&2
  exit 2
}
actual_registration_grant_sha256="$(printf '%s' "$latchway_registration_grant" | shasum -a 256 | awk '{print $1}')"
actual_assertion_grant_sha256="$(printf '%s' "$latchway_assertion_grant" | shasum -a 256 | awk '{print $1}')"
if [[ "$actual_registration_grant_sha256" != "$LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256" \
   || "$actual_assertion_grant_sha256" != "$LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256" ]]; then
  latchway_registration_grant=""
  latchway_assertion_grant=""
  echo "one-use grants do not match the protected signed hashes" >&2
  exit 1
fi
actual_registration_grant_sha256=""
actual_assertion_grant_sha256=""
if [[ ! -f "$LATCHWAY_COLLECTOR_TRUST_ROOT_PATH" || -L "$LATCHWAY_COLLECTOR_TRUST_ROOT_PATH" \
   || ! "$LATCHWAY_COLLECTOR_TRUST_ROOT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "signed collector-lease trust root is missing or unsafe" >&2
  exit 2
fi

if [[ ! -d "$LATCHWAY_IOS_APP_BUNDLE_PATH" || -L "$LATCHWAY_IOS_APP_BUNDLE_PATH" ]]; then
  echo "LATCHWAY_IOS_APP_BUNDLE_PATH must be a real .app directory" >&2
  exit 2
fi
if [[ "$LATCHWAY_IOS_APP_BUNDLE_PATH" != /* || "$LATCHWAY_IOS_APP_BUNDLE_PATH" != *.app ]]; then
  echo "LATCHWAY_IOS_APP_BUNDLE_PATH must be an absolute path ending in .app" >&2
  exit 2
fi

mkdir -p "$LATCHWAY_EVIDENCE_OUTPUT_DIR"
output_dir="$(cd "$LATCHWAY_EVIDENCE_OUTPUT_DIR" && pwd -P)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/latchway-app-attest.XXXXXX")"
cleanup() {
  if [[ -n "$temporary_root" && -d "$temporary_root" && "$temporary_root" == */latchway-app-attest.* ]]; then
    rm -rf "$temporary_root"
  fi
  unset DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN
  unset DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN
  latchway_registration_grant=""
  latchway_assertion_grant=""
  unset latchway_registration_grant
  unset latchway_assertion_grant
}
trap cleanup EXIT

if [[ "$(shasum -a 256 "$LATCHWAY_COLLECTOR_TRUST_ROOT_PATH" | awk '{print $1}')" \
   != "$LATCHWAY_COLLECTOR_TRUST_ROOT_SHA256" ]]; then
  echo "collector-lease trust root does not match the protected hash" >&2
  exit 1
fi

caller_app_bundle_path="$LATCHWAY_IOS_APP_BUNDLE_PATH"
snapshot_directory="$temporary_root/candidate-snapshot"
install -d -m 0700 "$snapshot_directory"
snapshot_app_bundle_path="$snapshot_directory/AppAttestConformance.app"
ditto --norsrc "$caller_app_bundle_path" "$snapshot_app_bundle_path"
unset caller_app_bundle_path
LATCHWAY_IOS_APP_BUNDLE_PATH="$snapshot_app_bundle_path"
export LATCHWAY_IOS_APP_BUNDLE_PATH
snapshot_tree_sha256="$(python3 "$repository_root/scripts/physical_app_bundle_tree.py" "$LATCHWAY_IOS_APP_BUNDLE_PATH")"
if [[ "$snapshot_tree_sha256" != "$LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256" ]]; then
  echo "private application snapshot does not match the protected bundle-tree hash" >&2
  exit 1
fi

actual_commit="$(git -C "$repository_root" rev-parse HEAD)"
if [[ "$actual_commit" != "$LATCHWAY_SOURCE_COMMIT" ]]; then
  echo "source commit does not match the protected run input" >&2
  exit 1
fi

verify_profile_uuid() {
  local bundle="$1"
  local label="$2"
  local expected_uuid="$3"
  local embedded="$bundle/embedded.mobileprovision"
  local decoded="$temporary_root/$label-profile.plist"
  if [[ ! -f "$embedded" || -L "$embedded" || ! "$expected_uuid" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "$label embedded provisioning profile or UUID pin is invalid" >&2
    exit 1
  fi
  if ! security cms -D -i "$embedded" >"$decoded" 2>/dev/null; then
    openssl smime -verify -inform der -noverify -in "$embedded" >"$decoded" 2>/dev/null || {
      echo "$label provisioning-profile CMS verification failed" >&2
      exit 1
    }
  fi
  local actual_uuid
  actual_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$decoded")"
  if [[ "$actual_uuid" != "$expected_uuid" ]]; then
    echo "$label provisioning-profile UUID does not match the protected pin" >&2
    exit 1
  fi
}
if [[ -n "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "physical release evidence requires a clean source worktree" >&2
  exit 1
fi

info_plist="$LATCHWAY_IOS_APP_BUNDLE_PATH/Info.plist"
if [[ ! -f "$info_plist" || -L "$info_plist" ]]; then
  echo "signed application Info.plist is missing or unsafe" >&2
  exit 1
fi
actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"
actual_latchway_application_id="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayApplicationID' "$info_plist")"
actual_latchway_environment="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayEnvironment' "$info_plist")"
actual_identity_provider="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayIdentityProvider' "$info_plist")"
if [[ "$actual_bundle_id" != "$LATCHWAY_BUNDLE_ID" || "$actual_version" != "$LATCHWAY_APP_VERSION" || "$actual_build" != "$LATCHWAY_BUILD_NUMBER" ]]; then
  echo "signed application identity does not match protected pins" >&2
  exit 1
fi
if [[ "$actual_latchway_application_id" != "$LATCHWAY_APPLICATION_ID" \
   || "$actual_latchway_environment" != "$LATCHWAY_ENVIRONMENT" \
   || "$actual_identity_provider" != "$LATCHWAY_IDENTITY_PROVIDER" ]]; then
  echo "signed Latchway tenant/auth configuration does not match protected pins" >&2
  exit 1
fi
if [[ ! -f "$LATCHWAY_IOS_APP_BUNDLE_PATH/$actual_executable" || -L "$LATCHWAY_IOS_APP_BUNDLE_PATH/$actual_executable" ]]; then
  echo "signed application executable is missing or unsafe" >&2
  exit 1
fi

python3 - "$LATCHWAY_IOS_APP_BUNDLE_PATH/PlugIns" \
  "$LATCHWAY_IOS_WIDGET_BUNDLE_ID" \
  "$LATCHWAY_IOS_SHARE_BUNDLE_ID" \
  "$LATCHWAY_IOS_ACTION_BUNDLE_ID" <<'PY'
import pathlib, plistlib, sys

plugins = pathlib.Path(sys.argv[1])
if not plugins.is_dir() or plugins.is_symlink():
    raise SystemExit("candidate PlugIns directory is missing or unsafe")
entries = list(plugins.iterdir())
if len(entries) != 3 or any(
    entry.suffix != ".appex" or not entry.is_dir() or entry.is_symlink()
    for entry in entries
):
    raise SystemExit("candidate must embed exactly three real app extensions")
identifiers = []
for entry in entries:
    info = entry / "Info.plist"
    if not info.is_file() or info.is_symlink():
        raise SystemExit("embedded extension Info.plist is missing or unsafe")
    value = plistlib.loads(info.read_bytes())
    identifiers.append(value.get("CFBundleIdentifier"))
if len(set(identifiers)) != 3 or set(identifiers) != set(sys.argv[2:]):
    raise SystemExit("embedded extension set does not match the protected pins")
PY

codesign --verify --deep --strict "$LATCHWAY_IOS_APP_BUNDLE_PATH"
verify_profile_uuid "$LATCHWAY_IOS_APP_BUNDLE_PATH" host "$LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID"
entitlements_path="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$LATCHWAY_IOS_APP_BUNDLE_PATH" >"$entitlements_path" 2>/dev/null
actual_team_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements_path")"
actual_app_attest_environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.devicecheck.appattest-environment' "$entitlements_path")"
actual_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$entitlements_path")"
actual_get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$entitlements_path" 2>/dev/null || true)"
if [[ "$actual_team_id" != "$LATCHWAY_TEAM_ID" || "$actual_application_identifier" != "$LATCHWAY_APP_ID_PREFIX.$LATCHWAY_BUNDLE_ID" ]]; then
  echo "signed Apple team/application identifier does not match protected pins" >&2
  exit 1
fi
if [[ "$actual_app_attest_environment" != production ]]; then
  echo "release evidence requires the production App Attest entitlement" >&2
  exit 1
fi
python3 - "$entitlements_path" \
  "$LATCHWAY_APP_ID_PREFIX.$LATCHWAY_BUNDLE_ID" \
  "$LATCHWAY_APP_ID_PREFIX.$LATCHWAY_IOS_WIDGET_BUNDLE_ID" \
  "$LATCHWAY_APP_ID_PREFIX.$LATCHWAY_IOS_SHARE_BUNDLE_ID" \
  "$LATCHWAY_APP_ID_PREFIX.$LATCHWAY_IOS_ACTION_BUNDLE_ID" <<'PY'
import pathlib, plistlib, sys
value = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
groups = value.get("keychain-access-groups")
if not isinstance(groups, list) or len(groups) != len(set(groups)) or set(groups) != set(sys.argv[2:]):
    raise SystemExit("host Keychain groups do not include exactly root, Widget, Share, and Action")
PY
if [[ -n "$actual_get_task_allow" && "$actual_get_task_allow" != false ]]; then
  echo "release evidence rejects applications signed with get-task-allow" >&2
  exit 1
fi

certificate_prefix="$temporary_root/signing-certificate"
codesign -d --extract-certificates "$certificate_prefix" "$LATCHWAY_IOS_APP_BUNDLE_PATH" 2>/dev/null
actual_certificate_sha256="$(shasum -a 256 "${certificate_prefix}0" | awk '{print $1}')"
actual_binary_sha256="$(shasum -a 256 "$LATCHWAY_IOS_APP_BUNDLE_PATH/$actual_executable" | awk '{print $1}')"
if [[ "$actual_certificate_sha256" != "$LATCHWAY_SIGNING_CERTIFICATE_SHA256" || "$actual_binary_sha256" != "$LATCHWAY_APP_BINARY_SHA256" ]]; then
  echo "signed application certificate or executable hash does not match protected pins" >&2
  exit 1
fi

verify_component_extension() {
  local label="$1"
  local expected_bundle_id="$2"
  local expected_binary_sha256="$3"
  local expected_extension_point="$4"
  local expected_profile_uuid="$5"
  local matched=""
  local count=0
  local candidate candidate_plist candidate_bundle_id
  for candidate in "$LATCHWAY_IOS_APP_BUNDLE_PATH"/PlugIns/*.appex; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    candidate_plist="$candidate/Info.plist"
    [[ -f "$candidate_plist" && ! -L "$candidate_plist" ]] || continue
    candidate_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_plist" 2>/dev/null || true)"
    if [[ "$candidate_bundle_id" == "$expected_bundle_id" ]]; then
      matched="$candidate"
      count=$((count + 1))
    fi
  done
  if [[ "$count" != 1 || -z "$matched" ]]; then
    echo "signed candidate must contain exactly one $label component" >&2
    exit 1
  fi
  local plist="$matched/Info.plist"
  local executable extension_point extension_version extension_build binary_hash extension_entitlements extension_team extension_application_id
  local extension_latchway_application_id extension_latchway_environment extension_identity_provider
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
  extension_point="$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist")"
  extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
  extension_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
  extension_latchway_application_id="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayApplicationID' "$plist")"
  extension_latchway_environment="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayEnvironment' "$plist")"
  extension_identity_provider="$(/usr/libexec/PlistBuddy -c 'Print :LatchwayIdentityProvider' "$plist")"
  if [[ "$extension_point" != "$expected_extension_point" || "$extension_version" != "$LATCHWAY_APP_VERSION" || "$extension_build" != "$LATCHWAY_BUILD_NUMBER" || ! -f "$matched/$executable" || -L "$matched/$executable" ]]; then
    echo "$label extension identity or executable is invalid" >&2
    exit 1
  fi
  if [[ "$extension_latchway_application_id" != "$LATCHWAY_APPLICATION_ID" \
     || "$extension_latchway_environment" != "$LATCHWAY_ENVIRONMENT" \
     || "$extension_identity_provider" != "$LATCHWAY_IDENTITY_PROVIDER" ]]; then
    echo "$label signed Latchway tenant/auth configuration does not match protected pins" >&2
    exit 1
  fi
  codesign --verify --strict "$matched"
  verify_profile_uuid "$matched" "$label" "$expected_profile_uuid"
  extension_entitlements="$temporary_root/$label-entitlements.plist"
  codesign -d --entitlements :- "$matched" >"$extension_entitlements" 2>/dev/null
  extension_team="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$extension_entitlements")"
  extension_application_id="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$extension_entitlements")"
  if [[ "$extension_team" != "$LATCHWAY_TEAM_ID" || "$extension_application_id" != "$LATCHWAY_APP_ID_PREFIX.$expected_bundle_id" ]]; then
    echo "$label extension signing identity does not match protected pins" >&2
    exit 1
  fi
  local extension_get_task_allow
  extension_get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$extension_entitlements" 2>/dev/null || true)"
  if [[ -n "$extension_get_task_allow" && "$extension_get_task_allow" != false ]]; then
    echo "$label extension is debuggable" >&2
    exit 1
  fi
  python3 - "$extension_entitlements" "$LATCHWAY_APP_ID_PREFIX.$expected_bundle_id" <<'PY'
import pathlib, plistlib, sys
value = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
groups = value.get("keychain-access-groups")
if not isinstance(groups, list) or groups != [sys.argv[2]]:
    raise SystemExit("extension Keychain group is not component-isolated")
PY
  local extension_certificate_prefix extension_certificate_sha256
  extension_certificate_prefix="$temporary_root/$label-signing-certificate"
  codesign -d --extract-certificates "$extension_certificate_prefix" "$matched" 2>/dev/null
  extension_certificate_sha256="$(shasum -a 256 "${extension_certificate_prefix}0" | awk '{print $1}')"
  if [[ "$extension_certificate_sha256" != "$LATCHWAY_SIGNING_CERTIFICATE_SHA256" ]]; then
    echo "$label extension signing certificate does not match the protected candidate" >&2
    exit 1
  fi
  binary_hash="$(shasum -a 256 "$matched/$executable" | awk '{print $1}')"
  if [[ "$binary_hash" != "$expected_binary_sha256" ]]; then
    echo "$label extension executable hash does not match the protected candidate" >&2
    exit 1
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.devicecheck.appattest-environment' "$extension_entitlements" >/dev/null 2>&1; then
    echo "$label must remain delegated-only without an App Attest entitlement" >&2
    exit 1
  fi
}

verify_component_extension \
  widget "$LATCHWAY_IOS_WIDGET_BUNDLE_ID" "$LATCHWAY_IOS_WIDGET_BINARY_SHA256" \
  com.apple.widgetkit-extension "$LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_UUID"
verify_component_extension \
  share "$LATCHWAY_IOS_SHARE_BUNDLE_ID" "$LATCHWAY_IOS_SHARE_BINARY_SHA256" \
  com.apple.share-services "$LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_UUID"
verify_component_extension \
  action "$LATCHWAY_IOS_ACTION_BUNDLE_ID" "$LATCHWAY_IOS_ACTION_BINARY_SHA256" \
  com.apple.ui-services "$LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID"

validate_signed_lease_before_launch() {
  local phase="$1"
  local lease=/etc/latchway/physical-collector/lease.json
  local signature=/etc/latchway/physical-collector/lease.sig
  if [[ ! -f "$lease" || -L "$lease" || ! -f "$signature" || -L "$signature" ]]; then
    echo "signed physical-collector lease is missing or unsafe" >&2
    exit 1
  fi
  openssl dgst -sha256 -verify "$LATCHWAY_COLLECTOR_TRUST_ROOT_PATH" \
    -signature "$signature" "$lease" >/dev/null
  python3 - "$lease" "$phase" \
    "$LATCHWAY_SOURCE_COMMIT" "$LATCHWAY_RUN_ID" \
    "$LATCHWAY_APPLICATION_ID" "$LATCHWAY_ENVIRONMENT" "$LATCHWAY_IDENTITY_PROVIDER" \
    "$LATCHWAY_REGISTRATION_DEVICE_GRANT_SHA256" "$LATCHWAY_ASSERTION_DEVICE_GRANT_SHA256" \
    "$LATCHWAY_APP_BINARY_SHA256" "$LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256" \
    "$LATCHWAY_IOS_WIDGET_BINARY_SHA256" "$LATCHWAY_IOS_SHARE_BINARY_SHA256" \
    "$LATCHWAY_IOS_ACTION_BINARY_SHA256" <<'PY'
import json, pathlib, sys, time

def reject_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SystemExit("collector lease contains duplicate JSON members")
        result[key] = value
    return result

path = pathlib.Path(sys.argv[1])
if path.is_symlink() or not path.is_file() or not 1 <= path.stat().st_size <= 1_048_576:
    raise SystemExit("collector lease is missing, unsafe, or oversized")
try:
    lease = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates)
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit("collector lease is invalid UTF-8 JSON") from None
(
    phase, source_commit, run_id, application_id, environment, identity_provider,
    registration_sha256, assertion_sha256, host_sha256, tree_sha256,
    widget_sha256, share_sha256, action_sha256,
) = sys.argv[2:]
now = int(time.time())
if phase not in {"initial", "resume"}:
    raise SystemExit("collector lease validation phase is invalid")
workflow = lease.get("workflow")
if not isinstance(workflow, dict) or set(workflow) != {"run_id", "run_attempt", "job", "audience"}:
    raise SystemExit("collector lease workflow coordinates are invalid")
if (
    workflow.get("job") != "app-attest-production"
    or workflow.get("audience") != "ios-app-attest"
    or run_id != f"app-attest-{workflow.get('run_id')}-{workflow.get('run_attempt')}"
    or lease.get("source_commit") != source_commit
):
    raise SystemExit("collector lease does not match the protected run/source")
candidate = lease.get("candidate")
expected_artifacts = {
    "ios_app_binary_sha256": host_sha256,
    "ios_app_bundle_tree_sha256": tree_sha256,
    "ios_widget_binary_sha256": widget_sha256,
    "ios_share_binary_sha256": share_sha256,
    "ios_action_binary_sha256": action_sha256,
}
expected_configuration = {
    "application_id": application_id,
    "environment": environment,
    "identity_provider": identity_provider,
}
if (
    not isinstance(candidate, dict)
    or candidate.get("artifacts") != expected_artifacts
    or candidate.get("configuration") != expected_configuration
):
    raise SystemExit("collector lease does not bind the exact candidate and tenant/auth configuration")
grants = lease.get("grants")
if not isinstance(grants, dict) or set(grants) != {"registration", "assertion"}:
    raise SystemExit("collector lease grant set is invalid")
grant_fields = {
    "audience", "application_id", "environment", "identity_provider",
    "source_commit", "run_id", "run_attempt", "sha256", "single_use",
    "jti_sha256", "issued_at_unix", "expires_at_unix",
}
for name, audience, expected_sha256 in (
    ("registration", "latchway-physical-evidence/ios-app-attest/registration", registration_sha256),
    ("assertion", "latchway-physical-evidence/ios-app-attest/assertion", assertion_sha256),
):
    grant = grants.get(name)
    if not isinstance(grant, dict) or set(grant) != grant_fields:
        raise SystemExit("collector lease grant fields are not exact")
    if (
        grant.get("audience") != audience
        or grant.get("application_id") != application_id
        or grant.get("environment") != environment
        or grant.get("identity_provider") != identity_provider
        or grant.get("source_commit") != source_commit
        or str(grant.get("run_id")) != str(workflow.get("run_id"))
        or str(grant.get("run_attempt")) != str(workflow.get("run_attempt"))
        or grant.get("sha256") != expected_sha256
        or grant.get("single_use") is not True
    ):
        raise SystemExit("collector lease grant is not bound to this run and tenant/auth configuration")
    issued = grant.get("issued_at_unix")
    expires = grant.get("expires_at_unix")
    if (
        not isinstance(issued, int) or isinstance(issued, bool)
        or not isinstance(expires, int) or isinstance(expires, bool)
        or issued > now or expires <= issued or expires - issued > 300
    ):
        raise SystemExit("collector lease grant lifetime is invalid")
    if phase == "initial" and expires < now + 30:
        raise SystemExit("one-use grant is expired or too close to expiry for launch")
lease_issued = lease.get("issued_at_unix")
lease_expires = lease.get("expires_at_unix")
if (
    not isinstance(lease_issued, int) or isinstance(lease_issued, bool)
    or not isinstance(lease_expires, int) or isinstance(lease_expires, bool)
    or lease_issued > now or lease_expires < now + 30
    or lease_expires <= lease_issued or lease_expires - lease_issued > 3600
):
    raise SystemExit("collector lease is expired or outside its bounded lifetime")
PY
}

client_policy_path="$temporary_root/gateway-client-policy.json"
python3 - "$client_policy_path" <<'PY'
import json, os, pathlib, sys
policy = {
    "allow_debug": False,
    "allow_testing": False,
    "app_attest_environment": "production",
    "app_version": os.environ["LATCHWAY_APP_VERSION"],
    "application_identifier": os.environ["LATCHWAY_BUNDLE_ID"],
    "build_number": os.environ["LATCHWAY_BUILD_NUMBER"],
    "minimum_trust_level": os.environ["LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL"],
    "platform": "ios_app_attest",
    "provider": "app_attest",
    "require_licensed": False,
    "require_play_recognized": False,
    "require_request_hash": True,
    "signing_certificate_sha256": os.environ["LATCHWAY_SIGNING_CERTIFICATE_SHA256"],
    "team_id": os.environ["LATCHWAY_TEAM_ID"],
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(policy, allow_nan=False, ensure_ascii=False, separators=(",", ":"), sort_keys=True),
    encoding="utf-8",
)
PY
latchway_capture_gateway_deployment "$output_dir" "$client_policy_path"

raw_device_inventory="$temporary_root/devicectl-details.json"
xcrun devicectl device info details \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --timeout 30 \
  --json-output "$raw_device_inventory" \
  --omit-deprecated-fields-in-json >/dev/null

# A previous container must never be able to contribute a component claim.
xcrun devicectl device uninstall app \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --timeout 60 \
  --omit-deprecated-fields-in-json \
  "$LATCHWAY_BUNDLE_ID" >/dev/null 2>&1 || true
preinstall_inventory="$temporary_root/preinstall-apps.json"
xcrun devicectl device info apps \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --bundle-id "$LATCHWAY_BUNDLE_ID" \
  --timeout 30 \
  --json-output "$preinstall_inventory" \
  --omit-deprecated-fields-in-json >/dev/null
python3 - "$preinstall_inventory" "$LATCHWAY_BUNDLE_ID" <<'PY'
import json, pathlib, sys
def _strings(value):
    if isinstance(value, dict):
        for child in value.values():
            yield from _strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from _strings(child)
    elif isinstance(value, str):
        yield value

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if any(item == sys.argv[2] for item in _strings(value)):
    raise SystemExit("stale application data remained before the physical run")
PY

snapshot_tree_sha256="$(python3 "$repository_root/scripts/physical_app_bundle_tree.py" "$LATCHWAY_IOS_APP_BUNDLE_PATH")"
if [[ "$snapshot_tree_sha256" != "$LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256" ]]; then
  echo "private application snapshot changed before installation" >&2
  exit 1
fi

install_receipt="$temporary_root/devicectl-install.json"
xcrun devicectl device install app \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --timeout 120 \
  --json-output "$install_receipt" \
  --omit-deprecated-fields-in-json \
  "$LATCHWAY_IOS_APP_BUNDLE_PATH" >/dev/null

postinstall_inventory="$temporary_root/postinstall-apps.json"
xcrun devicectl device info apps \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --bundle-id "$LATCHWAY_BUNDLE_ID" \
  --timeout 30 \
  --json-output "$postinstall_inventory" \
  --omit-deprecated-fields-in-json >/dev/null
launch_persistent_identifier="$(python3 "$repository_root/scripts/validate-devicectl-install.py" \
  --receipt "$install_receipt" \
  --inventory "$postinstall_inventory" \
  --bundle-id "$LATCHWAY_BUNDLE_ID" \
  --version "$LATCHWAY_APP_VERSION" \
  --build "$LATCHWAY_BUILD_NUMBER" \
  --installation-name AppAttestConformance.app)"

validate_signed_lease_before_launch initial

export DEVICECTL_CHILD_LATCHWAY_CONFORMANCE_AUTORUN=1
export DEVICECTL_CHILD_LATCHWAY_RESET_INSTALLATION=1
export DEVICECTL_CHILD_LATCHWAY_BASE_URL="$LATCHWAY_BASE_URL"
export DEVICECTL_CHILD_LATCHWAY_APPLICATION_ID="$LATCHWAY_APPLICATION_ID"
export DEVICECTL_CHILD_LATCHWAY_ENVIRONMENT="$LATCHWAY_ENVIRONMENT"
export DEVICECTL_CHILD_LATCHWAY_IDENTITY_PROVIDER="$LATCHWAY_IDENTITY_PROVIDER"
export DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN="$latchway_registration_grant"
export DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN="$latchway_assertion_grant"
export DEVICECTL_CHILD_LATCHWAY_FEATURE="$LATCHWAY_FEATURE"
export DEVICECTL_CHILD_LATCHWAY_ERROR_MAPPING_FEATURE="$LATCHWAY_ERROR_MAPPING_FEATURE"
export DEVICECTL_CHILD_LATCHWAY_MODEL="$LATCHWAY_MODEL"
export DEVICECTL_CHILD_LATCHWAY_RUN_ID="$LATCHWAY_RUN_ID"
export DEVICECTL_CHILD_LATCHWAY_DISTRIBUTION="$LATCHWAY_DISTRIBUTION"
export DEVICECTL_CHILD_LATCHWAY_TEAM_ID="$LATCHWAY_TEAM_ID"
export DEVICECTL_CHILD_LATCHWAY_SIGNING_CERTIFICATE_SHA256="$LATCHWAY_SIGNING_CERTIFICATE_SHA256"
export DEVICECTL_CHILD_LATCHWAY_SOURCE_COMMIT="$LATCHWAY_SOURCE_COMMIT"
export DEVICECTL_CHILD_LATCHWAY_CORE_COMMIT="$LATCHWAY_CORE_COMMIT"
export DEVICECTL_CHILD_LATCHWAY_CONTRACT_BUNDLE_SHA256="$LATCHWAY_CONTRACT_BUNDLE_SHA256"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_IMAGE_DIGEST="$LATCHWAY_GATEWAY_IMAGE_DIGEST"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_CONFIGURATION_SHA256="$LATCHWAY_GATEWAY_CONFIGURATION_SHA256"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_ORIGIN="$LATCHWAY_GATEWAY_ORIGIN"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID="$LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256="$LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256"
export DEVICECTL_CHILD_LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256="$LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256"

xcrun devicectl device process launch \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --terminate-existing \
  --timeout 30 \
  --launch-persistent-identifier "$launch_persistent_identifier" \
  "$LATCHWAY_BUNDLE_ID" >/dev/null

# Each lease-bound grant is exposed to exactly one in-app provider during the
# first launch. Neither extension processes, the independent observer, nor the
# post-observation host relaunch inherit either raw grant.
unset DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN
unset DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN
unset DEVICECTL_CHILD_LATCHWAY_RESET_INSTALLATION
latchway_registration_grant=""
latchway_assertion_grant=""
unset latchway_registration_grant
unset latchway_assertion_grant

component_observation_path="$output_dir/component-observation.json"
"$component_observer_hook" \
  --device-id "$LATCHWAY_IOS_DEVICE_ID" \
  --host-bundle-id "$LATCHWAY_BUNDLE_ID" \
  --widget-bundle-id "$LATCHWAY_IOS_WIDGET_BUNDLE_ID" \
  --share-bundle-id "$LATCHWAY_IOS_SHARE_BUNDLE_ID" \
  --action-bundle-id "$LATCHWAY_IOS_ACTION_BUNDLE_ID" \
  --host-definition-id "$LATCHWAY_HOST_COMPONENT_DEFINITION_ID" \
  --widget-definition-id "$LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID" \
  --share-definition-id "$LATCHWAY_SHARE_COMPONENT_DEFINITION_ID" \
  --action-definition-id "$LATCHWAY_ACTION_COMPONENT_DEFINITION_ID" \
  --producer-ready-relative-path Documents/latchway-component-producer-ready.json \
  --observer-completion-relative-path Documents/latchway-component-observer-complete.json \
  --host-binary-sha256 "$LATCHWAY_APP_BINARY_SHA256" \
  --widget-binary-sha256 "$LATCHWAY_IOS_WIDGET_BINARY_SHA256" \
  --share-binary-sha256 "$LATCHWAY_IOS_SHARE_BINARY_SHA256" \
  --action-binary-sha256 "$LATCHWAY_IOS_ACTION_BINARY_SHA256" \
  --run-id "$LATCHWAY_RUN_ID" \
  --output "$component_observation_path"
if [[ ! -f "$component_observation_path" || -L "$component_observation_path" ]]; then
  echo "the independent component observer did not emit a real observation" >&2
  exit 1
fi

# The observer terminates the containing app before the delegated Action
# request, writes only
# the run-bound completion marker after its independent checks, and returns
# while the host is still stopped. Relaunching here lets the host finish the
# pre-authorized root revocation test without overlapping the Action process.
validate_signed_lease_before_launch resume
xcrun devicectl device process launch \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --terminate-existing \
  --timeout 30 \
  --launch-persistent-identifier "$launch_persistent_identifier" \
  "$LATCHWAY_BUNDLE_ID" >/dev/null

observation_path="$output_dir/app-attest-observation.json"
observation_ready=false
for _ in {1..180}; do
  candidate="$temporary_root/observation.json"
  if xcrun devicectl device copy from \
    --device "$LATCHWAY_IOS_DEVICE_ID" \
    --domain-type appDataContainer \
    --domain-identifier "$LATCHWAY_BUNDLE_ID" \
    --source Documents/latchway-device-observation.json \
    --destination "$candidate" \
    --timeout 15 >/dev/null 2>&1; then
    if python3 - "$candidate" "$LATCHWAY_RUN_ID" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
try:
    value = json.loads(path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if value.get("run", {}).get("id") == sys.argv[2] else 1)
PY
    then
      cp "$candidate" "$observation_path"
      observation_ready=true
      break
    fi
  fi
  sleep 5
done
if [[ "$observation_ready" != true ]]; then
  echo "the physical application did not produce this run's observation" >&2
  exit 1
fi

latchway_recheck_gateway_deployment "$output_dir" "$temporary_root"
latchway_verify_observation_against_gateway_policy \
  "$observation_path" "$output_dir/gateway-client-policy.json"

device_inventory_path="$output_dir/device-inventory.json"
python3 - "$raw_device_inventory" "$observation_path" "$device_inventory_path" <<'PY'
import json, pathlib, sys
raw = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
observation = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
info = raw.get("info", {})
if info.get("outcome") != "success":
    raise SystemExit("devicectl did not report a successful physical-device query")
device = observation.get("device", {})
if device.get("physical") is not True or device.get("simulator") is not False:
    raise SystemExit("application did not report a physical device")
sanitized = {
    "schema_version": "latchway.physical-device-inventory.v1",
    "collector": "devicectl",
    "collector_version": str(info.get("version", "unknown"))[:64],
    "physical": True,
    "model": device.get("model"),
    "os_name": device.get("os_name"),
    "os_version": device.get("os_version"),
    "os_build": device.get("os_build"),
}
path = pathlib.Path(sys.argv[3])
path.write_text(json.dumps(sanitized, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
device_inventory_sha256="$(shasum -a 256 "$device_inventory_path" | awk '{print $1}')"

export LATCHWAY_DEVICE_INVENTORY_SHA256="$device_inventory_sha256"
export LATCHWAY_RUNNER_OS="$(sw_vers -productName) $(sw_vers -productVersion) $(sw_vers -buildVersion)"
export LATCHWAY_RUNNER_ARCH="$(uname -m)"
export LATCHWAY_COMPILER="$(swift --version | head -n 1)"
export LATCHWAY_BUILD_TOOL="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

profile_path="$output_dir/app-attest-profile.json"
python3 - "$profile_path" <<'PY'
import json, os, pathlib, sys
expected = {
    "application_identifier": os.environ["LATCHWAY_BUNDLE_ID"],
    "latchway_application_id": os.environ["LATCHWAY_APPLICATION_ID"],
    "latchway_environment": os.environ["LATCHWAY_ENVIRONMENT"],
    "identity_provider": os.environ["LATCHWAY_IDENTITY_PROVIDER"],
    "app_version": os.environ["LATCHWAY_APP_VERSION"],
    "build_number": os.environ["LATCHWAY_BUILD_NUMBER"],
    "team_id": os.environ["LATCHWAY_TEAM_ID"],
    "signing_certificate_sha256": os.environ["LATCHWAY_SIGNING_CERTIFICATE_SHA256"],
    "app_attest_environment": "production",
    "source_commit": os.environ["LATCHWAY_SOURCE_COMMIT"],
    "core_commit": os.environ["LATCHWAY_CORE_COMMIT"],
    "contract_bundle_sha256": os.environ["LATCHWAY_CONTRACT_BUNDLE_SHA256"],
    "gateway_image_digest": os.environ["LATCHWAY_GATEWAY_IMAGE_DIGEST"],
    "gateway_configuration_sha256": os.environ["LATCHWAY_GATEWAY_CONFIGURATION_SHA256"],
    "gateway_origin": os.environ["LATCHWAY_GATEWAY_ORIGIN"],
    "gateway_environment": os.environ["LATCHWAY_ENVIRONMENT"],
    "gateway_deployment_key_id": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID"],
    "gateway_deployment_statement_sha256": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256"],
    "gateway_deployment_public_key_sha256": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256"],
    "error_mapping_feature": os.environ["LATCHWAY_ERROR_MAPPING_FEATURE"],
    "host_bundle_identifier": os.environ["LATCHWAY_BUNDLE_ID"],
    "widget_bundle_identifier": os.environ["LATCHWAY_IOS_WIDGET_BUNDLE_ID"],
    "share_bundle_identifier": os.environ["LATCHWAY_IOS_SHARE_BUNDLE_ID"],
    "action_bundle_identifier": os.environ["LATCHWAY_IOS_ACTION_BUNDLE_ID"],
    "host_definition_id": os.environ["LATCHWAY_HOST_COMPONENT_DEFINITION_ID"],
    "widget_definition_id": os.environ["LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID"],
    "share_definition_id": os.environ["LATCHWAY_SHARE_COMPONENT_DEFINITION_ID"],
    "action_definition_id": os.environ["LATCHWAY_ACTION_COMPONENT_DEFINITION_ID"],
    "host_binary_sha256": os.environ["LATCHWAY_APP_BINARY_SHA256"],
    "widget_binary_sha256": os.environ["LATCHWAY_IOS_WIDGET_BINARY_SHA256"],
    "share_binary_sha256": os.environ["LATCHWAY_IOS_SHARE_BINARY_SHA256"],
    "action_binary_sha256": os.environ["LATCHWAY_IOS_ACTION_BINARY_SHA256"],
}
profile = {
    "schema_version": "latchway.physical-device-profile.v2",
    "platform": "ios_app_attest",
    "repository": "Latchway/latchway-ios-sdk",
    "source": {
        "commit": os.environ["LATCHWAY_SOURCE_COMMIT"],
        "core_commit": os.environ["LATCHWAY_CORE_COMMIT"],
        "worktree_clean": True,
        "sdk_version": os.environ["LATCHWAY_SDK_VERSION"],
        "contract_version": os.environ["LATCHWAY_CONTRACT_VERSION"],
        "contract_bundle_sha256": os.environ["LATCHWAY_CONTRACT_BUNDLE_SHA256"],
        "gateway_image_digest": os.environ["LATCHWAY_GATEWAY_IMAGE_DIGEST"],
        "gateway_configuration_sha256": os.environ["LATCHWAY_GATEWAY_CONFIGURATION_SHA256"],
        "gateway_origin": os.environ["LATCHWAY_GATEWAY_ORIGIN"],
        "gateway_deployment_key_id": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_KEY_ID"],
        "gateway_deployment_statement_sha256": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256"],
        "gateway_deployment_public_key_sha256": os.environ["LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256"],
    },
    "toolchain": {
        "runner_os": os.environ["LATCHWAY_RUNNER_OS"],
        "runner_arch": os.environ["LATCHWAY_RUNNER_ARCH"],
        "compiler": os.environ["LATCHWAY_COMPILER"],
        "build_tool": os.environ["LATCHWAY_BUILD_TOOL"],
        "collector_version": "2",
    },
    "expected_pins": expected,
    "application_binary_sha256": os.environ["LATCHWAY_APP_BINARY_SHA256"],
    "application_bundle_tree_sha256": os.environ["LATCHWAY_IOS_APP_BUNDLE_TREE_SHA256"],
    "device_inventory_sha256": os.environ["LATCHWAY_DEVICE_INVENTORY_SHA256"],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(profile, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

evidence_path="$output_dir/app-attest-evidence.json"
junit_path="$output_dir/app-attest-junit.xml"
summary_path="$output_dir/app-attest-validation.json"
python3 "$repository_root/scripts/device-evidence.py" finalize \
  --schema "$schema_path" \
  --profile "$profile_path" \
  --observation "$observation_path" \
  --component-observation "$component_observation_path" \
  --evidence "$evidence_path" \
  --junit "$junit_path" \
  --summary "$summary_path"

(
  cd "$output_dir"
  shasum -a 256 \
    app-attest-evidence.json \
    app-attest-junit.xml \
    app-attest-observation.json \
    app-attest-profile.json \
    app-attest-validation.json \
    component-observation.json \
    gateway-client-policy.json \
    gateway-deployment-public-key.pem \
    gateway-deployment-statement.json \
    gateway-deployment-statement.sig \
    gateway-deployment-verification.json \
    device-inventory.json > SHA256SUMS
)
chmod 600 "$output_dir"/*.json "$output_dir"/*.pem "$output_dir"/*.sig "$output_dir"/*.xml "$output_dir/SHA256SUMS"
echo "physical App Attest evidence accepted: $evidence_path"
