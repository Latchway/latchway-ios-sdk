#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 vMAJOR.MINOR.PATCH OUTPUT_DIRECTORY" >&2
  exit 64
fi

release_tag=$1
output_directory=$2
if ! printf '%s\n' "$release_tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "release tag must be a canonical stable semantic version" >&2
  exit 64
fi
if [ ! -d "$output_directory" ]; then
  echo "output directory does not exist" >&2
  exit 64
fi

version=${release_tag#v}
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/latchway-ios-release.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM
prefix="latchway-ios-sdk-$version/"

git archive --format=tar --prefix="$prefix" --output="$temporary_root/first.tar" "$release_tag"
git archive --format=tar --prefix="$prefix" --output="$temporary_root/second.tar" "$release_tag"
gzip -n -9 "$temporary_root/first.tar"
gzip -n -9 "$temporary_root/second.tar"
cmp "$temporary_root/first.tar.gz" "$temporary_root/second.tar.gz"

archive="$output_directory/latchway-ios-sdk-$version.tar.gz"
cp "$temporary_root/first.tar.gz" "$archive"
(
  cd "$output_directory"
  shasum -a 256 "${archive##*/}" >"${archive##*/}.sha256"
)
echo "Built reproducible iOS source archive ${archive##*/}"
