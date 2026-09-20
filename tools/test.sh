#!/usr/bin/env bash
# test.sh - what the three bootstrap scripts promise, asserted
#
# Plain bash and python3, no framework and no network: these run on a laptop
# and on a CI runner without installing anything. Anything a test needs that
# may be absent - plutil, GNU find, pwsh - is reported as a skip with its
# reason rather than silently passing.
#
# The functions under test are extracted from the scripts themselves rather
# than copied here, so a test cannot pass against a stale copy of the code.
#
#   bash tools/test.sh            # everything
#   bash tools/test.sh duration   # only the sections whose name matches

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_YELLOW=$'\033[33m'
else
  C_RESET=''; C_GREEN=''; C_RED=''; C_DIM=''; C_CYAN=''; C_YELLOW=''
fi

PASS=0 FAIL=0 SKIP=0
SECTION=''

section() {
  SECTION="$1"
  [[ -n "$FILTER" && "$SECTION" != *"$FILTER"* ]] && return 1
  printf '\n%s== %s%s\n' "$C_CYAN" "$1" "$C_RESET"
  return 0
}

ok()   { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  %sskip%s %s %s(%s)%s\n' "$C_YELLOW" "$C_RESET" "$1" "$C_DIM" "$2" "$C_RESET"; }
bad()  {
  FAIL=$((FAIL + 1))
  printf '  %sFAIL%s %s\n' "$C_RED" "$C_RESET" "$1"
  [[ $# -gt 1 ]] && printf '       want: %s\n       got:  %s\n' "$2" "${3:-}"
  return 0
}

is()   {   # is <label> <want> <got>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi
}

contains() {   # contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *)      bad "$1" "something containing '$2'" "$3" ;;
  esac
}

# Pulls one shell function out of a script, so the test runs the real thing.
extract_func() {   # extract_func <file> <name>
  sed -n "/^$2() {/,/^}/p" "$1"
}

# A path a native Windows program can open. Git Bash hands out /f/work-style
# paths, which pwsh and python.exe read as F:\f\work - a directory that does
# not exist. cygpath is there exactly where that happens; elsewhere the path is
# already native. parity.sh does the same for the same reason.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# A python that runs, not merely one on PATH: Windows puts python3 and python
# there as Microsoft Store stubs that print an install hint and exit non-zero,
# while the real interpreter answers to the py launcher.
PYTHON=()
for cand in python3 python 'py -3'; do
  read -ra words <<< "$cand"
  if "${words[@]}" -c 'import sys' >/dev/null 2>&1; then PYTHON=("${words[@]}"); break; fi
done
unset cand words

# ---------------------------------------------------------------- durations --
#
# Three implementations print the same thing or the rounding is wrong
# somewhere. It was: PowerShell's [int] cast rounds rather than truncates, and
# a 94-second run reported itself as "2m 34s".

if section 'duration formatting'; then
  {
    extract_func "${ROOT}/macos/bootstrap.sh" human_seconds
    cat <<'DRIVER'
for n in "$@"; do printf '%s\n' "$(human_seconds "$n")"; done
DRIVER
  } > "$TMP/hs.sh"

  CASES=(0 45 59 60 94 119 3599 3600 3700 7199 86399 86400 90000 200000)
  WANT=('0s' '45s' '59s' '1m 0s' '1m 34s' '1m 59s' '59m 59s' '1h 0m' '1h 1m'
        '1h 59m' '23h 59m' '1d 0h' '1d 1h' '2d 7h')

  # No mapfile: a Mac ships bash 3.2, and this has to run there too.
  GOT=()
  while IFS= read -r line; do GOT+=("$line"); done < <(bash "$TMP/hs.sh" "${CASES[@]}")

  for i in "${!CASES[@]}"; do
    is "human_seconds ${CASES[$i]}" "${WANT[$i]}" "${GOT[$i]:-}"
  done

  is 'a non-number is "unknown"' 'unknown' "$(bash "$TMP/hs.sh" bogus)"

  if diff -q <(extract_func "${ROOT}/macos/bootstrap.sh" human_seconds) \
             <(extract_func "${ROOT}/linux/bootstrap.sh" human_seconds) >/dev/null; then
    ok 'linux and macos share one implementation'
  else
    bad 'linux and macos share one implementation' 'identical functions' 'they have drifted'
  fi

  # The PowerShell one cannot be sourced from bash, so its boundaries are
  # asserted against the same table by the pwsh section further down.
fi

# ------------------------------------------------------------- brew_error ----
#
# A failed brew call has to say what brew said. The Error: line if there is
# one, the last non-empty line otherwise, never an empty string.

if section 'brew error extraction'; then
  {
    extract_func "${ROOT}/macos/bootstrap.sh" brew_error
    cat <<'DRIVER'
brew_error "$1"
DRIVER
  } > "$TMP/be.sh"

  printf 'Downloading...\nError: Cannot install under Rosetta 2 in ARM default prefix!\nTo rerun under ARM use:\n' > "$TMP/log1"
  is 'prefers the Error: line, without its prefix' \
     'Cannot install under Rosetta 2 in ARM default prefix!' "$(bash "$TMP/be.sh" "$TMP/log1")"

  printf 'curl: (22) The requested URL returned error: 404\n' > "$TMP/log2"
  is 'falls back to the last line' \
     'curl: (22) The requested URL returned error: 404' "$(bash "$TMP/be.sh" "$TMP/log2")"

  printf '\n\n   \n' > "$TMP/log3"
  is 'says something even when brew said nothing' 'no output' "$(bash "$TMP/be.sh" "$TMP/log3")"

  printf 'x%.0s' {1..300} > "$TMP/log4"; echo >> "$TMP/log4"
  long="$(bash "$TMP/be.sh" "$TMP/log4")"
  is 'a wall of text is truncated to fit a result line' '90' "${#long}"
fi

# ------------------------------------------------------------- run record ----
#
# All three platforms write the same key=value record. A reader - --status, or
# a person - should not have to care which script wrote it.

if section 'run record'; then
  # One space-separated line, not one key per line: a failure message that
  # prints only the first differing line tells you nothing.
  keys_of() {   # keys_of <file> - the keys that script's write_state writes
    sed -n '/^write_state()/,/^}/p' "$1" |
      sed -n 's/^ *echo "\([a-z_]*\)=.*/\1/p' | tr '\n' ' ' | sed 's/ $//'
  }
  MAC_KEYS="$(keys_of "${ROOT}/macos/bootstrap.sh")"
  LNX_KEYS="$(keys_of "${ROOT}/linux/bootstrap.sh")"
  WIN_KEYS="$(sed -n '/^function Write-RunRecord/,/^}/p' "${ROOT}/windows/bootstrap.ps1" |
                sed -n 's/^ *"\([a-z_]*\)=.*/\1/p' | tr '\n' ' ' | sed 's/ $//')"

  # One record shape, three implementations. A reader - --status, or a person -
  # should not have to care which script wrote the file in front of them.
  CORE_KEYS='version started finished_epoch duration_seconds exit interactive failed counts log error changed'
  is 'macos writes the expected keys' "$CORE_KEYS" "$MAC_KEYS"
  is 'linux writes exactly what macos writes' "$MAC_KEYS" "$LNX_KEYS"
  is 'windows writes exactly what macos writes' "$MAC_KEYS" "$WIN_KEYS"

  # --status must survive a record it did not write: a truncated one from a
  # killed run, a stray blank line, a value with an = in it.
  {
    extract_func "${ROOT}/macos/bootstrap.sh" human_seconds
    sed -n '/^STATUS_RC=0/,/^}/p' "${ROOT}/macos/bootstrap.sh"
    cat <<'HARNESS'
C_RESET=''; C_GREEN=''; C_RED=''; C_DIM=''; C_CYAN=''; C_YELLOW=''
phase() { printf '== %s\n' "$1"; }
result() { printf '  %-14s%-30s%s\n' "$1" "$2" "${3:-}"; }
STATE_FILE="$1"
print_status
printf 'STATUS_RC=%s\n' "$STATUS_RC"
HARNESS
  } > "$TMP/status.sh"

  cat > "$TMP/record-ok" <<EOF
version=1.36.0
started=2026-09-17T04:20:03Z
finished_epoch=$(( $(date +%s) - 3600 ))
duration_seconds=94
exit=0
interactive=no
failed=''
counts='installed=1 upgraded=12'
log=/tmp/bootstrap.log
error=''
EOF
  out="$(bash "$TMP/status.sh" "$TMP/record-ok")"
  contains 'a clean record reads as clean' 'clean - every step' "$out"
  contains 'and the age is rendered' '1h 0m ago' "$out"
  contains 'and it exits 0' 'STATUS_RC=0' "$out"

  sed "s/^exit=0/exit=1/; s/^failed=''/failed='brew formulae, docker-desktop'/" \
    "$TMP/record-ok" > "$TMP/record-bad"
  out="$(bash "$TMP/status.sh" "$TMP/record-bad")"
  contains 'a failed record names the steps' 'brew formulae, docker-desktop' "$out"
  contains 'and it exits 1' 'STATUS_RC=1' "$out"

  printf 'version=1.36.0\nexit=' > "$TMP/record-truncated"
  out="$(bash "$TMP/status.sh" "$TMP/record-truncated" 2>&1)"
  contains 'a truncated record still prints' 'Last run' "$out"
  contains 'and is treated as a failure, not as success' 'STATUS_RC=1' "$out"

  printf "version=1.36.0\nexit=0\n\nerror='a = sign, and spaces'\nfinished_epoch=0\n" > "$TMP/record-odd"
  out="$(bash "$TMP/status.sh" "$TMP/record-odd" 2>&1)"
  contains 'a blank line and an = in a value are survivable' 'Last run' "$out"

  out="$(bash "$TMP/status.sh" "$TMP/does-not-exist" 2>&1)"
  contains 'no record at all says so' 'nothing recorded yet' "$out"
  contains 'and does not claim a failure' 'STATUS_RC=0' "$out"
fi

# --------------------------------------------------------- version deltas ----
#
# "what moved last night" is the whole point of the history, so the diff
# between two package snapshots has to be right about all three cases.

if section 'version deltas'; then
  printf 'alpha 1.0\nbeta 2.0\ngamma 3.0\n' > "$TMP/before"
  printf 'alpha 1.1\nbeta 2.0\ngamma 3.0\ndelta 4.0\n' > "$TMP/after"

  {
    cat <<'HARNESS'
RUN_CHANGED=''
SNAP_BEFORE="$1"
SNAP_AFTER="$2"
result() { :; }
# The real function makes its own temp file and fills it from brew; here the
# "after" snapshot is the fixture, so both stubs just hand it over.
mktemp_tracked() { eval "$1=\"$SNAP_AFTER\""; }
pkg_snapshot() { :; }
HARNESS
    extract_func "${ROOT}/macos/bootstrap.sh" snapshot_after
    cat <<'DRIVER'
snapshot_after
printf '%s\n' "$RUN_CHANGED"
DRIVER
  } > "$TMP/delta.sh"

  is 'an upgrade, an install and an unchanged package' \
     'alpha 1.0>1.1, +delta 4.0' \
     "$(bash "$TMP/delta.sh" "$TMP/before" "$TMP/after")"

  is 'nothing moved means nothing to say' '' \
     "$(bash "$TMP/delta.sh" "$TMP/before" "$TMP/before")"

  # Linux diffs every dpkg package, so a dist-upgrade has to be summarised
  # rather than printed in full.
  : > "$TMP/before-many"
  : > "$TMP/after-many"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    printf 'pkg%02d 1.0\n' "$i" >> "$TMP/before-many"
    printf 'pkg%02d 2.0\n' "$i" >> "$TMP/after-many"
  done
  {
    cat <<'HARNESS'
RUN_CHANGED=''
SNAP_BEFORE="$1"
SNAP_AFTER="$2"
result() { :; }
mktemp_tracked() { eval "$1=\"$SNAP_AFTER\""; }
pkg_snapshot() { :; }
HARNESS
    extract_func "${ROOT}/linux/bootstrap.sh" snapshot_after
    cat <<'DRIVER'
snapshot_after
printf '%s\n' "$RUN_CHANGED"
DRIVER
  } > "$TMP/delta-linux.sh"
  out="$(bash "$TMP/delta-linux.sh" "$TMP/before-many" "$TMP/after-many")"
  contains 'twelve changes are capped' '+4 more' "$out"
  is 'and the cap keeps eight of them' '8' "$(awk -F'>' '{print NF-1}' <<< "$out")"
fi

# ----------------------------------------------- snapshots that misbehave ----
#
# A regression test with a name: a package listing that exits non-zero prints
# nothing at all rather than a shorter list, and under `set -e` that ended the
# run - before it installed anything - on the machine this was written on. A
# snapshot taken for the history must never be able to do that.
#
# This is also the gap that let it through: the snapshot only runs in a real
# run, and every test until now was a dry run, where it is skipped.

if section 'snapshots survive a broken package manager'; then
  # A brew that answers for formulae and fails for casks, which is how the real
  # one behaves when it cannot describe something it thinks it installed.
  cat > "$TMP/brew-half-broken" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *--formula*) printf 'git 2.55.0\nripgrep 14.1.1\n'; exit 0 ;;
  *--cask*)    printf "Error: Cask 'gone' is not installed.\n" >&2; exit 1 ;;
