#!/usr/bin/env bash
set -euo pipefail

app="${1:-}"
[[ -n "$app" && -d "$app" ]] || { echo "Usage: $0 <KOEON.app>" >&2; exit 2; }
executable="$app/KOEON"
frameworks="$app/Frameworks"
[[ -x "$executable" ]] || { echo "KOEON executable is missing" >&2; exit 1; }

if ! otool -l "$executable" | awk '
  $1 == "cmd" && $2 == "LC_RPATH" { in_rpath=1; next }
  in_rpath && $1 == "path" && $2 == "@executable_path/Frameworks" { found=1 }
  END { exit(found ? 0 : 1) }
'; then
  echo "Missing runtime Frameworks search path" >&2
  exit 1
fi
[[ -x "$frameworks/LiveKitWebRTC.framework/LiveKitWebRTC" ]] || { echo "LiveKit runtime framework is missing" >&2; exit 1; }

validate_binary() {
  local binary="$1" dependency framework_name framework_binary
  while IFS= read -r dependency; do
    dependency="${dependency#${dependency%%[![:space:]]*}}"
    dependency="${dependency%% *}"
    case "$dependency" in
      @rpath/*.framework/*)
        framework_name="${dependency#@rpath/}"
        framework_name="${framework_name%%.framework/*}"
        framework_binary="$frameworks/$framework_name.framework/$framework_name"
        [[ -x "$framework_binary" ]] || { echo "Unresolved bundled runtime framework" >&2; exit 1; }
        ;;
      /System/Library/*|/usr/lib/*|@executable_path/*|@loader_path/*) ;;
      /*) echo "Unexpected absolute non-system runtime dependency" >&2; exit 1 ;;
    esac
  done < <(otool -L "$binary" | tail -n +2)
}

validate_binary "$executable"
if [[ -d "$frameworks" ]]; then
  while IFS= read -r framework_binary; do validate_binary "$framework_binary"; done \
    < <(find "$frameworks" -mindepth 2 -maxdepth 2 -type f -perm -111 -print | sort)
fi
echo "RUNTIME_FRAMEWORKS=PASS"
