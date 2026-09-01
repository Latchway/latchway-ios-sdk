#!/bin/sh
set -eu
umask 077

core_dir=${LATCHWAY_CORE_DIR:-_core}
evidence_dir=${LATCHWAY_EVIDENCE_DIR:?LATCHWAY_EVIDENCE_DIR is required}
postgres_bin=${LATCHWAY_POSTGRES_BIN:?LATCHWAY_POSTGRES_BIN is required}
postgres_port=${LATCHWAY_POSTGRES_PORT:-55432}
develop_port=${LATCHWAY_DEVELOP_PORT:-18080}

case "$postgres_port$develop_port" in *[!0-9]*) echo 'conformance ports must be decimal integers' >&2; exit 64 ;; esac
test "$postgres_port" -ge 1 && test "$postgres_port" -le 65535
test "$develop_port" -ge 1 && test "$develop_port" -le 65535

core_commit=$(awk '$1 == "core_commit:" {print $2}' contract.lock)
contract_version=$(awk '$1 == "contract_version:" {print $2}' contract.lock)
bundle_sha256=$(awk '$1 == "bundle_sha256:" {gsub(/"/, "", $2); print $2}' contract.lock)
test "$(wc -l < contract.lock | tr -d ' ')" = 7
test "${#core_commit}" = 40
test "${#bundle_sha256}" = 64
case "$core_commit$bundle_sha256" in *[!0-9a-f]*) echo 'contract.lock contains a non-canonical digest' >&2; exit 1 ;; esac
test "$(git -C "$core_dir" rev-parse --verify HEAD)" = "$core_commit"
test -z "$(git -C "$core_dir" status --porcelain=v1 --untracked-files=all)"

mkdir -p "$evidence_dir"
build_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/latchway-ios-live-build.XXXXXX")
postgres_dir=$(mktemp -d "${RUNNER_TEMP:-/tmp}/latchway-ios-live-postgres.XXXXXX")
ready_file=$(mktemp "${RUNNER_TEMP:-/tmp}/latchway-ios-live-ready.XXXXXX")
develop_log=$(mktemp "${RUNNER_TEMP:-/tmp}/latchway-ios-live-core-log.XXXXXX")
develop_pid=
postgres_started=false
cleanup() {
  if [ -n "$develop_pid" ] && kill -0 "$develop_pid" 2>/dev/null; then
    kill "$develop_pid" >/dev/null 2>&1 || true
    wait "$develop_pid" 2>/dev/null || true
  fi
  if [ "$postgres_started" = true ]; then
    "$postgres_bin/pg_ctl" -D "$postgres_dir/data" -m fast -w stop >/dev/null 2>&1 || true
  fi
  rm -rf "$build_dir" "$postgres_dir"
  rm -f "$ready_file" "$develop_log"
}
trap cleanup EXIT HUP INT TERM

"$postgres_bin/initdb" --username=latchway --auth-local=trust --auth-host=trust \
  --encoding=UTF8 --locale=C --pgdata="$postgres_dir/data" >/dev/null
"$postgres_bin/pg_ctl" -D "$postgres_dir/data" \
  -o "-h 127.0.0.1 -p $postgres_port" -w start >/dev/null
postgres_started=true
"$postgres_bin/createdb" --host=127.0.0.1 --port="$postgres_port" --username=latchway latchway
database_url="postgres://latchway@127.0.0.1:$postgres_port/latchway?sslmode=disable"
postgres_version=$("$postgres_bin/postgres" --version)

core_binary="$build_dir/latchway"
(
  cd "$core_dir"
  go build -trimpath \
    -ldflags "-s -w -X github.com/latchway/latchway/internal/buildinfo.Version=$contract_version-pr -X github.com/latchway/latchway/internal/buildinfo.Commit=$core_commit -X github.com/latchway/latchway/internal/buildinfo.Date=1970-01-01T00:00:00Z" \
    -o "$core_binary" ./cmd/latchway
)
"$core_binary" --output json version > "$evidence_dir/core-version.json"
jq --exit-status --arg commit "$core_commit" --arg contract "$contract_version" '
  .commit == $commit and .contract_version == $contract and .protocol_version == "2"
' "$evidence_dir/core-version.json" >/dev/null
core_binary_sha256=$(shasum -a 256 "$core_binary" | awk '{print $1}')