esac
exit 0
STUB
  chmod +x "$TMP/brew-half-broken"

  {
    # The same shell settings the script runs under - without them the bug
    # this is about cannot reproduce.
    echo 'set -euo pipefail'
    printf 'BREW=%s\n' "$TMP/brew-half-broken"
    extract_func "${ROOT}/macos/bootstrap.sh" pkg_snapshot
    cat <<'DRIVER'
pkg_snapshot "$1"
printf 'survived rc=%s\n' "$?"
DRIVER
  } > "$TMP/snap.sh"

  out="$(bash "$TMP/snap.sh" "$TMP/snap.out" 2>/dev/null)"
  is 'a failing cask listing does not end the run' 'survived rc=0' "$out"
  is 'and the formulae are still recorded' 'git 2.55.0 ripgrep 14.1.1' \
     "$(tr '\n' ' ' < "$TMP/snap.out" | sed 's/ $//')"

  # And the whole thing failing is still not fatal.
  cat > "$TMP/brew-dead" <<'STUB'
#!/usr/bin/env bash
echo 'Error: everything is on fire' >&2
exit 1
STUB
  chmod +x "$TMP/brew-dead"
  {
    echo 'set -euo pipefail'
    printf 'BREW=%s\n' "$TMP/brew-dead"
    extract_func "${ROOT}/macos/bootstrap.sh" pkg_snapshot
    cat <<'DRIVER'
pkg_snapshot "$1"
printf 'survived rc=%s\n' "$?"
DRIVER
  } > "$TMP/snap-dead.sh"
  is 'a package manager that answers nothing is survivable' 'survived rc=0' \
     "$(bash "$TMP/snap-dead.sh" "$TMP/snap-dead.out" 2>/dev/null)"
  is 'and leaves an empty snapshot, not a missing one' '0' \
     "$(wc -l < "$TMP/snap-dead.out" | tr -d ' ')"

  # The Linux one has the same shape and the same hazard: no flatpak at all.
  {
    echo 'set -euo pipefail'
    cat <<'FAKE_DPKG'
dpkg-query() { printf 'libc6 2.41-1\nzsh 5.9-1\n'; }
FAKE_DPKG
    extract_func "${ROOT}/linux/bootstrap.sh" pkg_snapshot
    cat <<'DRIVER'
pkg_snapshot "$1"
printf 'survived rc=%s\n' "$?"
DRIVER
  } > "$TMP/snap-linux.sh"
  is 'linux: a machine with no flatpak is survivable' 'survived rc=0' \
     "$(PATH="$TMP/empty:$PATH" bash "$TMP/snap-linux.sh" "$TMP/snap-linux.out" 2>/dev/null)"
  is 'linux: and dpkg is still recorded' 'libc6 2.41-1 zsh 5.9-1' \
     "$(tr '\n' ' ' < "$TMP/snap-linux.out" | sed 's/ $//')"
