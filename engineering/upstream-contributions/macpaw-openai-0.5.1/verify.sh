#!/bin/sh
set -eu

base_revision=a532be89be9a30ec003e4ba0974a52a88d26fc6d
patch_sha256=0d31b3b7a4afeaa5abc91e2deff42910efdfc9c94c479fcdb270a4e66472a44c
upstream_source=${MACPAW_OPENAI_SOURCE:-https://github.com/MacPaw/OpenAI.git}
temporary_root=${TMPDIR:-/tmp}
if [ "$temporary_root" != / ]; then
    temporary_root=${temporary_root%/}
fi

bundle_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$bundle_directory/../../.." && pwd)
patch_file="$bundle_directory/0001-Reuse-injected-URLSession-configuration-for-streams.patch"
probe_source="$repository_root/IntegrationTests/MacPawOpenAITransportSpike/Sources/MacPawOpenAITransportSpike"
work_directory=$(mktemp -d "$temporary_root/latchway-macpaw-contribution.XXXXXX")

cleanup() {
    if [ "${KEEP_MACPAW_CONTRIBUTION_WORKDIR:-0}" = 1 ]; then
        printf '%s\n' "kept verification directory: $work_directory"
        return
    fi
    case "$work_directory" in
        "$temporary_root"/latchway-macpaw-contribution.*) rm -rf -- "$work_directory" ;;
        *) printf '%s\n' "refusing to remove unexpected path: $work_directory" >&2 ;;
    esac
}
trap cleanup EXIT HUP INT TERM

actual_patch_sha256=$(shasum -a 256 "$patch_file" | awk '{print $1}')
if [ "$actual_patch_sha256" != "$patch_sha256" ]; then
    printf '%s\n' "patch checksum mismatch: $actual_patch_sha256" >&2
    exit 1
fi

git clone --no-hardlinks "$upstream_source" "$work_directory/OpenAI"
git -C "$work_directory/OpenAI" checkout --detach "$base_revision"
actual_revision=$(git -C "$work_directory/OpenAI" rev-parse HEAD)
if [ "$actual_revision" != "$base_revision" ]; then
    printf '%s\n' "unexpected upstream revision: $actual_revision" >&2
    exit 1
fi

git -C "$work_directory/OpenAI" apply --check "$patch_file"
git -C "$work_directory/OpenAI" apply "$patch_file"
git -C "$work_directory/OpenAI" diff --check
swift test --package-path "$work_directory/OpenAI"

mkdir -p "$work_directory/Probe/Sources"
cp "$bundle_directory/ProbePackage.swift" "$work_directory/Probe/Package.swift"
cp "$bundle_directory/ProbePackage.resolved" "$work_directory/Probe/Package.resolved"
cp -R "$probe_source" "$work_directory/Probe/Sources/MacPawOpenAITransportSpike"
swift run --disable-automatic-resolution --package-path "$work_directory/Probe" \
    MacPawOpenAITransportSpike --expect-injected-streaming
