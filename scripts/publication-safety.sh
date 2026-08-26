#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

for forbidden in src server backend web event event-lp deploy task public/moty2026 docs/private; do
  if [[ -e "$forbidden" ]]; then
    echo "Forbidden path present: $forbidden" >&2
    exit 1
  fi
done

tracked=()
while IFS= read -r -d '' file; do
  case "$file" in
    android/gradle/wrapper/gradle-wrapper.jar|scripts/publication-safety.sh|scripts/ci-public-safety.sh)
      continue
      ;;
  esac
  tracked+=("$file")
done < <(git ls-files -z)

if ((${#tracked[@]} == 0)); then
  echo "No tracked files available for publication scan" >&2
  exit 1
fi

if printf '%s\0' "${tracked[@]}" | grep -zEiq '/([^/]*(\.p8|\.p12|\.mobileprovision|\.jks|\.keystore|\.pem|id_rsa|id_ed25519)|\.env([^/]*)?)$'; then
  echo "Signing/secret filename found" >&2
  exit 1
fi

secret_pattern='(-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[0-9A-Za-z]{30,}|xox[baprs]-[0-9A-Za-z-]{10,}|LIVEKIT_API_SECRET[[:space:]]*=)'
private_reference_pattern='(testflight\.apple\.com/join/|DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}([^A-Z0-9]|$))'
muso_reference_pattern='([[:alnum:]-]+\.)*muso-apps\.net'
approved_public_invite_host='koeon.muso-apps.net'
production_secret_pattern='(APNS_(AUTH_)?KEY|APP_STORE_CONNECT_(KEY|ISSUER)|PLAY_(SERVICE_ACCOUNT|SIGNING)|LIVEKIT_API_SECRET)[[:space:]]*[:=]'
private_ip_pattern='(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'

if grep -IEn "$secret_pattern" "${tracked[@]}"; then
  echo "High-confidence secret pattern found" >&2
  exit 1
fi

if grep -IEn "$private_reference_pattern" "${tracked[@]}"; then
  echo "Private endpoint, signing team, or tester code found" >&2
  exit 1
fi

# Allow only the exact, approved public Invite host. Any other muso-apps.net
# hostname (including the apex) remains a publication blocker.
unapproved_muso_references="$(grep -IEno "$muso_reference_pattern" "${tracked[@]}" \
  | grep -vE ":${approved_public_invite_host}$" || true)"
if [[ -n "$unapproved_muso_references" ]]; then
  echo "Unapproved muso-apps.net reference found" >&2
  printf '%s\n' "$unapproved_muso_references" >&2
  exit 1
fi

if grep -IEn "$production_secret_pattern" "${tracked[@]}"; then
  echo "Production secret reference found" >&2
  exit 1
fi

if grep -IEn "$private_ip_pattern" "${tracked[@]}"; then
  echo "Private IP literal found" >&2
  exit 1
fi

invite_scan=()
for file in "${tracked[@]}"; do
  case "$file" in
    LICENSE|NOTICE|THIRD_PARTY_NOTICES.md|protocol/pnpm-lock.yaml|sbom/*|docs/DEPENDENCY_*|docs/ACTIONS_RUNTIME_EVIDENCE.md)
      continue
      ;;
  esac
  invite_scan+=("$file")
done

invite_candidates="$(grep -IhEo '(^|[^0-9A-Z])[0-9ABCDEFGHJKMNPQRSTVWXYZ]{10}([^0-9A-Z]|$)' "${invite_scan[@]}" \
  | grep -Eo '[0-9ABCDEFGHJKMNPQRSTVWXYZ]{10}' \
  | sort -u \
  | grep -Ev '^(ABCDE23456|1234567890|2147483647|DEPENDENCY|PREFERENCE|REFERENCES|TASK003G6B|TRADEMARKS)$' || true)"
if [[ -n "$invite_candidates" ]]; then
  echo "Non-synthetic invite-shaped value found" >&2
  printf '%s\n' "$invite_candidates" >&2
  exit 1
fi

history_pathspec=(-- . ':(exclude)scripts/publication-safety.sh' ':(exclude)scripts/ci-public-safety.sh')
while IFS= read -r commit; do
  history_paths="$(git ls-tree -r --name-only "$commit")"
  if grep -Eiq '^(src|server|backend|web|event|event-lp|task|docs/private|public/moty2026)(/|$)' <<<"$history_paths"; then
    echo "Forbidden private/server/Web/event path found in history at $commit" >&2
    exit 1
  fi
  if grep -Eiq '(^|/)([^/]*(\.p8|\.p12|\.mobileprovision|\.jks|\.keystore|\.pem)|id_rsa|id_ed25519|\.env([^/]*))$' <<<"$history_paths"; then
    echo "Signing/secret filename found in history at $commit" >&2
    exit 1
  fi
  if git grep -IEn "$secret_pattern" "$commit" "${history_pathspec[@]}"; then
    echo "High-confidence secret found in history at $commit" >&2
    exit 1
  fi
  if git grep -IEn "$private_reference_pattern" "$commit" "${history_pathspec[@]}"; then
    echo "Private reference found in history at $commit" >&2
    exit 1
  fi
  history_muso_references="$(git grep -IEno "$muso_reference_pattern" "$commit" "${history_pathspec[@]}" \
    | grep -vE ":${approved_public_invite_host}$" || true)"
  if [[ -n "$history_muso_references" ]]; then
    echo "Unapproved muso-apps.net reference found in history at $commit" >&2
    printf '%s\n' "$history_muso_references" >&2
    exit 1
  fi
  if git grep -IEn 'moty20[0-9]{2}' "$commit" "${history_pathspec[@]}"; then
    echo "Legacy event campaign identifier found in history at $commit" >&2
    exit 1
  fi
done < <(git rev-list --all)

if git log --all --format='%B' | grep -Eiq "$secret_pattern|$private_reference_pattern"; then
  echo "Sensitive value found in commit messages" >&2
  exit 1
fi

unapproved_muso_messages="$(git log --all --format='%B' \
  | grep -Eio "$muso_reference_pattern" \
  | grep -vE "^${approved_public_invite_host}$" || true)"
if [[ -n "$unapproved_muso_messages" ]]; then
  echo "Unapproved muso-apps.net reference found in commit messages" >&2
  exit 1
fi

echo 'HIGH_CONFIDENCE_SECRET_HITS=0'
echo 'PRIVATE_SERVER_PATHS=0'
echo 'WEB_CLIENT_PATHS=0'
echo 'EVENT_PATHS=0'
echo 'MOTY_IDENTIFIERS=0'
echo 'PRIVATE_OPERATIONAL_DOCS=0'
echo 'SIGNING_FILES=0'
echo 'PRODUCTION_SECRET_REFERENCES=0'
echo 'PRIVATE_IPS=0'
echo 'KNOWN_INVITE_CODES=0'
echo 'HISTORY_SCAN=PASS'
