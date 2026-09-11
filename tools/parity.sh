#!/usr/bin/env bash
# parity.sh - check the cli group really is the same on all three platforms

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/tools/cli-parity.conf"

fail=0
note() { printf '  %-8s %s\n' "$1" "$2"; }
err()  { fail=1; printf '  %-8s %s\n' 'DRIFT' "$1"; }

linux_cli()  { ( set +u; . "${ROOT}/linux/packages.conf";  printf '%s\n' "${GROUP_cli_APT[@]}" ); }
linux_rel()  { ( set +u; . "${ROOT}/linux/packages.conf";  printf '%s\n' "${RELEASES[@]}" ); }
macos_cli()  { ( set +u; . "${ROOT}/macos/packages.conf";  printf '%s\n' "${GROUP_cli_FORMULA[@]}" ); }

HAVE_PWSH=no
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=yes

psd1_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${ROOT}/windows/packages.psd1"
  else
    printf '%s' "${ROOT}/windows/packages.psd1"
  fi
}

windows_cli() {
  local manifest; manifest="$(psd1_path)"
  pwsh -NoProfile -Command "
    \$m = Import-PowerShellDataFile -LiteralPath '${manifest}'
    (\$m.Groups | Where-Object { \$_.Name -eq 'cli' }).Packages
  " 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

has() { printf '%s\n' "$2" | grep -qxF "$1"; }

[[ -r "$TABLE" ]] || { echo "parity: cannot read $TABLE" >&2; exit 1; }

LINUX_ACTUAL="$(linux_cli)"
LINUX_RELEASES="$(linux_rel)"
MACOS_ACTUAL="$(macos_cli)"
WINDOWS_ACTUAL=''
[[ "$HAVE_PWSH" == yes ]] && WINDOWS_ACTUAL="$(windows_cli)"

declare -a TBL_LINUX=() TBL_MACOS=() TBL_WINDOWS=()

echo 'Checking the cli group against tools/cli-parity.conf'
echo

rows=0
while IFS='|' read -r canonical lx mac win _note _cmd _desc; do
  canonical="$(printf '%s' "$canonical" | tr -d '[:space:]')"
  [[ -z "$canonical" || "$canonical" == \#* ]] && continue
  lx="$(printf '%s' "$lx" | tr -d '[:space:]')"
  mac="$(printf '%s' "$mac" | tr -d '[:space:]')"
  win="$(printf '%s' "$win" | tr -d '[:space:]')"
  rows=$(( rows + 1 ))

  case "$lx" in
    -) ;;
    @releases)
      if ! has "${canonical//-/_}" "$LINUX_RELEASES"; then
        err "$canonical: marked @releases but not in linux RELEASES"
      fi ;;
    *) has "$lx" "$LINUX_ACTUAL" || err "$canonical: '$lx' not in linux GROUP_cli_APT" ;;
  esac

  case "$mac" in
    -) ;;
    *) has "$mac" "$MACOS_ACTUAL" || err "$canonical: '$mac' not in macos GROUP_cli_FORMULA" ;;
  esac

  if [[ "$HAVE_PWSH" == yes ]]; then
    case "$win" in
      -) ;;
      *) has "$win" "$WINDOWS_ACTUAL" || err "$canonical: '$win' not in the windows cli group" ;;
    esac
  fi

  [[ "$lx"  != - && "$lx"  != @releases ]] && TBL_LINUX+=("$lx")
  [[ "$lx"  == @releases ]] && TBL_LINUX+=("$canonical")
  [[ "$mac" != - ]] && TBL_MACOS+=("$mac")
  [[ "$win" != - ]] && TBL_WINDOWS+=("$win")
done < "$TABLE"

note 'rows' "$rows tools declared"

undeclared() {
  local label="$1" actual="$2"; shift 2
  local declared; declared="$(printf '%s\n' "$@")"
  local p
  while read -r p; do
    [[ -z "$p" ]] && continue
    has "$p" "$declared" || err "$label: '$p' is in the manifest but not in cli-parity.conf"
  done <<< "$actual"
}

undeclared 'linux'   "$LINUX_ACTUAL"   ${TBL_LINUX[@]+"${TBL_LINUX[@]}"}
undeclared 'macos'   "$MACOS_ACTUAL"   ${TBL_MACOS[@]+"${TBL_MACOS[@]}"}
if [[ "$HAVE_PWSH" == yes ]]; then
  undeclared 'windows' "$WINDOWS_ACTUAL" ${TBL_WINDOWS[@]+"${TBL_WINDOWS[@]}"}
else
  note 'skipped' 'windows - pwsh is not installed'
fi

echo
if [[ "$fail" -eq 0 ]]; then
  echo 'OK   the cli group matches cli-parity.conf on every platform checked'
else
  echo 'FAIL the cli group has drifted - fix the manifest, or declare the'
  echo '     divergence in tools/cli-parity.conf with a note saying why'
fi
exit "$fail"