fi

# -------------------------------------------------------------- doctor -------
#
# The doctor is mostly questions asked of a live machine, which a test cannot
# stage. What it can check is the mapping the questions are built from: the
# parity table's cmd column is written for a reader, and two rows need
# translating before they name a binary.

if section 'doctor command mapping'; then
  {
    printf 'SCRIPT_DIR=%s\n' "${ROOT}/macos"
    extract_func "${ROOT}/macos/bootstrap.sh" load_parity_table
    extract_func "${ROOT}/macos/bootstrap.sh" parity_row
    extract_func "${ROOT}/macos/bootstrap.sh" doctor_command_for
    cat <<'DRIVER'
load_parity_table
for pkg in "$@"; do printf '%s\n' "$(doctor_command_for "$pkg" || echo 'NONE')"; done
DRIVER
  } > "$TMP/cmdmap.sh"

  is 'a package whose binary shares its name' 'bat' "$(bash "$TMP/cmdmap.sh" bat)"
  is 'ripgrep is rg'                          'rg'  "$(bash "$TMP/cmdmap.sh" ripgrep)"
  is 'git-delta is delta'                     'delta' "$(bash "$TMP/cmdmap.sh" git-delta)"
  is "zoxide's binary, not the z it defines"  'zoxide' "$(bash "$TMP/cmdmap.sh" zoxide)"
  is "7zip's macOS binary is 7zz"             '7zz' "$(bash "$TMP/cmdmap.sh" sevenzip)"
  is 'a package with no row has no command'   'NONE' "$(bash "$TMP/cmdmap.sh" not-a-package)"

  # The Linux loader keeps its table in an associative array, which is bash 4.
  # A Mac's own bash is 3.2, so this half runs on Linux and on CI.
  if [[ "${BASH_VERSINFO[0]:-3}" -lt 4 ]]; then
    skip 'the linux command mapping' "needs bash 4, this is ${BASH_VERSION%%(*}"
  else
  # The Linux loader has to drop the two rows that name no binary of their own.
  {
    printf 'SCRIPT_DIR=%s\n' "${ROOT}/linux"
    printf 'declare -A DOCTOR_CMD=() DOCTOR_ORIGIN=()\n'
    extract_func "${ROOT}/linux/bootstrap.sh" doctor_load_tools
    cat <<'DRIVER'
doctor_load_tools
for want in "$@"; do printf '%s=%s/%s\n' "$want" "${DOCTOR_CMD[$want]:-none}" "${DOCTOR_ORIGIN[$want]:-none}"; done
DRIVER
  } > "$TMP/cmdmap-linux.sh"

  is 'a release binary is expected in ~/.local/bin' 'bat=bat/release' \
     "$(bash "$TMP/cmdmap-linux.sh" bat)"
  is 'an apt package is expected in /usr/bin' 'tmux=tmux/apt' \
     "$(bash "$TMP/cmdmap-linux.sh" tmux)"
  is 'cifs-utils names no binary of its own' 'cifs-utils=none/none' \
     "$(bash "$TMP/cmdmap-linux.sh" cifs-utils)"
  is 'nor does exfatprogs' 'exfatprogs=none/none' \
     "$(bash "$TMP/cmdmap-linux.sh" exfatprogs)"
  fi
