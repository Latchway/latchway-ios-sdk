#!/bin/sh
set -eu

contract_dir=${1:-}
if [ -z "$contract_dir" ]; then
  echo "usage: scripts/check-contract.sh <extracted-contract-directory> [bundle-archive]" >&2
  exit 64
fi
bundle_archive=${2:-}

for required in client.openapi.yaml protocol-version.json test-vectors/dpop/v1.json test-vectors/attestation-binding/v1.json; do
  if [ ! -f "$contract_dir/$required" ]; then
    echo "missing contract entry: $required" >&2
    exit 1
  fi
done

locked_version=$(awk '/^contract_version:/ { print $2 }' contract.lock)
locked_protocol=$(awk '/^wire_protocol:/ { print $2 }' contract.lock)
locked_bundle_sha=$(awk '/^bundle_sha256:/ { gsub(/"/, "", $2); print $2 }' contract.lock)

if [ -n "$bundle_archive" ]; then
  if [ ! -f "$bundle_archive" ]; then
    echo "missing contract bundle: $bundle_archive" >&2
    exit 1
  fi
  if command -v shasum >/dev/null 2>&1; then
    actual_bundle_sha=$(shasum -a 256 "$bundle_archive" | awk '{ print $1 }')
  elif command -v sha256sum >/dev/null 2>&1; then
    actual_bundle_sha=$(sha256sum "$bundle_archive" | awk '{ print $1 }')
  else
    echo "neither shasum nor sha256sum is available" >&2
    exit 1
  fi
  if [ "$actual_bundle_sha" != "$locked_bundle_sha" ]; then
    echo "contract bundle checksum does not match contract.lock" >&2
    exit 1
  fi
fi

if ! grep -q '"contract_version": "'"$locked_version"'"' "$contract_dir/protocol-version.json"; then
  echo "contract version does not match contract.lock" >&2
  exit 1
fi
if ! grep -q '"current": '"$locked_protocol" "$contract_dir/protocol-version.json"; then
  echo "wire protocol does not match contract.lock" >&2
  exit 1
fi

cmp "$contract_dir/test-vectors/dpop/v1.json" Tests/ConformanceTests/Fixtures/dpop-v1.json
cmp "$contract_dir/test-vectors/attestation-binding/v1.json" Tests/ConformanceTests/Fixtures/attestation-binding-v1.json

if [ -n "$bundle_archive" ]; then
  echo "contract $locked_version / wire $locked_protocol / bundle $locked_bundle_sha verified"
else
  echo "contract $locked_version / wire $locked_protocol fixtures verified"
fi
