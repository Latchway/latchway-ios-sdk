#!/bin/bash
set -euo pipefail
set +x
umask 077

if [[ $# -ne 1 || ! "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "usage: $0 MAJOR.MINOR.PATCH" >&2
  exit 64
fi

version=$1
script_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd "$script_directory/.." && pwd)
shard=$(ruby -rdigest -e 'digest = Digest::MD5.hexdigest(ARGV.fetch(0)); print digest[0], "/", digest[1], "/", digest[2]' Latchway)
url="https://cdn.cocoapods.org/Specs/$shard/Latchway/$version/Latchway.podspec.json"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/latchway-cocoapods-publish.XXXXXX")
cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT HUP INT TERM

local_spec="$temporary_root/local.json"
remote_spec="$temporary_root/remote.json"
(cd "$repository_root" && pod ipc spec Latchway.podspec) >"$local_spec"

fetch_spec() {
  local output=$1
  local status
  if ! status=$(curl \
    --proto '=https' \
    --proto-redir '=https' \
    --tlsv1.2 \
    --connect-timeout 15 \
    --max-time 60 \
    --max-filesize 1048576 \
    --silent \
    --show-error \
    --location \
    --output "$output" \
    --write-out '%{http_code}' \
    "$url"); then
    echo "Could not prove CocoaPods registry state" >&2
    return 1
  fi
  printf '%s' "$status"
}

verify_exact_spec() {
  ruby -rjson -e '
    local = JSON.parse(File.read(ARGV.fetch(0)))
    remote = JSON.parse(File.read(ARGV.fetch(1)))
    abort "published CocoaPods spec is not exactly the reviewed local podspec" unless remote == local
  ' "$local_spec" "$remote_spec"
}

status=$(fetch_spec "$remote_spec")
case "$status" in
  200)
    verify_exact_spec
    echo "Latchway $version already exists on CocoaPods with the exact reviewed specification"
    exit 0
    ;;
  404) ;;
  *)
    echo "Could not prove CocoaPods version availability (HTTP $status)" >&2
    exit 1
    ;;
esac

if [[ -z "${COCOAPODS_TRUNK_TOKEN:-}" ]]; then
  echo "Set COCOAPODS_TRUNK_TOKEN when the exact CocoaPods version is absent" >&2
  exit 1
fi
(cd "$repository_root" && pod trunk push Latchway.podspec --synchronous)

attempts=${LATCHWAY_COCOAPODS_VERIFY_ATTEMPTS:-90}
delay=${LATCHWAY_COCOAPODS_VERIFY_DELAY_SECONDS:-20}
if [[ ! "$attempts" =~ ^[0-9]+$ || "$attempts" -lt 1 || "$attempts" -gt 180 ||
      ! "$delay" =~ ^[0-9]+$ || "$delay" -lt 1 || "$delay" -gt 60 ]]; then
  echo "CocoaPods verification retry settings are invalid" >&2
  exit 64
fi

for ((attempt = 1; attempt <= attempts; attempt++)); do
  status=$(fetch_spec "$remote_spec")
  if [[ "$status" == 200 ]]; then
    verify_exact_spec
    echo "Published and verified exact Latchway $version CocoaPods specification"
    exit 0
  fi
  if [[ "$status" != 404 ]]; then
    echo "Could not verify CocoaPods publication (HTTP $status)" >&2
    exit 1
  fi
  if (( attempt < attempts )); then
    sleep "$delay"
  fi
done

echo "CocoaPods CDN did not expose Latchway $version within the verification window" >&2
exit 1