fi

# ------------------------------------------------- doctor: launch and cache --
#
# Both checks answer questions about the machine, so the tests build the
# machine: fake binaries that exit the way a broken one does, and a cache
# directory in each state tealdeer can leave it in.

if section 'doctor launch and tldr cache'; then
  if [[ "${BASH_VERSINFO[0]:-3}" -lt 4 ]]; then
    skip 'the linux doctor checks' "needs bash 4, this is ${BASH_VERSION%%(*}"
  else
    mkdir -p "$TMP/dbin"
    for spec in good:0 flagless:2 noexec:126 crashes:139 hangs:124; do
      printf '#!/bin/sh\nexit %s\n' "${spec#*:}" > "$TMP/dbin/${spec%%:*}"
      chmod +x "$TMP/dbin/${spec%%:*}"
    done
    {
      printf 'DOCTOR_OK=0 DOCTOR_BROKEN=0\n'
      printf 'declare -A DOCTOR_CMD=([good]=good [flagless]=flagless [noexec]=noexec [crashes]=crashes [hangs]=hangs [aptone]=aptone)\n'
      printf 'declare -A DOCTOR_ORIGIN=([good]=release [flagless]=release [noexec]=release [crashes]=release [hangs]=release [aptone]=apt)\n'
      printf 'DBIN=%s\n' "$TMP/dbin"
      cat <<'STUBS'
doctor_ok()     { echo "ok|$1"; }
doctor_broken() { echo "broken|$1"; }
doctor_note()   { echo "note|$1"; }
probe_get()     { case "$1" in resolve:aptone) echo /nonexistent/aptone ;; resolve:*) echo "$DBIN/${1#resolve:}" ;; esac; }
STUBS
      extract_func "${ROOT}/linux/bootstrap.sh" doctor_check_launch
      echo 'doctor_check_launch'
    } > "$TMP/launch.sh"
    launch_out="$(bash "$TMP/launch.sh" 2>&1)"

    contains 'a binary that exits 126 is broken'       'broken|noexec launches' "$launch_out"
    contains 'one that crashes (139) is broken'        'broken|crashes launches' "$launch_out"
    contains 'a timeout (124) is a note, not a failure'  'note|hangs launches' "$launch_out"
    case "$launch_out" in
      *'broken|flagless'*) bad 'an unknown --version flag (exit 2) still launched' 'not broken' "$launch_out" ;;
      *)                   ok  'an unknown --version flag (exit 2) still launched' ;;
    esac
    case "$launch_out" in
      *'broken|good'*|*'aptone'*) bad 'working and apt-owned binaries are not reported' 'neither listed' "$launch_out" ;;
      *)                          ok  'working and apt-owned binaries are not reported' ;;
    esac
    if command -v timeout >/dev/null 2>&1; then
      contains 'the summary counts what launched (good, flagless)' 'ok|release binaries launch' "$launch_out"
    else
      skip 'the summary counts what launched' 'no timeout(1) on this machine'
    fi

    # The cache check reads a directory, so build one in each state. Both
    # platforms have the check; macOS's also looks in ~/Library/Caches.
    cache_case() {   # cache_case <platform> <state> - the check's output for that cache
      local root="$TMP/cache-$1-$2"
      mkdir -p "$TMP/tbin" "$root/tealdeer/tldr-pages"
      printf '#!/bin/sh
exit 0
' > "$TMP/tbin/tldr"; chmod +x "$TMP/tbin/tldr"
      case "$2" in
        none)  rm -rf "$root/tealdeer" ;;
        empty) ;;
        fresh) echo x > "$root/tealdeer/tldr-pages/a.md" ;;
        stale) echo x > "$root/tealdeer/tldr-pages/a.md"; touch -d '90 days ago' "$root/tealdeer/tldr-pages/a.md" 2>/dev/null || touch -t 202001010000 "$root/tealdeer/tldr-pages/a.md" ;;
      esac
      {
        printf 'doctor_ok() { echo "ok|$1"; }
doctor_note() { echo "note|$1|$2"; }
'
        # HOME is the scratch root, so ~/Library/Caches cannot be a real one.
        printf 'export PATH=%s:$PATH XDG_CACHE_HOME=%s HOME=%s
' "$TMP/tbin" "$root" "$root/home"
        extract_func "${ROOT}/$1/bootstrap.sh" doctor_check_tldr_cache
        echo 'doctor_check_tldr_cache'
      } > "$TMP/cache-$1-$2.sh"
      bash "$TMP/cache-$1-$2.sh" 2>&1
    }
    for plat in linux macos; do
      contains "$plat: no cache is a note, since the first tldr fills it" 'note|tldr pages|not downloaded' "$(cache_case $plat none)"
      contains "$plat: an empty cache is a note"                          'note|tldr pages|'                 "$(cache_case $plat empty)"
      contains "$plat: a fresh cache is ok"                               'ok|tldr pages'                    "$(cache_case $plat fresh)"
      contains "$plat: nothing under 30 days old is a note"               'none newer than 30 days'          "$(cache_case $plat stale)"
    done
  fi
