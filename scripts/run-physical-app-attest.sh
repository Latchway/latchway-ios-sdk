#!/bin/bash
set -euo pipefail

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
  LATCHWAY_APP_VERSION
  LATCHWAY_BUILD_NUMBER
  LATCHWAY_TEAM_ID
  LATCHWAY_SIGNING_CERTIFICATE_SHA256
  LATCHWAY_APP_BINARY_SHA256
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
  LATCHWAY_IDENTITY_TOKEN
  LATCHWAY_FEATURE
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
for tool in cmp curl install openssl; do
  command -v "$tool" >/dev/null || { echo "required tool is unavailable: $tool" >&2; exit 2; }
done

[[ "$LATCHWAY_IOS_INSTALL_MODE" == install ]] || {
  echo "physical evidence requires installing the pinned app bundle" >&2
  exit 2
}
case "$LATCHWAY_DISTRIBUTION" in
  ad_hoc|testflight|app_store) ;;
  *) echo "LATCHWAY_DISTRIBUTION is not release eligible" >&2; exit 2 ;;
esac
[[ "$LATCHWAY_BASE_URL" == "$LATCHWAY_GATEWAY_ORIGIN" ]] || {
  echo "application base URL must exactly match the signed gateway origin" >&2
  exit 2
}
[[ "$LATCHWAY_GATEWAY_DEPLOYMENT_STATEMENT_SHA256" =~ ^[0-9a-f]{64}$ && "$LATCHWAY_GATEWAY_DEPLOYMENT_PUBLIC_KEY_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "invalid gateway deployment hash pin" >&2
  exit 2
}
case "$LATCHWAY_GATEWAY_MINIMUM_TRUST_LEVEL" in
  device_verified|strong_device_verified) ;;
  *) echo "invalid gateway minimum trust level" >&2; exit 2 ;;
esac

if [[ ! -d "$LATCHWAY_IOS_APP_BUNDLE_PATH" || -L "$LATCHWAY_IOS_APP_BUNDLE_PATH" ]]; then
  echo "LATCHWAY_IOS_APP_BUNDLE_PATH must be a real .app directory" >&2
  exit 2
fi
if [[ "$LATCHWAY_IOS_APP_BUNDLE_PATH" != *.app ]]; then
  echo "LATCHWAY_IOS_APP_BUNDLE_PATH must end in .app" >&2
  exit 2
fi

mkdir -p "$LATCHWAY_EVIDENCE_OUTPUT_DIR"
output_dir="$(cd "$LATCHWAY_EVIDENCE_OUTPUT_DIR" && pwd -P)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/latchway-app-attest.XXXXXX")"
cleanup() {
  if [[ -n "$temporary_root" && -d "$temporary_root" && "$temporary_root" == */latchway-app-attest.* ]]; then
    rm -rf "$temporary_root"
  fi
  unset DEVICECTL_CHILD_LATCHWAY_IDENTITY_TOKEN
}
trap cleanup EXIT

actual_commit="$(git -C "$repository_root" rev-parse HEAD)"
if [[ "$actual_commit" != "$LATCHWAY_SOURCE_COMMIT" ]]; then
  echo "source commit does not match the protected run input" >&2
  exit 1
fi
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
if [[ "$actual_bundle_id" != "$LATCHWAY_BUNDLE_ID" || "$actual_version" != "$LATCHWAY_APP_VERSION" || "$actual_build" != "$LATCHWAY_BUILD_NUMBER" ]]; then
  echo "signed application identity does not match protected pins" >&2
  exit 1
fi
if [[ ! -f "$LATCHWAY_IOS_APP_BUNDLE_PATH/$actual_executable" || -L "$LATCHWAY_IOS_APP_BUNDLE_PATH/$actual_executable" ]]; then
  echo "signed application executable is missing or unsafe" >&2
  exit 1
fi

codesign --verify --deep --strict "$LATCHWAY_IOS_APP_BUNDLE_PATH"
entitlements_path="$temporary_root/entitlements.plist"
codesign -d --entitlements :- "$LATCHWAY_IOS_APP_BUNDLE_PATH" >"$entitlements_path" 2>/dev/null
actual_team_id="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$entitlements_path")"
actual_app_attest_environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.devicecheck.appattest-environment' "$entitlements_path")"
actual_application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$entitlements_path")"
actual_get_task_allow="$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' "$entitlements_path" 2>/dev/null || true)"
if [[ "$actual_team_id" != "$LATCHWAY_TEAM_ID" || "$actual_application_identifier" != "$LATCHWAY_TEAM_ID.$LATCHWAY_BUNDLE_ID" ]]; then
  echo "signed Apple team/application identifier does not match protected pins" >&2
  exit 1
fi
if [[ "$actual_app_attest_environment" != production ]]; then
  echo "release evidence requires the production App Attest entitlement" >&2
  exit 1
fi
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

xcrun devicectl device install app \
  --device "$LATCHWAY_IOS_DEVICE_ID" \
  --timeout 120 \
  "$LATCHWAY_IOS_APP_BUNDLE_PATH" >/dev/null

export DEVICECTL_CHILD_LATCHWAY_CONFORMANCE_AUTORUN=1
export DEVICECTL_CHILD_LATCHWAY_RESET_INSTALLATION=1
export DEVICECTL_CHILD_LATCHWAY_BASE_URL="$LATCHWAY_BASE_URL"
export DEVICECTL_CHILD_LATCHWAY_APPLICATION_ID="$LATCHWAY_APPLICATION_ID"
export DEVICECTL_CHILD_LATCHWAY_ENVIRONMENT="$LATCHWAY_ENVIRONMENT"
export DEVICECTL_CHILD_LATCHWAY_IDENTITY_PROVIDER="$LATCHWAY_IDENTITY_PROVIDER"
export DEVICECTL_CHILD_LATCHWAY_IDENTITY_TOKEN="$LATCHWAY_IDENTITY_TOKEN"
export DEVICECTL_CHILD_LATCHWAY_FEATURE="$LATCHWAY_FEATURE"
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
}
profile = {
    "schema_version": "latchway.physical-device-profile.v1",
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
        "collector_version": "1",
    },
    "expected_pins": expected,
    "application_binary_sha256": os.environ["LATCHWAY_APP_BINARY_SHA256"],
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
    gateway-client-policy.json \
    gateway-deployment-public-key.pem \
    gateway-deployment-statement.json \
    gateway-deployment-statement.sig \
    gateway-deployment-verification.json \
    device-inventory.json > SHA256SUMS
)
chmod 600 "$output_dir"/*.json "$output_dir"/*.pem "$output_dir"/*.sig "$output_dir"/*.xml "$output_dir/SHA256SUMS"
echo "physical App Attest evidence accepted: $evidence_path"
