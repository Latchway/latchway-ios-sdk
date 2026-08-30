#!/bin/bash
set -Eeuo pipefail

# Produces a signed, side-loadable Release candidate only from signing assets
# that already exist in the caller's Apple/Xcode environment. It never imports,
# creates, downloads, or mutates certificates and provisioning profiles.

if [[ "$#" != 1 ]]; then
  echo "usage: $0 OUTPUT_DIRECTORY" >&2
  exit 64
fi

repository_root="$(cd "$(dirname "$0")/.." && pwd -P)"
output_parent="$1"
if [[ "$output_parent" == *$'\n'* || "$output_parent" == *$'\r'* || ! -d "$output_parent" || -L "$output_parent" ]]; then
  echo "output directory must be an existing real directory" >&2
  exit 64
fi
output_parent="$(cd "$output_parent" && pwd -P)"
case "$output_parent/" in
  "$repository_root/"|"$repository_root/"*)
    echo "candidate output must be staged outside the source checkout" >&2
    exit 64
    ;;
esac

required_variables=(
  LATCHWAY_SOURCE_COMMIT
  LATCHWAY_XCODE_IDENTITY
  LATCHWAY_IOS_TEAM_ID
  LATCHWAY_IOS_APP_ID_PREFIX
  LATCHWAY_IOS_CODE_SIGN_IDENTITY
  LATCHWAY_IOS_EXPECTED_SIGNING_CERTIFICATE_SHA256
  LATCHWAY_IOS_BUNDLE_ID
  LATCHWAY_IOS_WIDGET_BUNDLE_ID
  LATCHWAY_IOS_SHARE_BUNDLE_ID
  LATCHWAY_IOS_ACTION_BUNDLE_ID
  LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_SPECIFIER
  LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER
  LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_SPECIFIER
  LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_SPECIFIER
  LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_UUID
  LATCHWAY_IOS_APP_VERSION
  LATCHWAY_IOS_BUILD_NUMBER
  LATCHWAY_IOS_DISTRIBUTION
  LATCHWAY_GATEWAY_ORIGIN
  LATCHWAY_APPLICATION_ID
  LATCHWAY_ENVIRONMENT
  LATCHWAY_IDENTITY_PROVIDER
  LATCHWAY_HOST_COMPONENT_DEFINITION_ID
  LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID
  LATCHWAY_SHARE_COMPONENT_DEFINITION_ID
  LATCHWAY_ACTION_COMPONENT_DEFINITION_ID
  LATCHWAY_WIDGET_FEATURE
  LATCHWAY_SHARE_FEATURE
  LATCHWAY_ACTION_FEATURE
)
for variable_name in "${required_variables[@]}"; do
  if [[ -z "${!variable_name:-}" || "${!variable_name}" == *$'\n'* || "${!variable_name}" == *$'\r'* ]]; then
    echo "required safe environment variable is missing: $variable_name" >&2
    exit 2
  fi
done

for forbidden in \
  LATCHWAY_IDENTITY_TOKEN \
  LATCHWAY_REGISTRATION_IDENTITY_TOKEN \
  LATCHWAY_ASSERTION_IDENTITY_TOKEN \
  LATCHWAY_ONE_TIME_DEVICE_GRANT \
  LATCHWAY_REGISTRATION_DEVICE_GRANT \
  LATCHWAY_ASSERTION_DEVICE_GRANT \
  DEVICECTL_CHILD_LATCHWAY_IDENTITY_TOKEN \
  DEVICECTL_CHILD_LATCHWAY_REGISTRATION_IDENTITY_TOKEN \
  DEVICECTL_CHILD_LATCHWAY_ASSERTION_IDENTITY_TOKEN \
  DEVICECTL_CHILD_LATCHWAY_ONE_TIME_DEVICE_GRANT \
  DEVICECTL_CHILD_LATCHWAY_REGISTRATION_DEVICE_GRANT \
  DEVICECTL_CHILD_LATCHWAY_ASSERTION_DEVICE_GRANT; do
  if [[ -n "${!forbidden:-}" ]]; then
    echo "runtime identity/device grants are forbidden in the candidate build environment" >&2
    exit 2
  fi
done
while IFS= read -r environment_name; do
  case "$environment_name" in
    *APP_ATTEST*VERIFICATION*RESOURCE*|*APP_ATTEST*PRIVATE*KEY*)
      if [[ -n "${!environment_name:-}" ]]; then
        echo "App Attest server verification secrets are forbidden in the candidate build environment" >&2
        exit 2
      fi
      ;;
  esac
done < <(compgen -e)

for tool in codesign ditto openssl python3 security shasum tuist xcodebuild; do
  command -v "$tool" >/dev/null || { echo "required tool is unavailable: $tool" >&2; exit 2; }