fi

# ------------------------------------------------------------ launchd plist --
#
# The macOS agent is generated by a heredoc. If it stops being valid XML,
# launchctl rejects it and the daily run silently never happens.

if section 'launchd plist'; then
  {
    cat <<'HARNESS'
set -euo pipefail
SCHEDULE_LABEL="com.github.bootstrap.macos"
SCHEDULE_TIME="04:20"
SCHEDULE_LOG_DIR="/tmp/logs"
SCRIPT_DIR="/tmp/repo & co/macos"
BREW_PREFIX="/opt/homebrew"
sched_hour=$((10#${SCHEDULE_TIME%%:*}))
sched_min=$((10#${SCHEDULE_TIME##*:}))
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NEW_PLIST="$1"
HARNESS
    sed -n '/^    cat > "\$NEW_PLIST" <<PLIST$/,/^PLIST$/p' "${ROOT}/macos/bootstrap.sh" | sed 's/^    //'
  } > "$TMP/plist.sh"

  if bash "$TMP/plist.sh" "$TMP/agent.plist" 2>/dev/null; then
    ok 'the heredoc runs'
  else
    bad 'the heredoc runs' 'a written plist' 'the generator failed'
  fi

  if [[ ${#PYTHON[@]} -eq 0 ]]; then
    skip 'it parses as a plist, with the values the agent needs' 'no working python'
  elif "${PYTHON[@]}" - "$(native_path "$TMP/agent.plist")" <<'PY'
import sys, plistlib
with open(sys.argv[1], 'rb') as fh:
    plist = plistlib.load(fh)
cmd = plist['ProgramArguments'][2]
assert plist['Label'] == 'com.github.bootstrap.macos', plist['Label']
assert plist['StartCalendarInterval'] == {'Hour': 4, 'Minute': 20}, plist['StartCalendarInterval']
assert plist['RunAtLoad'] is False
assert '--skip-cask-upgrade' in cmd, cmd
assert '--skip-update-check' in cmd, cmd
assert '>>' in cmd and '2>&1' in cmd, cmd
assert plist['EnvironmentVariables']['PATH'].startswith('/opt/homebrew/bin'), 'PATH'
# A path with an & in it must survive as itself, not as &amp; .
assert plist['WorkingDirectory'] == '/tmp/repo & co/macos', plist['WorkingDirectory']
PY
  then
    ok 'it parses as a plist, with the values the agent needs'
  else
    bad 'it parses as a plist, with the values the agent needs' 'a valid plist' 'see the assertion above'
  fi

  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$TMP/agent.plist" >/dev/null 2>&1; then
      ok "plutil -lint agrees"
    else
      bad "plutil -lint agrees" 'OK' "$(plutil -lint "$TMP/agent.plist" 2>&1)"
    fi
  else
    skip 'plutil -lint agrees' 'not macOS'
  fi
fi

# ------------------------------------------------------- apt cache pruning ---
#
# The Linux housekeeping phase deletes files by age. The test that matters is
# that it deletes the old one and *only* the old one.

if section 'apt cache pruning'; then
  if ! find /dev/null -maxdepth 0 -printf '' 2>/dev/null; then
    skip 'prunes by age and nothing else' 'needs GNU find'
  else
    APT_CACHE_TEST="$TMP/archives"
    mkdir -p "$APT_CACHE_TEST"
    head -c 3000000 /dev/zero > "$APT_CACHE_TEST/old_1.0_amd64.deb"
    head -c 1000000 /dev/zero > "$APT_CACHE_TEST/new_2.0_amd64.deb"
    touch -d "40 days ago" "$APT_CACHE_TEST/old_1.0_amd64.deb"

    {
      cat <<'HARNESS'
C_RESET=''; C_CYAN=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
DRY_RUN="${DRY_RUN:-no}"; SKIP_CLEANUP=no
APT_CLEANUP_ENABLED=yes; APT_CLEANUP_PRUNE_DAYS=30
phase() { printf '== %s\n' "$1"; }
result() { printf '  %-14s%-16s%s\n' "$1" "$2" "${3:-}"; }
run_priv() { "$@"; }
HARNESS
      sed -n '/^# Housekeeping$/,/^# Tools that install themselves into \$HOME$/p' \
        "${ROOT}/linux/bootstrap.sh" | sed '$d' |
        sed "s#APT_CACHE=/var/cache/apt/archives#APT_CACHE=$APT_CACHE_TEST#"
    } > "$TMP/house.sh"

    out="$(DRY_RUN=yes bash "$TMP/house.sh" 2>/dev/null)"
    contains 'a dry run reports what it would reclaim' 'would-upgrade' "$out"
    contains 'and sizes it in MB' '2.9 MB' "$out"
    is 'and deletes nothing' '2' "$(find "$APT_CACHE_TEST" -name '*.deb' | grep -c .)"

    out="$(bash "$TMP/house.sh" 2>/dev/null)"
    contains 'a real run removes the stale download' '1 .deb(s) removed' "$out"
    is 'and keeps the recent one' 'new_2.0_amd64.deb' "$(cd "$APT_CACHE_TEST" && ls)"

    out="$(bash "$TMP/house.sh" 2>/dev/null)"
    contains 'a second run has nothing to do' 'current' "$out"
  fi
fi

# ------------------------------------------------------------- manifests -----
#
# Invariants the scripts assume while reading a manifest, checked here rather
# than discovered halfway through a run on a new machine.

if section 'manifests'; then
  macos_check="$(
    set +u
    # shellcheck disable=SC1090,SC1091
    . "${ROOT}/macos/packages.conf"
    for g in "${PKG_GROUPS[@]}"; do
      desc="GROUP_${g}_DESC"
      [[ -n "${!desc:-}" ]] || echo "group $g has no description"
    done
    printf '%s\n' "${GROUP_cli_FORMULA[@]}" "${GROUP_dev_FORMULA[@]}" |
      sort | uniq -d | sed 's/^/duplicate package: /'
  )"
  is 'every macOS group is described, and nothing is listed twice' '' "$macos_check"

  for platform in macos linux; do
    version="$(sed -n "s/^BOOTSTRAP_VERSION='\(.*\)'/\1/p" "${ROOT}/${platform}/bootstrap.sh")"
    if grep -qF "## [${version}]" "${ROOT}/${platform}/CHANGELOG.md"; then
      ok "${platform} v${version} has a changelog section"
    else
      bad "${platform} v${version} has a changelog section" \
          "## [${version}] in ${platform}/CHANGELOG.md" 'no such section'
    fi
  done

  win_version="$(sed -n "s/^\\\$script:BootstrapVersion = '\(.*\)'/\1/p" "${ROOT}/windows/bootstrap.ps1")"
  if grep -qF "## [${win_version}]" "${ROOT}/windows/CHANGELOG.md"; then
    ok "windows v${win_version} has a changelog section"
  else
    bad "windows v${win_version} has a changelog section" \
        "## [${win_version}] in windows/CHANGELOG.md" 'no such section'
  fi

  # Every --skip-* and --status the usage text promises is a flag the parser
  # actually takes. A usage line for an option that dies with "unknown option"
  # is worse than no usage line.
  for platform in macos linux; do
    script="${ROOT}/${platform}/bootstrap.sh"
    documented="$(sed -n '/^usage() {/,/^}/p' "$script" | grep -oE '^  --[a-z-]+' | tr -d ' ')"
    undocumented=''
    while read -r flag; do
      [[ -z "$flag" ]] && continue
      # A flag can be spelled `--yes)` or `--yes|-y)` in the case statement.
      grep -qE -- "${flag}[)|]" <<< "$(sed -n '/^while \[\[ \$# -gt 0 \]\]/,/^done/p' "$script")" || \
        undocumented="${undocumented}${flag} "
    done <<< "$documented"
    is "${platform}: every documented flag is parsed" '' "$undocumented"
  done
fi

# ----------------------------------------------------------------- pwsh ------
#
# The Windows half, when there is a pwsh to run it with. CI has one; a Mac
# usually does not, and the section says so rather than passing quietly.

if section 'powershell'; then
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'windows/*.ps1 parse' 'pwsh is not installed'
    skip 'Format-Duration matches the shell implementation' 'pwsh is not installed'
  else
    root_native="$(native_path "$ROOT")"
    # Zero files is a failure, not a pass: with a path pwsh could not resolve,
    # this loop used to find nothing, count no errors and report 'parsed'.
    parse_out="$(pwsh -NoProfile -Command "
      \$bad = 0
      \$files = @(Get-ChildItem '${root_native}/windows/*.ps1')
      foreach (\$file in \$files) {
        \$errors = \$null
        [void][System.Management.Automation.Language.Parser]::ParseFile(\$file.FullName, [ref]\$null, [ref]\$errors)
        if (\$errors.Count) { \$bad++; Write-Output \"\$(\$file.Name): \$(\$errors[0].Message)\" }
      }
      if (\$files.Count -eq 0) { Write-Output 'no .ps1 files found under ${root_native}/windows' }
      elseif (\$bad -eq 0) { Write-Output 'parsed' }" 2>&1)"
    is 'windows/*.ps1 parse' 'parsed' "$(tail -1 <<< "$parse_out")"

    dur_out="$(pwsh -NoProfile -Command "
      \$src = Get-Content -Raw '${root_native}/windows/bootstrap.ps1'
      \$start = \$src.IndexOf('function Format-Duration')
      \$end = \$src.IndexOf('function Write-RunRecord')
      Invoke-Expression \$src.Substring(\$start, \$end - \$start)
      (0, 45, 59, 60, 94, 119, 3599, 3600, 3700, 7199, 86399, 86400, 90000, 200000 |
        ForEach-Object { Format-Duration \$_ }) -join '|'" 2>&1 | tail -1)"
    is 'Format-Duration matches the shell implementation' \
       '0s|45s|59s|1m 0s|1m 34s|1m 59s|59m 59s|1h 0m|1h 1m|1h 59m|23h 59m|1d 0h|1d 1h|2d 7h' \
       "$dur_out"
  fi
fi

# ------------------------------------------------------ the `tools` function --
#
# `tools` is generated text, so the risk is in the generating: a description
# with an apostrophe, an &, a backslash or a $(...) in it must come out the
# other end as those characters, not as a syntax error or a command that runs.
# The generator is extracted from each script and run on rows built to break it.

TOOLS_DESC="it's a \$(echo BOOM) & \`id\` \\ test"

if section 'tools function'; then
  for plat in linux macos; do
    {
      extract_func "${ROOT}/${plat}/bootstrap.sh" emit_tools_function
      printf '%s\n' 'emit_tools_function "$@"'
    } > "$TMP/emit-$plat.sh"
    bash "$TMP/emit-$plat.sh" 'alpha' 'aa' "$TOOLS_DESC" 'beta' '' 'no command' > "$TMP/tools-$plat.sh"
    # An empty table is what a manifest with no cli group would produce.
    empty_ok=yes; bash "$TMP/emit-$plat.sh" > "$TMP/tools-empty-$plat.sh" || empty_ok=no

    if bash -n "$TMP/tools-$plat.sh" 2>"$TMP/tools-$plat.err"; then
      ok "$plat: the generated function parses"
    else
      bad "$plat: the generated function parses" 'no syntax error' "$(cat "$TMP/tools-$plat.err")"
    fi
    is "$plat: an empty table still generates" 'yes' "$empty_ok"

    # Run it with stdout not a terminal, as `tools | rg fd` would.
    out="$(bash -c "source '$TMP/tools-$plat.sh'; tools" 2>&1)"
    contains "$plat: a hostile description comes out verbatim" "$TOOLS_DESC" "$out"
    case "$out" in
      *BOOM*"$TOOLS_DESC"*|*"BOOM"$'\n'*) bad "$plat: nothing in a description is executed" 'no bare BOOM' "$out" ;;
      *) ok "$plat: nothing in a description is executed" ;;
    esac
    case "$out" in
      *$'\033'*) bad "$plat: piped output carries no escape codes" 'plain text' "$out" ;;
      *)         ok  "$plat: piped output carries no escape codes" ;;
    esac
    contains "$plat: a row with no command still lists" 'beta' "$out"
    if command -v zsh >/dev/null 2>&1; then
      zout="$(zsh -c "source '$TMP/tools-$plat.sh'; tools" 2>&1)"
      is "$plat: zsh prints what bash prints" "$out" "$zout"
    else
      skip "$plat: zsh prints what bash prints" 'zsh is not installed'
    fi
  done

  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'windows: the generated function runs' 'pwsh is not installed'
  else
    tmp_native="$(native_path "$TMP")"
    cat > "$TMP/tools-win.ps1" <<PWSH
\$src = Get-Content -Raw '$(native_path "$ROOT")/windows/bootstrap.ps1'
\$start = \$src.IndexOf('function New-ToolsListContent')
\$end = \$src.IndexOf('function Deploy-ToolsList')
Invoke-Expression \$src.Substring(\$start, \$end - \$start)
\$desc = "it's a \`\$(echo BOOM) & \`\`id\`\` \\ test"
\$content = New-ToolsListContent -Rows @(@('alpha', 'aa', \$desc), @('beta', '', 'no command'))
Set-Content -Path '$tmp_native/tools-win-out.ps1' -Value \$content
. '$tmp_native/tools-win-out.ps1'
(tools 6>&1 | Out-String) -replace '\s+', ' '
PWSH
    win_out="$(pwsh -NoProfile -File "$(native_path "$TMP")/tools-win.ps1" 2>&1)"
    contains 'windows: an apostrophe survives the generated function' "it's a" "$win_out"
    contains 'windows: a row with no command still lists' 'beta' "$win_out"
    case "$win_out" in
      *'$(echo BOOM) & '*) ok 'windows: nothing in a description is executed' ;;
      *)           bad 'windows: nothing in a description is executed' 'the literal $(echo BOOM)' "$win_out" ;;
    esac
  fi
fi

# --------------------------------------------------------- workflow pickers --
#
# gb, gs, fkill and cheat: fzf pickers over git, processes and the tools list.
# zsh cannot be run on every machine, so the shared block is checked for being
# one block and, where zsh exists, for parsing. PowerShell's are run for real
# against a scratch repo, with fzf in --select-1 mode standing in for a person.

if section 'workflow pickers'; then
  # The opener is indented to match its surroundings, which differ per script.
  wf_of() { sed -n "/^ *cat <<'WORKFLOW'\$/,/^WORKFLOW\$/p" "$1" | sed 's/^ *cat/cat/'; }
  wf_linux="$(wf_of "${ROOT}/linux/bootstrap.sh")"
  wf_macos="$(wf_of "${ROOT}/macos/bootstrap.sh")"
  if [[ -n "$wf_linux" && "$wf_linux" == "$wf_macos" ]]; then
    ok 'linux and macos write the same picker block'
  else
    bad 'linux and macos write the same picker block' 'identical, non-empty' 'they differ or are missing'
  fi

  printf '%s\n' "$wf_linux" | sed '1d;$d' > "$TMP/pickers.zsh"
  for fn in gb gs fkill cheat; do
    contains "the picker block defines $fn" "$fn() {" "$(cat "$TMP/pickers.zsh")"
  done
  if command -v zsh >/dev/null 2>&1; then
    if zsh -n "$TMP/pickers.zsh" 2>"$TMP/pickers.err"; then ok 'the picker block parses as zsh'
    else bad 'the picker block parses as zsh' 'no syntax error' "$(cat "$TMP/pickers.err")"; fi
  else
    skip 'the picker block parses as zsh' 'zsh is not installed'
  fi

  if ! command -v pwsh >/dev/null 2>&1 || ! command -v fzf >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
    skip 'windows: gb, gs and cheat against a scratch repo' 'needs pwsh, fzf and git'
  else
    cat > "$TMP/pickers-win.ps1" <<'PWSH'
$ErrorActionPreference = 'Stop'
$ast = [System.Management.Automation.Language.Parser]::ParseFile("$env:T_ROOT/windows/profile.ps1", [ref]$null, [ref]$null)
foreach ($n in 'gb', 'gs', 'cheat') {
    $f = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq $n }, $true) | Select-Object -First 1
    if (-not $f) { throw "no function $n in profile.ps1" }
    Invoke-Expression $f.Extent.Text
}
function tldr { "TLDR:$($args -join ' ')" }
git init -q "$env:T_TMP/repo" | Out-Null
Set-Location "$env:T_TMP/repo"
git config user.email t@example.com; git config user.name t
'a' | Set-Content f; git add f; git commit -q -m one
git branch feature/login
$env:FZF_DEFAULT_OPTS = '--filter=feature'
gb *> $null
"branch=$(git branch --show-current)"
'b' | Set-Content f; git stash -q
$env:FZF_DEFAULT_OPTS = '--select-1 --query=WIP'
gs *> $null
"applied=$((Get-Content f) -join '')"
"kept=$(@(git stash list).Count)"
$global:ToolsRows = @(
    ,@('ripgrep', 'rg', 'fast grep')
    ,@('sd', 'sd', "it's sed")
)
$env:FZF_DEFAULT_OPTS = '--filter=ripgrep'
"cheat=$(cheat)"
PWSH
    win_wf="$(T_ROOT="$(native_path "$ROOT")" T_TMP="$(native_path "$TMP")" pwsh -NoProfile -File "$(native_path "$TMP")/pickers-win.ps1" 2>&1)"
    contains 'windows: gb switches to the picked branch'    'branch=feature/login' "$win_wf"
    contains 'windows: gs applies the picked stash'         'applied=b' "$win_wf"
    contains 'windows: gs applies and does not drop'        'kept=1' "$win_wf"
    contains 'windows: cheat opens the page of the pick'    'cheat=TLDR:rg' "$win_wf"

    # The doctor's verdicts on those facts. Get-ProbeValue and the Add-Doctor*
    # reporters are stubbed, so each case is only a hashtable of what a probe
    # would have said.
    cat > "$TMP/doctor-win.ps1" <<'PWSH'
