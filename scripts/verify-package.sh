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
  pod lib lint Latchway.podspec --platforms=ios --fail-fast
fi
