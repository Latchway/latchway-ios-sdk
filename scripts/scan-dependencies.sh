#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"

source_commit=${1:-${LATCHWAY_SOURCE_COMMIT:-}}
[[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "usage: scripts/scan-dependencies.sh <40-character-source-commit>" >&2
  exit 2
}
[[ "$(git rev-parse --verify HEAD)" = "$source_commit" ]] || {
  echo "dependency scan source commit does not match HEAD" >&2
  exit 1
}

readonly policy_files=(
  Package.swift
  Package.resolved
  IntegrationTests/Consumer/Package.resolved
  scripts/install-osv-scanner.sh
  scripts/scan-dependencies.sh
  scripts/verify-osv-report.py
)
for path in "${policy_files[@]}"; do
  [[ -f "$path" ]] || { echo "missing dependency scan input" >&2; exit 1; }
  expected_blob=$(git rev-parse "$source_commit:$path")
  actual_blob=$(git hash-object "$path")
  [[ "$actual_blob" = "$expected_blob" ]] || {
    echo "dependency scan input is not bound to the candidate: $path" >&2
    exit 1
  }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/latchway-osv.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
scanner="$work/osv-scanner"
if [[ "${LATCHWAY_OSV_TEST_MODE:-0}" = "1" && "${CI:-}" != "true" ]]; then
  [[ -x "${LATCHWAY_OSV_TEST_SCANNER:-}" ]] || {
    echo "test scanner is not executable" >&2
    exit 2
  }
  scanner=$LATCHWAY_OSV_TEST_SCANNER
else
  [[ -z "${LATCHWAY_OSV_TEST_SCANNER:-}" ]] || {
    echo "test scanner override is forbidden" >&2
    exit 2
  }
  scripts/install-osv-scanner.sh "$scanner"
fi

version_output=$("$scanner" --version)
grep -Fxq "osv-scanner version: 2.4.0" <<<"$version_output"
grep -Fxq "commit: b56b5191101d5f27d4787d5583d8d01e9518a7af" <<<"$version_output"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

inventory_manifest="$work/inventory.sha256"
for path in Package.swift Package.resolved IntegrationTests/Consumer/Package.resolved; do
  printf '%s  %s\n' "$(sha256_file "$path")" "$path" >> "$inventory_manifest"
done
inventory_sha256=$(sha256_file "$inventory_manifest")

report="$work/osv-report.json"
database="$work/database"
set +e
env -u GH_TOKEN -u GITHUB_TOKEN -u NPM_TOKEN -u NODE_AUTH_TOKEN \
  -u COCOAPODS_TRUNK_TOKEN -u SONATYPE_USERNAME -u SONATYPE_PASSWORD \
  OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$database" \
  "$scanner" scan source \
    --lockfile=Package.resolved \
    --lockfile=IntegrationTests/Consumer/Package.resolved \
    --offline --download-offline-databases --no-resolve \
    --format=json --all-packages --verbosity=error \
    --output-file="$report"
scanner_status=$?
set -e
[[ "$scanner_status" -eq 0 || "$scanner_status" -eq 1 ]] || {
  echo "OSV-Scanner failed closed with operational status $scanner_status" >&2
  exit 1
}

database_manifest="$work/database.sha256"
expected_database="$database/osv-scanner/SwiftURL/all.zip"
[[ -s "$expected_database" ]] || {
  echo "OSV-Scanner did not materialize the expected SwiftURL vulnerability database" >&2
  exit 1
}
while IFS= read -r path; do
  relative_path=${path#"$database/"}
  printf '%s  %s\n' "$(sha256_file "$path")" "$relative_path" >> "$database_manifest"
done < <(find "$database/osv-scanner" -type f -name all.zip -print | LC_ALL=C sort)
[[ -s "$database_manifest" ]] || {
  echo "OSV-Scanner did not materialize an offline vulnerability database" >&2
  exit 1
}
database_sha256=$(sha256_file "$database_manifest")

verification=(
  python3 scripts/verify-osv-report.py
  --report "$report"
  --source-commit "$source_commit"
  --inventory-sha256 "$inventory_sha256"
  --database-sha256 "$database_sha256"
)
if [[ -n "${LATCHWAY_OSV_EVIDENCE_PATH:-}" ]]; then
  verification+=(--evidence "$LATCHWAY_OSV_EVIDENCE_PATH")
fi
"${verification[@]}"