$src = Get-Content -Raw "$env:T_ROOT/windows/bootstrap.ps1"
$start = $src.IndexOf('function Test-DoctorWorkflow'); $end = $src.IndexOf('# tealdeer fills its page cache')
Invoke-Expression $src.Substring($start, $end - $start)
$script:seen = @()
function Add-DoctorOk     { param($Id, $Detail) $script:seen += "ok:$Id" }
function Add-DoctorBroken { param($Id, $Detail) $script:seen += "broken:$Id" }
function Add-DoctorNote   { param($Id, $Detail) $script:seen += "note:$Id" }
function Get-ProbeValue   { param($Key) if ($script:facts.ContainsKey($Key)) { $script:facts[$Key] } else { '' } }
$healthy = @{ 'cmd:tools' = '1'; 'tools:rows' = '12'; 'resolve:fzf' = 'C:\fzf.exe'
              'cmd:gb' = '1'; 'cmd:gs' = '1'; 'cmd:fkill' = '1'; 'cmd:cheat' = '1' }
# `+` on hashtables throws on a repeated key rather than overriding it.
function With([hashtable]$base, [hashtable]$over) { $c = $base.Clone(); foreach ($k in $over.Keys) { $c[$k] = $over[$k] }; $c }
function Run([hashtable]$facts) { $script:facts = $facts; $script:seen = @(); Test-DoctorWorkflow; $script:seen -join ',' }
"healthy=$(Run $healthy)"
"noprofile=$(Run @{ 'resolve:fzf' = 'C:\fzf.exe' })"
"emptylist=$(Run (With $healthy @{ 'tools:rows' = '0' }))"
"nofzf=$(Run @{ 'cmd:tools' = '1'; 'tools:rows' = '3' })"
"ghostscript=$(Run (With $healthy @{ 'cmd:gs' = '0'; 'app:gs' = 'C:\gs\gs.exe' }))"
PWSH
    win_doc="$(T_ROOT="$(native_path "$ROOT")" pwsh -NoProfile -File "$(native_path "$TMP")/doctor-win.ps1" 2>&1)"
    contains 'windows doctor: a healthy shell is all ok' 'healthy=ok:tools,ok:gb,ok:fkill,ok:cheat,ok:gs' "$win_doc"
    contains 'windows doctor: no profile means no tools'  'broken:tools' "$win_doc"
    contains 'windows doctor: an empty list is broken'    'emptylist=broken:tools' "$win_doc"
    contains 'windows doctor: no fzf is a note, not a failure' 'nofzf=ok:tools,note:workflow pickers' "$win_doc"
    contains "windows doctor: Ghostscript's gs is a note" 'note:gs' "$win_doc"
  fi
fi

# ---------------------------------------------------------------- summary ----

printf '\n%s== summary%s\n' "$C_CYAN" "$C_RESET"
printf '  %spassed%s  %s\n' "$C_GREEN" "$C_RESET" "$PASS"
[[ "$SKIP" -gt 0 ]] && printf '  %sskipped%s %s\n' "$C_YELLOW" "$C_RESET" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
  printf '  %sfailed%s  %s\n\n' "$C_RED" "$C_RESET" "$FAIL"
  exit 1
fi
printf '\n'
exit 0
