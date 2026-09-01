#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/latchway-ios-package-verification.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM
module_cache="$temporary_root/swift-module-cache"
clang_cache="$temporary_root/clang-module-cache"

mkdir -p "$module_cache" "$clang_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"
export CLANG_MODULE_CACHE_PATH="$clang_cache"

cd "$repository_root"
python3 scripts/run-offline-release-tests.py
python3 scripts/test-dependency-vulnerability-scan.py
python3 scripts/test-keychain-source-invariants.py
swift package --disable-sandbox dump-package >/dev/null
swift build --disable-sandbox --configuration release
swift test --disable-sandbox --parallel
swift build \
  --package-path IntegrationTests/Consumer \
  --scratch-path "$temporary_root/consumer-build" \
  --disable-sandbox \
  --configuration debug

ruby -c Latchway.podspec >/dev/null
if command -v pod >/dev/null 2>&1; then
  podspec_json="$temporary_root/Latchway.podspec.json"
  pod ipc spec Latchway.podspec > "$podspec_json"
  ruby -rjson -e '
    spec = JSON.parse(File.read(ARGV.fetch(0)))
    names = spec.fetch("subspecs").map { |entry| entry.fetch("name") }.sort
    expected = %w[AppAttest AppExtensions Core FirebaseAuth]
    abort "CocoaPods subspec surface mismatch: expected #{expected.inspect}, got #{names.inspect}" unless names == expected
  ' "$podspec_json"
  for subspec in AppAttest AppExtensions Core FirebaseAuth; do
    pod lib lint Latchway.podspec \
      --platforms=ios \
      --fail-fast \
      --subspec="$subspec"
  done
fi
