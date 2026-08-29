#!/bin/sh
set -eu

if [ "$#" -ne 1 ] || ! printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "usage: $0 MAJOR.MINOR.PATCH" >&2
  exit 64
fi

version=$1
attempts=${LATCHWAY_COCOAPODS_VERIFY_ATTEMPTS:-90}
delay=${LATCHWAY_COCOAPODS_VERIFY_DELAY_SECONDS:-20}
case "$attempts:$delay" in
  *[!0-9:]*|:*|*:) echo "CocoaPods verification retry settings are invalid" >&2; exit 64 ;;
esac
if [ "$attempts" -lt 1 ] || [ "$attempts" -gt 180 ] || [ "$delay" -lt 1 ] || [ "$delay" -gt 60 ]; then
  echo "CocoaPods verification retry settings are invalid" >&2
  exit 64
fi

shard=$(ruby -rdigest -e 'digest = Digest::MD5.hexdigest(ARGV.fetch(0)); print digest[0], "/", digest[1], "/", digest[2]' Latchway)
url="https://cdn.cocoapods.org/Specs/$shard/Latchway/$version/Latchway.podspec.json"
temporary_spec=$(mktemp "${TMPDIR:-/tmp}/latchway-cocoapods-spec.XXXXXX")
temporary_local_spec=$(mktemp "${TMPDIR:-/tmp}/latchway-cocoapods-local-spec.XXXXXX")
temporary_archive_root=$(mktemp -d "${TMPDIR:-/tmp}/latchway-cocoapods-archive.XXXXXX")
trap 'rm -f "$temporary_spec" "$temporary_local_spec"; rm -rf "$temporary_archive_root"' EXIT HUP INT TERM

available=false
attempt=1
while [ "$attempt" -le "$attempts" ]; do
  if curl --fail --silent --show-error --location --output "$temporary_spec" "$url"; then
    available=true
    break
  fi
  if [ "$attempt" -lt "$attempts" ]; then
    sleep "$delay"
  fi
  attempt=$((attempt + 1))
done
if [ "$available" != true ]; then
  echo "CocoaPods CDN did not expose Latchway $version within the verification window" >&2
  exit 1
fi

ruby -rjson -e '
  spec = JSON.parse(File.read(ARGV.fetch(0)))
  version = ARGV.fetch(1)
  abort "published CocoaPods name mismatch" unless spec["name"] == "Latchway"
  abort "published CocoaPods version mismatch" unless spec["version"] == version
  source = spec.fetch("source")
  abort "published CocoaPods source mismatch" unless source["git"] == "https://github.com/Latchway/latchway-ios-sdk.git"
  abort "published CocoaPods tag mismatch" unless source["tag"] == "v#{version}"
  names = spec.fetch("subspecs").map { |entry| entry.fetch("name") }.sort
  abort "published CocoaPods subspec mismatch" unless names == %w[AppAttest Core FirebaseAuth]
' "$temporary_spec" "$version"

expected_archive=${LATCHWAY_COCOAPODS_EXPECTED_ARCHIVE:-}
archive_sha256=
specs_byte_equivalent=false
if [ -n "$expected_archive" ]; then
  if [ ! -f "$expected_archive" ] || [ "$(basename "$expected_archive")" != "latchway-ios-sdk-$version.tar.gz" ]; then
    echo "The reviewed CocoaPods source archive is missing or misnamed" >&2
    exit 64
  fi
  "$(dirname "$0")/build-release-archive.sh" "v$version" "$temporary_archive_root" >/dev/null
  cmp "$expected_archive" "$temporary_archive_root/latchway-ios-sdk-$version.tar.gz" || {
    echo "The reviewed CocoaPods source archive differs from the exact release tag" >&2
    exit 1
  }
  archive_sha256=$(shasum -a 256 "$expected_archive" | awk '{print $1}')
  pod ipc spec Latchway.podspec > "$temporary_local_spec"
  ruby -rjson -e '
    published = JSON.parse(File.read(ARGV.fetch(0)))
    local = JSON.parse(File.read(ARGV.fetch(1)))
    abort "published CocoaPods specification differs from the reviewed podspec" unless published == local
  ' "$temporary_spec" "$temporary_local_spec"
  specs_byte_equivalent=true
fi

published_spec_sha256=$(shasum -a 256 "$temporary_spec" | awk '{print $1}')
ruby -rjson -e '
  spec = JSON.parse(File.read(ARGV.fetch(0)))
  puts JSON.pretty_generate({
    schema_version: 1,
    registry: "cocoapods",
    package: "Latchway",
    version: ARGV.fetch(1),
    published_spec_sha256: ARGV.fetch(2),
    reviewed_source_archive_sha256: ARGV.fetch(3),
    published_spec_equals_reviewed_podspec: ARGV.fetch(4) == "true",
    reviewed_source_archive_equals_release_tag: !ARGV.fetch(3).empty?,
    source: spec.fetch("source"),
  })
' "$temporary_spec" "$version" "$published_spec_sha256" "$archive_sha256" "$specs_byte_equivalent"
