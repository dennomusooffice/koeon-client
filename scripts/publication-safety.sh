#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for forbidden in src server web event-lp deploy task public/moty2026 docs/private; do
  if [[ -e "$forbidden" ]]; then
    echo "Forbidden path present: $forbidden" >&2
    exit 1
  fi
done

if find . -path ./.git -prune -o -type f -print | grep -Eiq '/([^/]*(\.p8|\.p12|\.mobileprovision|\.jks|\.keystore|\.pem|id_rsa|id_ed25519)|\.env([^/]*)?)$'; then
  echo "Signing/secret filename found" >&2
  exit 1
fi

files=()
while IFS= read -r -d '' file; do files+=("$file"); done < <(find . -path ./.git -prune -o -type f ! -name gradle-wrapper.jar ! -path ./scripts/publication-safety.sh -print0)

if grep -IEn '(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{30,}|xox[baprs]-[0-9A-Za-z-]{10,}|LIVEKIT_API_SECRET[[:space:]]*=)' "${files[@]}"; then
  echo "High-confidence secret pattern found" >&2
  exit 1
fi

if grep -IEn '(muso-apps\.net|testflight\.apple\.com/join/|DEVELOPMENT_TEAM[[:space:]]*=|pull_request_target)' "${files[@]}"; then
  echo "Private endpoint, signing team, tester code, or pull_request_target found" >&2
  exit 1
fi

echo 'HIGH_CONFIDENCE_SECRET_HITS=0'
echo 'PRIVATE_EVENT_PATHS=0'
echo 'SERVER_IMPLEMENTATION_PATHS=0'
echo 'WEB_CLIENT_PATHS=0'
echo 'SIGNING_SECRET_FILES=0'
