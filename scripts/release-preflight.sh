#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/release-preflight.sh <vMAJOR.MINOR.PATCH>" >&2
  exit 64
fi

release_tag=$1
version=${release_tag#v}
if ! printf '%s\n' "$release_tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "release tag must be a canonical stable semantic version" >&2
  exit 1
fi

sdk_version=$(awk -F '"' '/public static let sdk =/ { print $2 }' Sources/Latchway/LatchwayVersion.swift)
contract_version=$(awk -F '"' '/public static let contract =/ { print $2 }' Sources/Latchway/LatchwayVersion.swift)
locked_contract=$(awk '/^contract_version:/ { print $2 }' contract.lock)
podspec_version=$(ruby -e 'content = File.read("Latchway.podspec"); match = content.match(/spec\.version\s*=\s*['"'"']([^'"'"']+)['"'"']/); abort "podspec version missing" unless match; print match[1]')

if [ "$sdk_version" != "$version" ] || [ "$podspec_version" != "$version" ]; then
  echo "tag, public SDK version, and podspec version must match" >&2
  exit 1
fi
if [ "$contract_version" != "$locked_contract" ]; then
  echo "public contract version does not match contract.lock" >&2
  exit 1
fi
if [ -n "$(git status --short --untracked-files=all)" ]; then
  echo "release checkout must be clean" >&2
  exit 1
fi
if [ "$(git rev-parse "$release_tag^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "release tag must resolve to the checked-out commit" >&2
  exit 1
fi
if git ls-files | grep -Eq '(^|/)(\.env($|\.)|DerivedData|\.build)(/|$)|\.(p8|p12|cer|mobileprovision)$'; then
  echo "release tree contains forbidden credentials or local build output" >&2
  exit 1
fi

scripts/verify-package.sh