LATCHWAY_CONFORMANCE_DATABASE_URL=$database_url \
  "$core_binary" --output json develop \
  --database-url-env LATCHWAY_CONFORMANCE_DATABASE_URL \
  --listen "127.0.0.1:$develop_port" --browser-origin http://localhost:5173 \
  > "$ready_file" 2> "$develop_log" &
develop_pid=$!
attempt=0
until jq --exit-status --arg gateway "http://127.0.0.1:$develop_port" '
  .state == "ready" and .gateway_url == $gateway and
  (.application_id | type == "string") and .environment == "development" and
  (.feature | type == "string") and (.model | type == "string") and
  (.identity_token_url | type == "string") and (.attestation_evidence_url | type == "string")
' "$ready_file" >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if ! kill -0 "$develop_pid" 2>/dev/null || [ "$attempt" -ge 90 ]; then
    echo 'the exact native core development server did not become ready' >&2
    exit 1
  fi
  sleep 1
done

LATCHWAY_DEVELOP_BASE_URL=$(jq --raw-output .gateway_url "$ready_file")
LATCHWAY_DEVELOP_APPLICATION_ID=$(jq --raw-output .application_id "$ready_file")
LATCHWAY_DEVELOP_ENVIRONMENT=$(jq --raw-output .environment "$ready_file")
LATCHWAY_DEVELOP_FEATURE=$(jq --raw-output .feature "$ready_file")
LATCHWAY_DEVELOP_MODEL=$(jq --raw-output .model "$ready_file")
LATCHWAY_DEVELOP_IDENTITY_TOKEN_URL=$(jq --raw-output .identity_token_url "$ready_file")
LATCHWAY_DEVELOP_ATTESTATION_EVIDENCE_URL=$(jq --raw-output .attestation_evidence_url "$ready_file")
LATCHWAY_SDK_CONFORMANCE_OUTPUT="$evidence_dir/sdk-live-conformance.json"
export LATCHWAY_DEVELOP_BASE_URL LATCHWAY_DEVELOP_APPLICATION_ID LATCHWAY_DEVELOP_ENVIRONMENT
export LATCHWAY_DEVELOP_FEATURE LATCHWAY_DEVELOP_MODEL LATCHWAY_DEVELOP_IDENTITY_TOKEN_URL
export LATCHWAY_DEVELOP_ATTESTATION_EVIDENCE_URL LATCHWAY_SDK_CONFORMANCE_OUTPUT
LATCHWAY_IOS_LIVE_CONFORMANCE=1 \
  swift test --filter LiveCoreConformanceTests/testSDKIssuesOneDebugAttestedProxiedRequest

jq --exit-status '
  .schema_version == 1 and .kind == "latchway_sdk_live_debug_conformance" and
  .sdk_kind == "ios" and .status == "passed" and
  .physical_attestation_claimed == false and
  (.checks.debug_attestation == true) and (.checks.dpop_session == true) and
  (.checks.proxied_mock_request == true) and (.checks.quota == true) and
  (.checks.session_refresh == true)
' "$LATCHWAY_SDK_CONFORMANCE_OUTPUT" >/dev/null

kill "$develop_pid"
wait "$develop_pid"
develop_pid=

sdk_commit=$(git rev-parse --verify HEAD)
jq --null-input \
  --arg sdk_commit "$sdk_commit" \
  --arg core_commit "$core_commit" \
  --arg contract_version "$contract_version" \
  --arg bundle_sha256 "$bundle_sha256" \
  --arg core_binary_sha256 "$core_binary_sha256" \
  --arg postgres_version "$postgres_version" '
  {
    schema_version: 1,
    kind: "latchway_ios_pr_native_live_conformance",
    sdk: {kind: "ios", commit: $sdk_commit},
    contract: {version: $contract_version, core_commit: $core_commit, bundle_sha256: $bundle_sha256},
    runtime: {
      core_runtime_kind: "native_macos_source_build",
      core_binary_sha256: $core_binary_sha256,
      core_image_claimed: false,
      postgres_runtime_kind: "native_macos_loopback",
      postgres_version: $postgres_version,
      sdk_runtime_request_claimed: true,
      debug_attestation_claimed: true,
      physical_attestation_claimed: false,
      companion_exact_image_job: "pinned-core-conformance"
    }
  }
' > "$evidence_dir/identity.json"