done
[[ "$LATCHWAY_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  echo "LATCHWAY_SOURCE_COMMIT must be a full Git commit" >&2
  exit 2
}
[[ "$LATCHWAY_IOS_EXPECTED_SIGNING_CERTIFICATE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "expected signing-certificate SHA-256 is invalid" >&2
  exit 2
}
[[ "$LATCHWAY_IOS_DISTRIBUTION" == ad_hoc ]] || {
  echo "the installable physical candidate producer supports ad_hoc distribution only" >&2
  exit 2
}
[[ "$LATCHWAY_GATEWAY_ORIGIN" =~ ^https:// ]] || {
  echo "the embedded gateway origin must use HTTPS" >&2
  exit 2
}

actual_commit="$(git -C "$repository_root" rev-parse HEAD)"
actual_tree="$(git -C "$repository_root" rev-parse 'HEAD^{tree}')"
if [[ "$actual_commit" != "$LATCHWAY_SOURCE_COMMIT" ]]; then
  echo "source checkout does not match LATCHWAY_SOURCE_COMMIT" >&2
  exit 1
fi
if [[ -n "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "signed candidate production requires a clean source worktree" >&2
  exit 1
fi
actual_xcode_identity="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [[ "$actual_xcode_identity" != "$LATCHWAY_XCODE_IDENTITY" ]]; then
  echo "Xcode identity does not match the external build pin" >&2
  exit 1
fi
if [[ "$(tuist version)" != 4.200.4 ]]; then
  echo "the candidate producer requires pinned Tuist 4.200.4" >&2
  exit 1
fi

candidate_name="latchway-ios-app-attest-${LATCHWAY_SOURCE_COMMIT}"
candidate_root="$output_parent/$candidate_name"
if [[ -e "$candidate_root" || -L "$candidate_root" ]]; then
  echo "candidate output already exists: $candidate_root" >&2
  exit 1
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/latchway-ios-candidate.XXXXXX")"
output_staging=""
published_candidate=""
cleanup() {
  if [[ -n "${temporary_root:-}" && -d "$temporary_root" && "$temporary_root" == */latchway-ios-candidate.* ]]; then
    rm -rf "$temporary_root"
  fi
  if [[ -n "${output_staging:-}" && -d "$output_staging" && "$output_staging" == "$output_parent"/.latchway-ios-candidate-staging.* ]]; then
    rm -rf "$output_staging"
  fi
  if [[ -n "${published_candidate:-}" \
     && "$published_candidate" == "$candidate_root" \
     && -d "$published_candidate" \
     && ! -L "$published_candidate" ]]; then
    rm -rf "$published_candidate"
  fi
}
trap cleanup EXIT
umask 077

export TUIST_LATCHWAY_CONFORMANCE_BUNDLE_ID="$LATCHWAY_IOS_BUNDLE_ID"
export TUIST_LATCHWAY_CONFORMANCE_WIDGET_BUNDLE_ID="$LATCHWAY_IOS_WIDGET_BUNDLE_ID"
export TUIST_LATCHWAY_CONFORMANCE_SHARE_BUNDLE_ID="$LATCHWAY_IOS_SHARE_BUNDLE_ID"
export TUIST_LATCHWAY_CONFORMANCE_ACTION_BUNDLE_ID="$LATCHWAY_IOS_ACTION_BUNDLE_ID"
export TUIST_LATCHWAY_DEVELOPMENT_TEAM="$LATCHWAY_IOS_TEAM_ID"
export TUIST_LATCHWAY_APP_ATTEST_ENVIRONMENT=production
export TUIST_LATCHWAY_CONFORMANCE_VERSION="$LATCHWAY_IOS_APP_VERSION"
export TUIST_LATCHWAY_CONFORMANCE_BUILD="$LATCHWAY_IOS_BUILD_NUMBER"
export TUIST_LATCHWAY_GATEWAY_URL="$LATCHWAY_GATEWAY_ORIGIN"
export TUIST_LATCHWAY_APPLICATION_ID="$LATCHWAY_APPLICATION_ID"
export TUIST_LATCHWAY_ENVIRONMENT="$LATCHWAY_ENVIRONMENT"
export TUIST_LATCHWAY_IDENTITY_PROVIDER="$LATCHWAY_IDENTITY_PROVIDER"
export TUIST_LATCHWAY_HOST_COMPONENT_DEFINITION_ID="$LATCHWAY_HOST_COMPONENT_DEFINITION_ID"
export TUIST_LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID="$LATCHWAY_WIDGET_COMPONENT_DEFINITION_ID"
export TUIST_LATCHWAY_SHARE_COMPONENT_DEFINITION_ID="$LATCHWAY_SHARE_COMPONENT_DEFINITION_ID"
export TUIST_LATCHWAY_ACTION_COMPONENT_DEFINITION_ID="$LATCHWAY_ACTION_COMPONENT_DEFINITION_ID"
export TUIST_LATCHWAY_WIDGET_FEATURE="$LATCHWAY_WIDGET_FEATURE"
export TUIST_LATCHWAY_SHARE_FEATURE="$LATCHWAY_SHARE_FEATURE"
export TUIST_LATCHWAY_ACTION_FEATURE="$LATCHWAY_ACTION_FEATURE"
export TUIST_LATCHWAY_WIDGET_KEYCHAIN_GROUP_SUFFIX="$LATCHWAY_IOS_WIDGET_BUNDLE_ID"
export TUIST_LATCHWAY_SHARE_KEYCHAIN_GROUP_SUFFIX="$LATCHWAY_IOS_SHARE_BUNDLE_ID"
export TUIST_LATCHWAY_ACTION_KEYCHAIN_GROUP_SUFFIX="$LATCHWAY_IOS_ACTION_BUNDLE_ID"
export TUIST_LATCHWAY_CODE_SIGN_STYLE=Manual
export TUIST_LATCHWAY_HOST_PROVISIONING_PROFILE_SPECIFIER="$LATCHWAY_IOS_HOST_PROVISIONING_PROFILE_SPECIFIER"
export TUIST_LATCHWAY_WIDGET_PROVISIONING_PROFILE_SPECIFIER="$LATCHWAY_IOS_WIDGET_PROVISIONING_PROFILE_SPECIFIER"
export TUIST_LATCHWAY_SHARE_PROVISIONING_PROFILE_SPECIFIER="$LATCHWAY_IOS_SHARE_PROVISIONING_PROFILE_SPECIFIER"
export TUIST_LATCHWAY_ACTION_PROVISIONING_PROFILE_SPECIFIER="$LATCHWAY_IOS_ACTION_PROVISIONING_PROFILE_SPECIFIER"

tuist generate --path "$repository_root/Examples/AppAttestConformance" --no-open
xcodebuild -quiet \
  -project "$repository_root/Examples/AppAttestConformance/AppAttestConformance.xcodeproj" \
  -scheme AppAttestConformance \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$temporary_root/DerivedData" \
  -archivePath "$temporary_root/AppAttestConformance.xcarchive" \
  CODE_SIGN_IDENTITY="$LATCHWAY_IOS_CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$LATCHWAY_IOS_TEAM_ID" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  archive

archived_app="$temporary_root/AppAttestConformance.xcarchive/Products/Applications/AppAttestConformance.app"
if [[ ! -d "$archived_app" || -L "$archived_app" ]]; then
  echo "Xcode archive did not contain the expected signed application" >&2
  exit 1
fi
output_staging="$(mktemp -d "$output_parent/.latchway-ios-candidate-staging.XXXXXX")"
staging="$output_staging"
ditto "$archived_app" "$staging/AppAttestConformance.app"

export LATCHWAY_SOURCE_TREE="$actual_tree"
export LATCHWAY_IOS_STAGED_APP_PATH="$candidate_root/AppAttestConformance.app"
python3 "$repository_root/scripts/inspect-physical-app-attest-candidate.py" \
  "$staging/AppAttestConformance.app" \
  "$staging/latchway-ios-app-attest-candidate.json"
(
  cd "$staging"
  shasum -a 256 latchway-ios-app-attest-candidate.json > SHA256SUMS
)

if [[ "$(git -C "$repository_root" rev-parse HEAD)" != "$actual_commit" \
   || "$(git -C "$repository_root" rev-parse 'HEAD^{tree}')" != "$actual_tree" \
   || -n "$(git -C "$repository_root" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "source checkout changed while the signed candidate was being produced" >&2
  exit 1
fi
manifest_tree_sha256="$(python3 - "$staging/latchway-ios-app-attest-candidate.json" <<'PY'
import json
import pathlib
import re
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
digest = value.get("app_bundle_tree", {}).get("tree_sha256", "")
if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("candidate manifest has no valid application bundle-tree hash")
print(digest)
PY
)"
staged_tree_sha256="$(
  python3 "$repository_root/scripts/physical_app_bundle_tree.py" \
    "$staging/AppAttestConformance.app"
)"
if [[ "$staged_tree_sha256" != "$manifest_tree_sha256" ]]; then
  echo "staged application changed after candidate inspection" >&2
  exit 1
fi
if [[ -e "$candidate_root" || -L "$candidate_root" ]]; then
  echo "candidate output appeared while the build was running: $candidate_root" >&2
  exit 1
fi
mv "$staging" "$candidate_root"
output_staging=""
published_candidate="$candidate_root"
final_tree_sha256="$(
  python3 "$repository_root/scripts/physical_app_bundle_tree.py" \
    "$candidate_root/AppAttestConformance.app"
)"
if [[ "$final_tree_sha256" != "$manifest_tree_sha256" ]]; then
  echo "published application changed during candidate handoff" >&2
  exit 1
fi
published_candidate=""
echo "Staged verified physical App Attest candidate at $candidate_root"
echo "Protected input metadata: $candidate_root/latchway-ios-app-attest-candidate.json"
