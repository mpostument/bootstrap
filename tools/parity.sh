#!/usr/bin/env bash
# ============================================================
# parity.sh - check the cli group really is the same on all three platforms
# ============================================================
# The three manifests each claim in a comment that their `cli` group is
# deliberately identical. This checks it, against the mapping in
# cli-parity.conf, and fails if a manifest and that file disagree.
#
# It reads the manifests; it installs nothing and needs no package manager, so
# it runs anywhere - including a Linux CI runner checking the Windows list.
#
# Two directions, and both matter. A tool in the table but missing from a
# manifest is drift. A tool in a manifest but missing from the table is an
# undeclared decision - which is the shape the yq bug had, so it is an error
# here rather than a warning.
#
# Exit 0 when they agree, 1 when they do not.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="${ROOT}/tools/cli-parity.conf"

fail=0
note() { printf '  %-8s %s\n' "$1" "$2"; }
err()  { fail=1; printf '  %-8s %s\n' 'DRIFT' "$1"; }

# ------------------------------------------------------------
# What each manifest actually says
# ------------------------------------------------------------
# Sourced in a subshell each time and printed one per line, rather than sourced
# into this shell: the two manifests define overlapping variable names -
# PKG_GROUPS, TOOLS, ZSH_PLUGINS - so sourcing both here would silently leave
# whichever came second in charge of all of them.
linux_cli()  { ( set +u; . "${ROOT}/linux/packages.conf";  printf '%s\n' "${GROUP_cli_APT[@]}" ); }
linux_rel()  { ( set +u; . "${ROOT}/linux/packages.conf";  printf '%s\n' "${RELEASES[@]}" ); }
macos_cli()  { ( set +u; . "${ROOT}/macos/packages.conf";  printf '%s\n' "${GROUP_cli_FORMULA[@]}" ); }

# The Windows manifest is PowerShell data, so pwsh reads it - the same
# Import-PowerShellDataFile the release workflow uses, which evaluates nothing.
# Without pwsh the Windows column is skipped rather than guessed at: a regex
# over a .psd1 would be a second, worse parser that disagrees with the real one
# exactly when it matters.
HAVE_PWSH=no
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=yes

# Git Bash hands out MSYS paths - /f/WORK/... - which pwsh is a native Windows
# process and cannot resolve; it reports the file does not exist, the Windows
# column comes back empty, and every row reads as drift. cygpath translates,
# and exists only where the translation is needed, so its absence on a Linux
# runner is the correct answer rather than a missing dependency.
psd1_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${ROOT}/windows/packages.psd1"
  else
    printf '%s' "${ROOT}/windows/packages.psd1"
  fi
}

windows_cli() {
  local manifest; manifest="$(psd1_path)"
  # -LiteralPath: a Windows path is full of backslashes, which PowerShell's
  # -Path treats as wildcard escapes.
  pwsh -NoProfile -Command "
    \$m = Import-PowerShellDataFile -LiteralPath '${manifest}'
    (\$m.Groups | Where-Object { \$_.Name -eq 'cli' }).Packages
  " 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

has() { printf '%s\n' "$2" | grep -qxF "$1"; }

# ------------------------------------------------------------
# Read the table
# ------------------------------------------------------------
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
while IFS='|' read -r canonical lx mac win _note; do
  # Trim. Comments and blank lines are not rows.
  canonical="$(printf '%s' "$canonical" | tr -d '[:space:]')"
  [[ -z "$canonical" || "$canonical" == \#* ]] && continue
  lx="$(printf '%s' "$lx" | tr -d '[:space:]')"
  mac="$(printf '%s' "$mac" | tr -d '[:space:]')"
  win="$(printf '%s' "$win" | tr -d '[:space:]')"
  rows=$(( rows + 1 ))

  # --- Linux -------------------------------------------------------------
  case "$lx" in
    -) ;;
    # @releases means the command exists, installed by the release-binary
    # phase instead of apt. Checked against RELEASES so the marker cannot
    # outlive the entry it points at - which is how a fix rots back into a bug.
    @releases)
      # RELEASES entries use _ where a command uses -, because they become
      # shell variable names.
      if ! has "${canonical//-/_}" "$LINUX_RELEASES"; then
        err "$canonical: marked @releases but not in linux RELEASES"
      fi ;;
    *) has "$lx" "$LINUX_ACTUAL" || err "$canonical: '$lx' not in linux GROUP_cli_APT" ;;
  esac

  # --- macOS -------------------------------------------------------------
  case "$mac" in
    -) ;;
    *) has "$mac" "$MACOS_ACTUAL" || err "$canonical: '$mac' not in macos GROUP_cli_FORMULA" ;;
  esac

  # --- Windows -----------------------------------------------------------
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

# ------------------------------------------------------------
# The other direction: anything in a manifest the table does not know about
# ------------------------------------------------------------
# This is the check that would have caught yq. An undeclared package is not a
# style problem - it is a decision nobody wrote down, and the reason a parity
# claim can be false for months without anybody noticing.
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
