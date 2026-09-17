#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_VERSION='1.37.1'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
SKIP_CASK_UPGRADE=no
SKIP_CLEANUP=no
SKIP_SCHEDULE=no
SKIP_VSCODE_EXT=no
SKIP_UPDATE_CHECK=no
GUI_OVERRIDE=auto
ONLY_GROUPS=""
STATUS_ONLY=no
DOCTOR_ONLY=no
HISTORY_ONLY=no
HISTORY_LINES=10

# Run state. The launchd agent exports BOOTSTRAP_LOG_DIR, so a run started by
# it knows which log file it is being written to and can say so in --status.
RUN_STARTED_EPOCH="$(date +%s)"
RUN_STARTED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_INTERACTIVE=no
[[ -t 1 ]] && RUN_INTERACTIVE=yes
RUN_LOG=""
[[ -n "${BOOTSTRAP_LOG_DIR:-}" ]] && RUN_LOG="${BOOTSTRAP_LOG_DIR}/bootstrap-$(date +%Y-%m-%d).log"
RUN_RECORDING=no
# What this run moved: "pkg old>new" for an upgrade, "+pkg version" for an
# install, filled in by comparing a snapshot taken before the packages phase
# with one taken after the upgrades.
RUN_CHANGED=''
SNAP_BEFORE=''
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/bootstrap-macos"
STATE_FILE="${STATE_DIR}/last-run"
HISTORY_FILE="${STATE_DIR}/history"
FAILED_IDS=()

# Output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_CYAN=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
fi

RESULT_ACTIONS=()

phase() {
  printf '\n%s== %s %s%s\n' "$C_CYAN" "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1} > 0 ? 60 - ${#1} : 0))))" "$C_RESET"
}

result() {
  local action="$1" id="$2" detail="${3:-}" colour=""
  case "$action" in
    installed|upgraded|ok)   colour="$C_GREEN" ;;
    would-install|would-upgrade) colour="$C_BLUE" ;;
    failed|broken)           colour="$C_RED" ;;
    missing|held|no-gui)     colour="$C_YELLOW" ;;
    *)                       colour="$C_DIM" ;;
  esac
  printf '  %s%-14s%s%-42s %s%s%s\n' \
    "$colour" "$action" "$C_RESET" "$id" "$C_DIM" "$detail" "$C_RESET"
  # What failed, not only how much of it: --status has to name the steps, and
  # by then the output has scrolled away or gone to a log nobody opened.
  [[ "$action" == "failed" || "$action" == "broken" ]] && FAILED_IDS+=("$id")
  RESULT_ACTIONS+=("$action")
}

# RUN_ABORT_MSG is what the EXIT trap writes into the run record: a run that
# died has no failed result to name, and "exit 1" on its own explains nothing.
RUN_ABORT_MSG=""
die() {
  RUN_ABORT_MSG="$*"
  printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

# Run state
#
# An unattended run is a run nobody watches: it writes to a log file under
# ~/Library/Logs and exits, and the one question worth answering afterwards -
# did last night's run work? - took reading the file to answer. Every real run
# now leaves one key=value record behind, written from the EXIT trap so a run
# that dies in preflight records that rather than leaving yesterday's success
# in place, and `--status` reads it back.
#
# Dry runs never write it: a dry run is a question, and it should not overwrite
# the record of the last real answer.

action_count() {   # action_count <action>
  local want="$1" a count=0
  for a in "${RESULT_ACTIONS[@]:-}"; do
    [[ "$a" == "$want" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

write_state() {   # write_state <exit-code>
  local rc="$1" finished counts='' failed='' action count f
  [[ "$RUN_RECORDING" == "yes" ]] || return 0
  [[ "$DRY_RUN" == "no" ]] || return 0

  finished="$(date +%s)"
  for action in installed upgraded failed missing skipped current present held no-gui; do
    count="$(action_count "$action")"
    [[ "$count" -gt 0 ]] && counts="${counts}${counts:+ }${action}=${count}"
  done
  # Comma-separated: an id can contain spaces ("tap: tflint - ...").
  for f in "${FAILED_IDS[@]:-}"; do
    [[ -z "$f" ]] && continue
    failed="${failed}${failed:+, }${f}"
  done

  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  {
    echo "version=$BOOTSTRAP_VERSION"
    echo "started=$RUN_STARTED_ISO"
    echo "finished_epoch=$finished"
    echo "duration_seconds=$(( finished - RUN_STARTED_EPOCH ))"
    echo "exit=$rc"
    echo "interactive=$RUN_INTERACTIVE"
    echo "failed='${failed//\'/}'"
    echo "counts='$counts'"
    echo "log=$RUN_LOG"
    echo "error='$(printf '%s' "${RUN_ABORT_MSG//\'/}" | tr '\n' ' ' | cut -c1-200)'"
    echo "changed='${RUN_CHANGED//\'/}'"
  } > "$STATE_FILE" 2>/dev/null || true

  append_history "$rc" "$finished" "$(( finished - RUN_STARTED_EPOCH ))"
  return 0
}

# One line per run, oldest first, so a week of unattended runs can be read at
# once. Bounded at 200 lines - eight months of nightly runs - because a file
# that grows forever is a file somebody eventually has to deal with.
append_history() {   # append_history <exit> <finished-epoch> <duration>
  local line tallies tmp
  tallies="$(action_count installed)/$(action_count upgraded)/$(action_count failed)"
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$2" "$1" "$3" "$RUN_INTERACTIVE" "$tallies" "${RUN_CHANGED:0:300}")"
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  if [[ -f "$HISTORY_FILE" ]]; then
    tmp="${HISTORY_FILE}.new"
    { tail -n 199 "$HISTORY_FILE"; printf '%s\n' "$line"; } > "$tmp" 2>/dev/null &&
      mv "$tmp" "$HISTORY_FILE"
  else
    printf '%s\n' "$line" > "$HISTORY_FILE" 2>/dev/null
  fi
  return 0
}

print_history() {
  local epoch code dur trigger tallies changed when verdict shown=0
  phase 'History'
  if [[ ! -r "$HISTORY_FILE" ]]; then
    result 'missing' 'history' "nothing recorded yet - $HISTORY_FILE"
    echo
    return 0
  fi
  [[ "$HISTORY_LINES" =~ ^[0-9]+$ ]] || HISTORY_LINES=10
  printf '  %s%-17s %-8s %-8s %-7s %s%s\n' \
    "$C_DIM" 'when' 'took' 'result' 'i/u/f' 'what moved' "$C_RESET"
  while IFS="$(printf '\t')" read -r epoch code dur trigger tallies changed; do
    [[ -z "$epoch" ]] && continue
    when="$(date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
    # An unattended run is the one worth spotting in a list of runs.
    [[ "$trigger" == "no" ]] && when="${when}*"
    if [[ "$code" == "0" ]]; then
      verdict='ok'; colour="$C_GREEN"
    else
      verdict="exit $code"; colour="$C_RED"
    fi
    # The colour goes around the padded field, not inside it: escape codes
    # count towards printf's width and the columns walk off to the right.
    printf '  %-17s %-8s %s%-8s%s %-7s %s%s%s\n' \
      "$when" "$(human_seconds "$dur")" "$colour" "$verdict" "$C_RESET" \
      "$tallies" "$C_DIM" "$changed" "$C_RESET"
    shown=$((shown + 1))
  done < <(tail -n "$HISTORY_LINES" "$HISTORY_FILE")
  printf '  %s%s run(s), * = unattended%s\n\n' "$C_DIM" "$shown" "$C_RESET"
  return 0
}

# Notification Center, and only for a run nobody was watching: an interactive
# run already printed the failures in red, and a banner on top of that is
# noise. osascript is silent and harmless where there is no GUI session to
# post into, an ssh login for instance, so the failure is ignored.
notify_failure() {   # notify_failure <exit-code>
  local rc="$1" body
  [[ "$rc" -ne 0 ]] || return 0
  [[ "$RUN_RECORDING" == "yes" ]] || return 0
  [[ "$DRY_RUN" == "no" ]] || return 0
  [[ "$RUN_INTERACTIVE" == "no" ]] || return 0
  [[ "${SCHEDULE_NOTIFY_ON_FAILURE:-no}" == "yes" ]] || return 0
  command -v osascript >/dev/null 2>&1 || return 0

  local n_failed subtitle
  n_failed="$(action_count failed)"
  if [[ "$n_failed" -gt 0 ]]; then
    subtitle="$n_failed step(s) failed"
    body="${RUN_LOG:-run bootstrap.sh --status}"
  else
    # No failed result to count: the run died rather than finishing badly.
    subtitle="aborted, exit $rc"
    body="${RUN_ABORT_MSG:-${RUN_LOG:-run bootstrap.sh --status}}"
  fi
  body="${body//\\/}"; body="${body//\"/}"
  subtitle="${subtitle//\\/}"; subtitle="${subtitle//\"/}"
  osascript -e "display notification \"${body}\" with title \"bootstrap-macos\" subtitle \"${subtitle}\"" \
    >/dev/null 2>&1 || true
  return 0
}

STATUS_RC=0
print_status() {
  local key value stamp ago dur trigger
  local s_version='' s_finished='' s_duration='' s_exit='' s_interactive='' \
        s_failed='' s_counts='' s_log='' s_error=''

  phase 'Last run'
  if [[ ! -r "$STATE_FILE" ]]; then
    result 'missing' 'last run' "nothing recorded yet - $STATE_FILE"
    echo
    return 0
  fi

  while IFS='=' read -r key value; do
    value="${value#\'}"; value="${value%\'}"
    case "$key" in
      version)          s_version="$value" ;;
      finished_epoch)   s_finished="$value" ;;
      duration_seconds) s_duration="$value" ;;
      exit)             s_exit="$value" ;;
      interactive)      s_interactive="$value" ;;
      failed)           s_failed="$value" ;;
      counts)           s_counts="$value" ;;
      log)              s_log="$value" ;;
      error)            s_error="$value" ;;
    esac
  done < "$STATE_FILE"

  stamp="$(date -r "${s_finished:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  ago="$(human_seconds $(( $(date +%s) - ${s_finished:-0} )) ) ago"
  dur="$(human_seconds "${s_duration:-0}")"
  trigger='a terminal'
  [[ "$s_interactive" == "no" ]] && trigger='unattended - the launchd agent, or output redirected'

  printf '  %-16s%s  %s(%s)%s\n' 'when' "$stamp" "$C_DIM" "$ago" "$C_RESET"
  printf '  %-16s%s\n' 'trigger' "$trigger"
  printf '  %-16s%s\n' 'version' "v${s_version:-?}"
  printf '  %-16s%s\n' 'duration' "$dur"
  if [[ "${s_exit:-1}" == "0" ]]; then
    printf '  %-16s%s%s%s\n' 'result' "$C_GREEN" 'clean - every step did what it said' "$C_RESET"
  else
    STATUS_RC=1
    printf '  %-16s%s%s%s\n' 'result' "$C_RED" "exit ${s_exit:-?}" "$C_RESET"
    [[ -n "$s_failed" ]] && printf '  %-16s%s%s%s\n' 'failed' "$C_YELLOW" "$s_failed" "$C_RESET"
    [[ -n "$s_error" ]] && printf '  %-16s%s%s%s\n' 'aborted' "$C_YELLOW" "$s_error" "$C_RESET"
  fi
  [[ -n "$s_counts" ]] && printf '  %-16s%s\n' 'counts' "$s_counts"
  [[ -n "$s_log" ]] && printf '  %-16s%s\n' 'log' "$s_log"
  echo
  return 0
}

human_seconds() {   # human_seconds <seconds>
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || { printf 'unknown'; return 0; }
  if   [[ "$s" -lt 60 ]];    then printf '%ss' "$s"
  elif [[ "$s" -lt 3600 ]];  then printf '%sm %ss' "$(( s / 60 ))" "$(( s % 60 ))"
  elif [[ "$s" -lt 86400 ]]; then printf '%sh %sm' "$(( s / 3600 ))" "$(( s % 3600 / 60 ))"
  else printf '%sd %sh' "$(( s / 86400 ))" "$(( s % 86400 / 3600 ))"
  fi
  return 0
}

# Temp files and directories
#
# Every temp path goes through mktemp_tracked, which remembers it so an
# interrupted run cleans up after itself. Without this a Ctrl-C between the
# mktemp and the mv left the half-written file behind: ~/.zshrc.bootstrap.XXXXXX
# and friends accumulated in $HOME, looking enough like config to confuse.
# Paths that were moved into place are gone by the time cleanup runs, and
# rm -f on a missing path is a no-op, so tracking every one is safe.
BOOTSTRAP_TMP=()

# Assigns to the variable named in $1 rather than printing: a command
# substitution would run the append in a subshell and the parent would forget
# the path, which is the whole point of tracking it.
mktemp_tracked() {   # mktemp_tracked <varname> [mktemp args...]
  local _var="$1"; shift
  local _t
  _t="$(mktemp "$@")" || return 1
  BOOTSTRAP_TMP+=("$_t")
  printf -v "$_var" '%s' "$_t"
}

cleanup_tmp() {
  local _t
  # Guarded expansion: bash 3.2 under set -u calls an empty array unbound.
  for _t in ${BOOTSTRAP_TMP[@]+"${BOOTSTRAP_TMP[@]}"}; do
    [[ -n "$_t" ]] && rm -rf "$_t" 2>/dev/null
  done
  return 0
}

# EXIT covers a normal end and a die; INT and TERM re-exit with the signal's
# conventional status, which fires the EXIT trap in turn - cleanup_tmp is
# idempotent, so running twice costs nothing.
on_exit() {
  local rc=$?
  cleanup_tmp
  write_state "$rc" || true
  notify_failure "$rc" || true
  return 0
}

trap on_exit EXIT
trap 'cleanup_tmp; exit 130' INT
trap 'cleanup_tmp; exit 143' TERM


# GitHub's unauthenticated API allows 60 requests/hour per source IP - shared
# with anything else on the same address hitting api.github.com that hour.
# An authenticated request gets 5000/hour. GITHUB_TOKEN/GH_TOKEN (what `gh`
# itself reads) needs nothing new set if either is already exported;
# `gh auth token` is tried next, if the CLI is installed and logged in - a
# local, no-network read of its stored credential. Empty when neither is
# available, same as today.
#
# Computed once, here, rather than lazily inside github_latest_tag: that
# function is always called as `x="$(github_latest_tag ...)"`, which runs it
# in a subshell, and a subshell's writes to a global never reach back out -
# lazy memoization there would silently redo this, `gh auth token` included,
# on every single tool.
GITHUB_AUTH_HEADER=''
_github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [[ -z "$_github_token" ]] && command -v gh >/dev/null 2>&1; then
  _github_token="$(gh auth token 2>/dev/null || true)"
fi
[[ -n "$_github_token" ]] && GITHUB_AUTH_HEADER="Authorization: Bearer $_github_token"
unset _github_token

github_latest_tag() {   # github_latest_tag <owner/repo>
  local -a auth=()
  [[ -n "$GITHUB_AUTH_HEADER" ]] && auth=(-H "$GITHUB_AUTH_HEADER")
  curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true
}

# Compares the checkout's own tag against its GitHub origin's latest release -
# not BOOTSTRAP_VERSION, which is this script's own number and never lines up
# with the vYYYY.MM.DD bundle tag. Silent whenever it can't be sure: no git
# checkout (a release tarball), no GitHub origin (a fork hosted elsewhere), no
# tags, or no network - this never blocks or fails the run over it.
check_bootstrap_update() {
  [[ "$SKIP_UPDATE_CHECK" == yes ]] && return 0
  git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local origin_url repo_slug local_tag remote_tag
  origin_url="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
  repo_slug="$(printf '%s' "${origin_url%.git}" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p')"
  [[ -n "$repo_slug" ]] || return 0

  local_tag="$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
  [[ -n "$local_tag" ]] || return 0

  remote_tag="$(github_latest_tag "$repo_slug")"
  [[ -n "$remote_tag" && "$remote_tag" != "$local_tag" ]] || return 0

  printf '  %-16s%s%s available (you have %s)%s - https://github.com/%s/releases/tag/%s\n' \
    'update' "$C_YELLOW" "$remote_tag" "$local_tag" "$C_RESET" "$repo_slug" "$remote_tag"
}

# Which Mac is this?
detect_arch() {
  local machine translated
  machine="$(uname -m)"
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"

  if [[ "$machine" == "arm64" ]]; then
    ARCH=arm64
    ARCH_NOTE="Apple silicon"
  elif [[ "$translated" == "1" ]]; then
    ARCH=arm64
    ARCH_NOTE="Apple silicon, seen through Rosetta"
  else
    ARCH=x86_64
    ARCH_NOTE="Intel"
  fi

  if [[ "$ARCH" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
  else
    BREW_PREFIX="/usr/local"
  fi
}

# Package state

# brew's own words about what just went wrong. Every brew call here sends its
# output to BREW_LOG rather than /dev/null: 'failed - brew install failed' is
# no use in a log file nobody was watching, which is every run the launchd
# agent makes. The Error: line if there is one, the last line otherwise.
brew_error() {   # brew_error <logfile>
  local line
  line="$(grep -m1 '^Error:' "$1" 2>/dev/null || true)"
  [[ -n "$line" ]] || line="$(grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 || true)"
  line="${line#Error: }"
  line="$(tr -d '\r' <<< "$line")"
  [[ "${#line}" -gt 90 ]] && line="${line:0:87}..."
  printf '%s' "${line:-no output}"
}

brew_formula_installed() {
  "$BREW" list --formula --versions "$1" >/dev/null 2>&1
}

brew_cask_installed() {
  "$BREW" list --cask --versions "$1" >/dev/null 2>&1
}

brew_formula_available() {
  "$BREW" info --formula "$1" >/dev/null 2>&1
}

brew_formula_version() {
  "$BREW" list --formula --versions "$1" 2>/dev/null | awk '{print $2}' || true
}

brew_cask_version() {
  "$BREW" list --cask --versions "$1" 2>/dev/null | awk '{print $2}' || true
}

# Arguments

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh [options]

  --dry-run          Show what would change, touch nothing.
  --groups a,b       Limit to named groups. Default is every group.
  --list-groups      Print the groups in the manifest and exit.
  --list-packages    Print every package name in every group and exit - for
                     when you know something is in here somewhere but not
                     which group.
  --status           Print what the last real run did and exit. Exits 1 if
                     that run failed, so a check can use it.
  --history[=n]      Print the last n runs (default 10) and what each one
                     moved, and exit.
  --doctor           Check what a login shell actually sees - tools on PATH,
                     shell integration, config drift, the agent - and exit.
                     Changes nothing. Exits 1 if something is wrong.
  --skip-upgrade     Install what is missing, leave installed versions alone.
  --skip-cask-upgrade
                     Upgrade formulae but not casks. What the launchd agent
                     passes: a cask that wants an admin password cannot ask
                     for one from an unattended run.
  --skip-cleanup     Leave stale downloads and superseded versions on disk.
  --skip-schedule    Leave the launchd agent alone.
  --skip-vscode-extensions
                     Install none of the VS Code extensions in the manifest.
  --skip-update-check
                     Don't check the GitHub origin for a newer release tag.
  --gui / --no-gui   Whether to install groups that need a desktop. Default is
                     --gui; use --no-gui on a headless build agent.
  --version          Print the version and exit.
  -h, --help         This text.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=yes ;;
    --skip-upgrade) SKIP_UPGRADE=yes ;;
    --skip-cask-upgrade) SKIP_CASK_UPGRADE=yes ;;
    --skip-cleanup) SKIP_CLEANUP=yes ;;
    --skip-schedule) SKIP_SCHEDULE=yes ;;
    --skip-vscode-extensions) SKIP_VSCODE_EXT=yes ;;
    --skip-update-check) SKIP_UPDATE_CHECK=yes ;;
    --gui)          GUI_OVERRIDE=yes ;;
    --no-gui)       GUI_OVERRIDE=no ;;
    --groups)       shift; ONLY_GROUPS="${1:-}" ;;
    --groups=*)     ONLY_GROUPS="${1#*=}" ;;
    --list-groups)  LIST_GROUPS=yes ;;
    --list-packages) LIST_PACKAGES=yes ;;
    --status)       STATUS_ONLY=yes ;;
    --doctor)       DOCTOR_ONLY=yes ;;
    --history)      HISTORY_ONLY=yes ;;
    --history=*)    HISTORY_ONLY=yes; HISTORY_LINES="${1#*=}" ;;
    --version)      echo "$BOOTSTRAP_VERSION"; exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

if [[ "$STATUS_ONLY" == "yes" ]]; then
  print_status
  exit "$STATUS_RC"
fi

if [[ "$HISTORY_ONLY" == "yes" ]]; then
  print_history
  exit 0
fi

# Arrays, the bash 3.2 way
group_array() {   # group_array <dest> <source-array-name>
  eval "$1=()"
  declare -p "$2" >/dev/null 2>&1 || return 0
  eval "if (( \${#$2[@]} )); then $1=(\"\${$2[@]}\"); fi"
}

# The cli group's package -> command mapping, from the table CI enforces.
# Loaded by the zsh fragment (for the `tools` function) and by the doctor (to
# know which binary a package is supposed to put on PATH).
load_parity_table() {
  _parity_pkg=() _parity_cmd=() _parity_desc=()
  [[ -r "$SCRIPT_DIR/../tools/cli-parity.conf" ]] || return 0
  local _pty_can _pty_lx _pty_mac _pty_win _pty_note _pty_cmd _pty_desc
  while IFS='|' read -r _pty_can _pty_lx _pty_mac _pty_win _pty_note _pty_cmd _pty_desc; do
    _pty_can="$(printf '%s' "$_pty_can" | tr -d '[:space:]')"
    [[ -z "$_pty_can" || "$_pty_can" == \#* ]] && continue
    _pty_mac="$(printf '%s' "$_pty_mac" | tr -d '[:space:]')"
    [[ -z "$_pty_mac" || "$_pty_mac" == '-' ]] && continue
    _pty_cmd="$(printf '%s' "$_pty_cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _pty_desc="$(printf '%s' "$_pty_desc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    _parity_pkg+=("$_pty_mac")
    _parity_cmd+=("$_pty_cmd")
    _parity_desc+=("$_pty_desc")
  done < "$SCRIPT_DIR/../tools/cli-parity.conf"
  return 0
}

parity_row() {    # parity_row <package>
  local i
  _row_cmd='' _row_desc=''
  for (( i = 0; i < ${#_parity_pkg[@]}; i++ )); do
    [[ "${_parity_pkg[$i]}" == "$1" ]] || continue
    _row_cmd="${_parity_cmd[$i]}"
    _row_desc="${_parity_desc[$i]}"
    break
  done
  [[ -n "$_row_cmd" ]]
}

# Manifest

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
# shellcheck source=packages.conf
source "$MANIFEST"

for required in PKG_GROUPS MANUAL HELD TOOLS TAPS \
                ZSH_ENABLED VSCODE_EXTENSIONS \
                GHOSTTY_ENABLED SCHEDULE_ENABLED HISTORY_SIZE HISTORY_FILE_SIZE; do
  declare -p "$required" >/dev/null 2>&1 || die "manifest is missing \$$required: $MANIFEST"
done

if [[ "${LIST_GROUPS:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    desc_var="GROUP_${g}_DESC"
    gui_var="GROUP_${g}_GUI"
    group_array _form "GROUP_${g}_FORMULA"
    group_array _cask "GROUP_${g}_CASK"
    total=$(( ${#_form[@]} + ${#_cask[@]} ))
    gui_tag='               '
    [[ "${!gui_var:-no}" == "yes" ]] && gui_tag='[needs desktop]'
    printf '  %s%-10s%s %-3s packages  %s%s%s  %s\n' \
      "$C_CYAN" "$g" "$C_RESET" "$total" "$C_DIM" "$gui_tag" "$C_RESET" "${!desc_var}"
    unset _form _cask
  done
  echo
  exit 0
fi

if [[ "${LIST_PACKAGES:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    printf '  %s%s%s\n' "$C_CYAN" "$g" "$C_RESET"
    group_array _form "GROUP_${g}_FORMULA"
    group_array _cask "GROUP_${g}_CASK"
    for pkg in "${_form[@]:-}" "${_cask[@]:-}"; do
      [[ -z "$pkg" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$pkg" "$C_RESET"
    done
    unset _form _cask
  done
  if [[ "${#VSCODE_EXTENSIONS[@]}" -gt 0 ]]; then
    printf '  %sVS Code extensions%s\n' "$C_CYAN" "$C_RESET"
    for ext in "${VSCODE_EXTENSIONS[@]:-}"; do
      [[ -z "$ext" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$ext" "$C_RESET"
    done
  fi
  echo
  exit 0
fi

# Doctor
#
# Every other phase asserts that a package is installed. This one asserts that
# it is in *effect*, which is not the same thing and is where the bugs have
# been: ~/go/bin missing from PATH, an apt fd-find shadowing the real fd, the
# mise shims not reaching a login shell, starship's format never applied, Tab
# never getting to fzf-tab. Every one of those was found months later by
# somebody noticing, because a run that installs a package has no idea whether
# the shell you actually type into can see it.
#
# So the checks that matter run inside a real login shell - zsh -lic - which is
# the environment they are about. One probe emitting every fact at once, in
# about a second; a shell per check would take a minute and tell you the same
# thing.
#
# It reports and never fixes. The fix is bootstrap.sh itself.

DOCTOR_OK=0
DOCTOR_BROKEN=0
DOCTOR_PROBE_OUT=''

doctor_ok()     { DOCTOR_OK=$((DOCTOR_OK + 1)); result 'ok' "$1" "${2:-}"; }
doctor_broken() { DOCTOR_BROKEN=$((DOCTOR_BROKEN + 1)); result 'broken' "$1" "${2:-}"; }
doctor_note()   { result 'present' "$1" "${2:-}"; }

probe_get() {   # probe_get <key>
  printf '%s\n' "$DOCTOR_PROBE_OUT" | sed -n "s|^$1=||p" | head -1
}

# The command a package is supposed to put on PATH. The parity table's cmd
# column is written for a reader, so two rows need saying differently here:
# zoxide's entry is the `z` function it defines rather than its binary, and
# 7zip's names all three platforms' binaries in one cell.
doctor_command_for() {   # doctor_command_for <package>
  case "$1" in
    zoxide)   printf 'zoxide' ;;
    sevenzip) printf '7zz' ;;
    *)
      parity_row "$1" || return 1
      printf '%s' "${_row_cmd%% *}"
      ;;
  esac
}

doctor_probe() {
  local probe cmds pkg cmd
  cmds=''
  for pkg in "${_doctor_pkgs[@]:-}"; do
    [[ -z "$pkg" ]] && continue
    cmd="$(doctor_command_for "$pkg")" || continue
    cmds="$cmds $cmd"
  done
  # Not in the cli parity table, but just as load-bearing.
  cmds="$cmds brew starship atuin carapace mise git gh node go java kubectl code"

  mktemp_tracked probe "${TMPDIR:-/tmp}/bootstrap-probe.XXXXXX"
  {
    printf 'for c in%s; do print -r -- "resolve:$c=${commands[$c]:-}"; done\n' "$cmds"
    cat <<'PROBE'
print -r -- "env:starship=${STARSHIP_SESSION_KEY:+yes}"
print -r -- "env:JAVA_HOME=${JAVA_HOME:-}"
print -r -- "env:PATH=${PATH}"
print -r -- "widget:atuin=$(( $+widgets[atuin-search] ))"
print -r -- "widget:hss=$(( $+widgets[history-substring-search-up] ))"
print -r -- "fn:fzf-tab=$(( $+functions[fzf-tab-complete] ))"
print -r -- "fn:carapace=$(( $+functions[_carapace_completer] ))"
print -r -- "fn:zoxide=$(( $+functions[__zoxide_z] ))"
print -r -- "fn:compdef=$(( $+functions[compdef] ))"
print -r -- "bind:tab=$(bindkey '^I' 2>/dev/null | head -1)"
print -r -- "bind:up=$(bindkey '^[[A' 2>/dev/null | head -1)"
print -r -- "alias:cat=${aliases[cat]:-}"
print -r -- "alias:ls=${aliases[ls]:-}"
print -r -- "alias:make=${aliases[make]:-}"
PROBE
  } > "$probe"

  # A login shell runs the user's own .zshrc, which can do anything including
  # fail; the probe's own lines are what matters, and stderr is not.
  DOCTOR_PROBE_OUT="$(zsh -lic "source '$probe'" 2>/dev/null || true)"
  [[ -n "$DOCTOR_PROBE_OUT" ]]
}

doctor_check_tools() {
  local pkg cmd path want shims
  shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
  for pkg in "${_doctor_pkgs[@]:-}"; do
    [[ -z "$pkg" ]] && continue
    cmd="$(doctor_command_for "$pkg")" || continue
    path="$(probe_get "resolve:$cmd")"
    want="${BREW_PREFIX}/bin/${cmd}"
    if [[ -z "$path" ]]; then
      if brew_formula_installed "$pkg"; then
        doctor_broken "$cmd" "installed as $pkg, but a login shell cannot find it"
      else
        doctor_broken "$cmd" "not installed, and not on PATH"
      fi
    elif [[ "$path" == "$shims"/* ]]; then
      # A mise shim in front of the brew binary runs the same program through
      # one more exec, so it is not broken - but a shim for a tool mise does
      # not manage is a leftover, and worth seeing.
      doctor_note "$cmd" "a mise shim answers first, ahead of $want"
    elif [[ "$path" != "$want" ]]; then
      doctor_broken "$cmd" "resolves to $path, not the $pkg at $want"
    else
      doctor_ok "$cmd" "$path"
    fi
  done
}

doctor_check_shell() {
  local v
  if [[ "${ZSH_ENABLED:-no}" != "yes" ]]; then
    doctor_note 'zsh integration' 'ZSH_ENABLED is not yes - nothing to check'
    return 0
  fi

  [[ -f "${HOME}/.zshrc.bootstrap" ]] \
    && doctor_ok 'managed fragment' "${HOME}/.zshrc.bootstrap" \
    || doctor_broken 'managed fragment' "${HOME}/.zshrc.bootstrap does not exist"

  if grep -qF '.zshrc.bootstrap' "${HOME}/.zshrc" 2>/dev/null; then
    doctor_ok 'fragment is sourced' '.zshrc has the source line'
  else
    doctor_broken 'fragment is sourced' 'nothing in ~/.zshrc sources it, so none of it is in effect'
  fi

  [[ "$(probe_get 'env:starship')" == 'yes' ]] \
    && doctor_ok 'starship' 'initialised - STARSHIP_SESSION_KEY is set' \
    || doctor_broken 'starship' 'not initialised in a login shell'

  v="$(probe_get 'widget:atuin')"
  [[ "$v" == '1' ]] \
    && doctor_ok 'atuin' 'the atuin-search widget exists' \
    || doctor_broken 'atuin' 'no atuin-search widget - Ctrl-R is not atuin'

  v="$(probe_get 'bind:up')"
  case "$v" in
    *history-substring-search-up*) doctor_ok 'history-substring-search' 'bound to the up arrow' ;;
    *) doctor_broken 'history-substring-search' "the up arrow runs ${v:-nothing}" ;;
  esac

  v="$(probe_get 'bind:tab')"
  case "$v" in
    *fzf-tab-complete*) doctor_ok 'fzf-tab' 'bound to Tab' ;;
    *) doctor_broken 'fzf-tab' "Tab runs ${v:-nothing}, not fzf-tab-complete" ;;
  esac

  # carapace 1.7+ defines _carapace_completer, not _carapace - the fragment
  # registers it with `compdef _carapace_completer <every command it covers>`.
  [[ "$(probe_get 'fn:carapace')" == '1' ]] \
    && doctor_ok 'carapace' 'the _carapace_completer completer is defined' \
    || doctor_broken 'carapace' 'not initialised in a login shell'

  [[ "$(probe_get 'fn:zoxide')" == '1' ]] \
    && doctor_ok 'zoxide' 'z is defined' \
    || doctor_broken 'zoxide' 'z is not defined - zoxide never initialised'

  [[ "$(probe_get 'fn:compdef')" == '1' ]] \
    && doctor_ok 'completion' 'compinit has run' \
    || doctor_broken 'completion' 'compdef is not defined - completion never initialised'

  for v in cat ls make; do
    if [[ -n "$(probe_get "alias:$v")" ]]; then
      doctor_ok "alias $v" "$(probe_get "alias:$v")"
    else
      doctor_broken "alias $v" 'not aliased - the fragment did not reach this shell'
    fi
  done
}

doctor_check_runtimes() {
  local tool path mise_root
  mise_root="${XDG_DATA_HOME:-$HOME/.local/share}/mise"
  for tool in node go java; do
    path="$(probe_get "resolve:$tool")"
    if [[ -z "$path" ]]; then
      doctor_broken "$tool" 'not on PATH in a login shell'
    elif [[ "$path" == "$mise_root"/* ]]; then
      doctor_ok "$tool" "$path"
    else
      doctor_broken "$tool" "resolves to $path, not the mise install under $mise_root"
    fi
  done

  path="$(probe_get 'env:JAVA_HOME')"
  if [[ -z "$path" ]]; then
    doctor_broken 'JAVA_HOME' 'unset - Gradle, Maven and the IDEs that read it will not find the JDK'
  elif [[ "$path" == "$mise_root"/* ]]; then
    doctor_ok 'JAVA_HOME' "$path"
  else
    doctor_note 'JAVA_HOME' "$path - not the mise JDK, which may be deliberate"
  fi

  path="$(probe_get 'env:PATH')"
  case ":$path:" in
    *":${HOME}/.local/bin:"*) doctor_ok 'PATH ~/.local/bin' 'present' ;;
    *) doctor_broken 'PATH ~/.local/bin' 'missing - uv tools and release binaries live there' ;;
  esac
  case ":$path:" in
    *":${HOME}/go/bin:"*) doctor_ok 'PATH ~/go/bin' 'present' ;;
    *) doctor_broken 'PATH ~/go/bin' 'missing - gopls, dlv and staticcheck land there' ;;
  esac
  case ":$path:" in
    *":${BREW_PREFIX}/bin:"*) doctor_ok 'PATH brew prefix' "${BREW_PREFIX}/bin" ;;
    *) doctor_broken 'PATH brew prefix' "${BREW_PREFIX}/bin is not on a login shell's PATH" ;;
  esac
}

# Config this script deploys by copying: if the copy has drifted, a later run
# will replace it, so the honest verdict is "differs", not "broken".
doctor_config() {   # doctor_config <label> <repo copy> <deployed path>
  local label="$1" src="$2" dst="$3"
  if [[ ! -r "$dst" ]]; then
    doctor_broken "$label" "not deployed at $dst"
  elif [[ ! -r "$src" ]]; then
    doctor_note "$label" "deployed, but the repo copy is missing at $src"
  elif cmp -s "$src" "$dst"; then
    doctor_ok "$label" "$dst"
  else
    doctor_note "$label" "$dst differs from the repo - the next run would replace it"
  fi
}

doctor_check_configs() {
  local bat_cfg
  doctor_config 'starship.toml' "${SCRIPT_DIR}/../starship.toml" "${HOME}/.config/starship.toml"
  doctor_config 'atuin config' "${SCRIPT_DIR}/../atuin/config.toml" "${HOME}/.config/atuin/config.toml"

  if bat_cfg="$(bat --config-dir 2>/dev/null)" && [[ -n "$bat_cfg" ]]; then
    doctor_config 'bat config' "${SCRIPT_DIR}/../bat/config" "${bat_cfg}/config"
    doctor_config 'bat theme' "${SCRIPT_DIR}/../bat/themes/Catppuccin Mocha.tmTheme" \
                  "${bat_cfg}/themes/Catppuccin Mocha.tmTheme"
  else
    doctor_broken 'bat config' 'bat is not installed, so nothing reads the theme'
  fi

  if [[ "${GHOSTTY_ENABLED:-no}" == "yes" ]]; then
    [[ -r "${HOME}/.config/ghostty/config" ]] \
      && doctor_ok 'ghostty config' "${HOME}/.config/ghostty/config" \
      || doctor_broken 'ghostty config' 'not deployed'
  fi
}

doctor_check_schedule() {
  local label
  label="${SCHEDULE_LABEL:-com.github.bootstrap.macos}"
  if [[ "${SCHEDULE_ENABLED:-no}" != "yes" ]]; then
    doctor_note 'launchd agent' 'SCHEDULE_ENABLED is not yes'
  elif [[ ! -f "${HOME}/Library/LaunchAgents/${label}.plist" ]]; then
    doctor_broken 'launchd agent' 'no plist - the daily run has never been installed'
  elif launchctl list "$label" >/dev/null 2>&1; then
    doctor_ok 'launchd agent' "$label is loaded"
  else
    doctor_broken 'launchd agent' "$label has a plist but is not loaded"
  fi
}

run_doctor() {
  group_array _doctor_pkgs "GROUP_cli_FORMULA"
  load_parity_table

  phase 'Doctor - what a login shell actually sees'
  if ! command -v zsh >/dev/null 2>&1; then
    result 'failed' 'login shell' 'no zsh to probe with'
    return 1
  fi
  if ! doctor_probe; then
    result 'failed' 'login shell' 'zsh -lic produced nothing - the probe could not run'
    return 1
  fi
  doctor_ok 'login shell' "zsh $(zsh --version 2>/dev/null | awk '{print $2}') - probed in one pass"

  phase 'Doctor - the cli group on PATH'
  doctor_check_tools

  phase 'Doctor - shell integration'
  doctor_check_shell

  phase 'Doctor - runtimes and PATH'
  doctor_check_runtimes

  phase 'Doctor - deployed config'
  doctor_check_configs

  phase 'Doctor - the daily run'
  doctor_check_schedule

  phase 'Doctor summary'
  printf '  %-16s%s%s%s\n' 'ok' "$C_GREEN" "$DOCTOR_OK" "$C_RESET"
  if [[ "$DOCTOR_BROKEN" -gt 0 ]]; then
    printf '  %-16s%s%s%s\n' 'broken' "$C_RED" "$DOCTOR_BROKEN" "$C_RESET"
    printf '\n  %sRun ./bootstrap.sh to fix what it can.%s\n\n' "$C_DIM" "$C_RESET"
    return 1
  fi
  printf '\n  %sEverything the manifest promises is in effect.%s\n\n' "$C_DIM" "$C_RESET"
  return 0
}

# Preflight
#
# Past this line the run counts: the EXIT trap records what happened, whether
# it gets to the summary or dies in the middle.

[[ "$DOCTOR_ONLY" == "yes" ]] || RUN_RECORDING=yes

phase 'Preflight'

[[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS (uname says $(uname -s))"

[[ "$(id -u)" -ne 0 ]] || die "do not run this with sudo - Homebrew refuses to run as root, and it would leave root-owned files in your home directory"

detect_arch

printf '  %-16s%s\n' 'bootstrap' "v$BOOTSTRAP_VERSION"
printf '  %-16s%s\n' 'macOS' "$(sw_vers -productVersion 2>/dev/null || echo unknown) ($(sw_vers -buildVersion 2>/dev/null || echo '?'))"
printf '  %-16s%s  %s(%s)%s\n' 'arch' "$ARCH" "$C_DIM" "$ARCH_NOTE" "$C_RESET"
printf '  %-16s%s\n' 'user' "$(id -un) (uid $(id -u))"
check_bootstrap_update

if [[ "$ARCH_NOTE" == *Rosetta* ]]; then
  printf '  %-16s%sthis shell is running under Rosetta - targeting the native prefix anyway%s\n' \
    'note' "$C_YELLOW" "$C_RESET"
fi

if [[ "$GUI_OVERRIDE" == "auto" ]]; then
  HAS_GUI=yes
  GUI_NOTE="every Mac has one; pass --no-gui for a headless agent"
else
  HAS_GUI="$GUI_OVERRIDE"
  GUI_NOTE="forced with --gui"
  [[ "$GUI_OVERRIDE" == "no" ]] && GUI_NOTE="forced with --no-gui"
fi

if [[ "$HAS_GUI" == "yes" ]]; then
  printf '  %-16s%syes%s  %s(%s)%s\n' 'desktop apps' "$C_GREEN" "$C_RESET" "$C_DIM" "$GUI_NOTE" "$C_RESET"
else
  printf '  %-16s%sno%s   %s(%s)%s\n' 'desktop apps' "$C_YELLOW" "$C_RESET" "$C_DIM" "$GUI_NOTE" "$C_RESET"
  printf '  %-16s%s%s%s\n' '' "$C_DIM" 'groups needing a desktop will be skipped' "$C_RESET"
fi

[[ "$DRY_RUN" == "yes" ]] && printf '  %-16s%s%s%s\n' 'mode' "$C_BLUE" 'dry run - nothing will change' "$C_RESET"

CLT_PRESENT=no
if xcode-select -p >/dev/null 2>&1; then
  CLT_PRESENT=yes
  printf '  %-16s%s%s%s\n' 'xcode CLT' "$C_DIM" "$(xcode-select -p)" "$C_RESET"
else
  printf '  %-16s%s%s%s\n' 'xcode CLT' "$C_YELLOW" 'not installed' "$C_RESET"
fi

BREW="${BREW_PREFIX}/bin/brew"

# Reused by every brew call below rather than one temp file per package: the
# calls are sequential, so the previous command's output is never wanted again.
mktemp_tracked BREW_LOG "${TMPDIR:-/tmp}/bootstrap-brew.XXXXXX"

if [[ ! -x "$BREW" ]]; then
  if command -v brew >/dev/null 2>&1; then
    FOUND="$(command -v brew)"
    result 'present' 'homebrew' "$FOUND (not the ${ARCH} prefix ${BREW_PREFIX})"
    BREW="$FOUND"
    BREW_PREFIX="$("$BREW" --prefix)"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'homebrew' "$BREW_PREFIX"
  else
    if [[ "$CLT_PRESENT" == "no" ]]; then
      printf '  %s%s%s\n' "$C_DIM" 'Homebrew will install the Command Line Tools first; this takes a while.' "$C_RESET"
    fi
    if NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)" >/dev/null 2>&1 \
        && [[ -x "$BREW" ]]; then
      result 'installed' 'homebrew' "$BREW_PREFIX"
    else
      die "Homebrew install failed. Run it by hand and read the output: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/brew/HEAD/install.sh)\""
    fi
  fi
else
  result 'current' 'homebrew' "$BREW_PREFIX"
fi

if [[ ! -x "$BREW" && "$DRY_RUN" == "no" ]]; then
  die "no usable brew at $BREW"
fi

if [[ -x "$BREW" ]]; then
  eval "$("$BREW" shellenv)"
fi

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

# The doctor asks the machine questions and changes nothing, so it runs here -
# after the prefix and brew are known, before the index refresh it does not
# need and the phases it is not going to run.
if [[ "$DOCTOR_ONLY" == "yes" ]]; then
  run_doctor
  exit $?
fi

if [[ "$DRY_RUN" == "no" && -x "$BREW" ]]; then
  printf '  %-16s' 'brew index'
  if "$BREW" update --quiet >/dev/null 2>&1; then
    printf '%supdated%s\n' "$C_DIM" "$C_RESET"
  else
    printf '%scould not refresh - continuing with what is cached%s\n' "$C_YELLOW" "$C_RESET"
  fi
fi

# Held

for entry in "${HELD[@]:-}"; do
  [[ -z "$entry" ]] && continue
  result 'held' "${entry%%:*}" "${entry#*:}"
done

# Taps

phase 'Taps - third-party Homebrew repositories'

if [[ "${#TAPS[@]}" -eq 0 ]]; then
  printf '  %s%s%s\n' "$C_DIM" 'none in the manifest - everything comes from homebrew/core and homebrew/cask' "$C_RESET"
else
  TAPPED="$("$BREW" tap 2>/dev/null || true)"
  for entry in "${TAPS[@]:-}"; do
    [[ -z "$entry" ]] && continue
    tap_name="${entry%%:*}"
    tap_desc="${entry#*:}"
    if printf '%s\n' "$TAPPED" | grep -qxF "$tap_name"; then
      result 'current' "tap: $tap_desc" "$tap_name"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' "tap: $tap_desc" "$tap_name"
    elif "$BREW" tap "$tap_name" >"$BREW_LOG" 2>&1; then
      result 'installed' "tap: $tap_desc" "$tap_name"
    else
      result 'failed' "tap: $tap_desc" "brew tap $tap_name: $(brew_error "$BREW_LOG")"
    fi
  done
fi

# Packages

selected=("${PKG_GROUPS[@]}")
if [[ -n "$ONLY_GROUPS" ]]; then
  IFS=',' read -r -a selected <<< "$ONLY_GROUPS"
  for g in "${selected[@]}"; do
    printf '%s\n' "${PKG_GROUPS[@]}" | grep -qx "$g" || die "unknown group: $g (try --list-groups)"
  done
fi

# What the machine has, name and version, one per line. Both lists, because the
# same name can be a formula and a cask and `brew list` alone would merge them.
#
# Each listing runs separately and each is allowed to fail. A listing that
# fails prints nothing at all rather than a shorter list, so taking the two
# together meant losing both - and under `set -e` a snapshot taken for the
# history could end the run before it installed anything, which is what it did
# on the machine this was written on.
pkg_snapshot() {   # pkg_snapshot <file>
  {
    "$BREW" list --formula --versions 2>/dev/null || true
    "$BREW" list --cask --versions 2>/dev/null || true
  } | awk 'NF >= 2 { print $1, $NF }' | sort > "$1" || true
  return 0
}

snapshot_before() {
  [[ "$DRY_RUN" == "no" && -x "$BREW" ]] || return 0
  mktemp_tracked SNAP_BEFORE "${TMPDIR:-/tmp}/bootstrap-before.XXXXXX"
  pkg_snapshot "$SNAP_BEFORE"
  return 0
}

# Everything that moved between the two snapshots, which is what an upgrade
# actually did as opposed to what it said while scrolling past.
snapshot_after() {
  local snap_after
  [[ -n "$SNAP_BEFORE" && -r "$SNAP_BEFORE" ]] || return 0
  mktemp_tracked snap_after "${TMPDIR:-/tmp}/bootstrap-after.XXXXXX"
  pkg_snapshot "$snap_after"
  RUN_CHANGED="$(awk '
    NR == FNR { before[$1] = $2; next }
    {
      if (!($1 in before)) { printf "+%s %s, ", $1, $2 }
      else if (before[$1] != $2) { printf "%s %s>%s, ", $1, before[$1], $2 }
    }
  ' "$SNAP_BEFORE" "$snap_after" 2>/dev/null | sed 's/, $//' || true)"
  [[ -n "$RUN_CHANGED" ]] && result 'present' 'versions moved' "$RUN_CHANGED"
  return 0
}

snapshot_before

install_formula() {
  local pkg="$1"
  if brew_formula_installed "$pkg"; then
    local version
    version="$(brew_formula_version "$pkg")"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$pkg" "$version"
      return
    fi
    result 'current' "$pkg" "$version"
    return
  fi
  if ! brew_formula_available "$pkg"; then
    result 'missing' "$pkg" 'no such formula - renamed, or gone from the tap'
    return
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$pkg" 'formula'
    return
  fi
  if "$BREW" install --formula "$pkg" >"$BREW_LOG" 2>&1; then
    result 'installed' "$pkg" "$(brew_formula_version "$pkg")"
  else
    result 'failed' "$pkg" "brew install: $(brew_error "$BREW_LOG")"
  fi
}

install_cask() {
  local token="$1"
  if brew_cask_installed "$token"; then
    local version
    version="$(brew_cask_version "$token")"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$token" "$version"
    else
      result 'current' "$token" "$version"
    fi
    return
  fi

  local json
  if ! json="$("$BREW" info --cask --json=v2 "$token" 2>/dev/null)"; then
    result 'missing' "$token" 'no such cask - tokens get renamed, check brew search'
    return
  fi

  local appname
  # shellcheck disable=SC2001
  appname="$(sed 's/.*"artifacts"//' <<< "$json" | grep -o '"[^"]*\.app"' | head -1 | tr -d '"' || true)"
  if [[ -n "$appname" && -d "/Applications/${appname}" ]]; then
    result 'present' "$token" "/Applications/${appname} - installed by something else"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$token" 'cask'
    return
  fi
  if "$BREW" install --cask "$token" >"$BREW_LOG" 2>&1; then
    result 'installed' "$token" "$(brew_cask_version "$token")"
  else
    result 'failed' "$token" "brew install --cask: $(brew_error "$BREW_LOG")"
  fi
}

for group in "${selected[@]}"; do
  desc_var="GROUP_${group}_DESC"
  gui_var="GROUP_${group}_GUI"
  needs_gui="${!gui_var:-no}"

  phase "$group - ${!desc_var}"

  if [[ "$needs_gui" == "yes" && "$HAS_GUI" != "yes" ]]; then
    eval "pkgs=(\"\${GROUP_${group}_FORMULA[@]:-}\" \"\${GROUP_${group}_CASK[@]:-}\")"
    for pkg in "${pkgs[@]}"; do
      [[ -z "$pkg" ]] && continue
      result 'no-gui' "$pkg" 'needs a desktop, skipped with --no-gui'
    done
    continue
  fi

  eval "formulae=(\"\${GROUP_${group}_FORMULA[@]:-}\")"
  for pkg in "${formulae[@]}"; do
    [[ -z "$pkg" ]] && continue
    install_formula "$pkg"
  done

  eval "casks=(\"\${GROUP_${group}_CASK[@]:-}\")"
  for token in "${casks[@]}"; do
    [[ -z "$token" ]] && continue
    install_cask "$token"
  done
done

# Upgrades

brew_outdated() {
  "$BREW" outdated --quiet "$@" 2>/dev/null || true
}

count_lines() {
  grep -c . <<< "$1" || true
}

if [[ "$SKIP_UPGRADE" == "yes" ]]; then
  phase 'Upgrades - skipped (--skip-upgrade)'
else
  phase 'Upgrades'

  outdated_formulae="$(brew_outdated --formula)"
  n_formulae="$(count_lines "$outdated_formulae")"
  if [[ "$n_formulae" -eq 0 ]]; then
    result 'current' 'brew formulae' 'nothing outdated'
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-upgrade' 'brew formulae' "$n_formulae outdated: $(tr '\n' ' ' <<< "$outdated_formulae")"
  elif "$BREW" upgrade --formula >"$BREW_LOG" 2>&1; then
    result 'upgraded' 'brew formulae' "$n_formulae package(s)"
  else
    result 'failed' 'brew formulae' "brew upgrade: $(brew_error "$BREW_LOG")"
  fi

  outdated_casks="$(brew_outdated --cask)"
  n_casks="$(count_lines "$outdated_casks")"
  if [[ "$n_casks" -eq 0 ]]; then
    result 'current' 'brew casks' 'nothing outdated'
  elif [[ "$SKIP_CASK_UPGRADE" == "yes" ]]; then
    result 'skipped' 'brew casks' "$n_casks outdated - --skip-cask-upgrade"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-upgrade' 'brew casks' "$n_casks outdated: $(tr '\n' ' ' <<< "$outdated_casks")"
  elif "$BREW" upgrade --cask >"$BREW_LOG" 2>&1; then
    result 'upgraded' 'brew casks' "$n_casks app(s)"
  else
    result 'failed' 'brew casks' "brew upgrade --cask: $(brew_error "$BREW_LOG")"
  fi

  self_updating="$(comm -13 \
    <(printf '%s\n' "$outdated_casks" | grep . | sort || true) \
    <(brew_outdated --cask --greedy | grep . | sort || true) || true)"
  if [[ -n "$self_updating" ]]; then
    result 'present' 'self-updating casks' "$(tr '\n' ' ' <<< "$self_updating")- left to their own updaters"
  fi
fi

snapshot_after

# Housekeeping
#
# Every upgrade leaves the version it replaced in the Cellar and the bottle it
# downloaded in the cache, and neither is ever read again. On a machine that
# upgrades itself nightly from the launchd agent below, that is gigabytes a
# month nobody looks at. `brew cleanup --prune=N` removes exactly those two
# things: versions no longer linked, and cache entries older than N days.
#
# `brew autoremove` is reported and never run. It uninstalls formulae it
# believes nothing depends on any more, and a formula installed on purpose as
# a tool is indistinguishable from one pulled in as a dependency and since
# orphaned - so the list is printed and the decision stays yours.

if [[ "$SKIP_CLEANUP" == "yes" ]]; then
  phase 'Housekeeping - skipped (--skip-cleanup)'
elif [[ "${BREW_CLEANUP_ENABLED:-no}" != "yes" ]]; then
  phase 'Housekeeping - disabled in the manifest'
else
  phase 'Housekeeping - superseded versions and stale downloads'

  PRUNE_DAYS="${BREW_CLEANUP_PRUNE_DAYS:-30}"
  cleanup_preview="$("$BREW" cleanup --prune="$PRUNE_DAYS" --dry-run 2>/dev/null || true)"
  # `grep -c` exits 1 on no match, which set -e would take as a failure.
  n_stale="$(grep -c '^Would remove' <<< "$cleanup_preview" || true)"
  freed="$(sed -n 's/.*free approximately \([0-9.]*[KMGTP]*B\).*/\1/p' <<< "$cleanup_preview" | tail -1)"

  if [[ "$n_stale" -eq 0 ]]; then
    result 'current' 'brew cleanup' "nothing superseded, nothing cached over ${PRUNE_DAYS} days"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-upgrade' 'brew cleanup' "$n_stale file(s), ${freed:-unknown} to reclaim"
  elif "$BREW" cleanup --prune="$PRUNE_DAYS" >"$BREW_LOG" 2>&1; then
    result 'upgraded' 'brew cleanup' "$n_stale file(s) removed, ${freed:-unknown} reclaimed"
  else
    result 'failed' 'brew cleanup' "brew cleanup: $(brew_error "$BREW_LOG")"
  fi

  orphans="$("$BREW" autoremove --dry-run 2>/dev/null | grep -v '^==>' | grep . || true)"
  if [[ -n "$orphans" ]]; then
    result 'present' 'unused dependencies' "$(tr '\n' ' ' <<< "$orphans")- brew autoremove, if you agree"
  fi
fi

# Tools that install themselves into $HOME

git_clone_or_update() {
  local name="$1" dir="$2" repo="$3"

  if [[ -d "$dir/.git" ]]; then
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$name" "$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null || echo present)"
      return
    fi
    if [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-upgrade' "$name" 'git pull'
      return
    fi
    local before after
    before="$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null || true)"
    if (cd "$dir" && git pull --quiet --ff-only >/dev/null 2>&1); then
      after="$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null || true)"
      if [[ "$before" == "$after" ]]; then
        result 'current' "$name" "$after"
      else
        result 'upgraded' "$name" "$before -> $after"
      fi
    else
      result 'failed' "$name" 'git pull could not fast-forward'
    fi
    return
  fi

  if [[ -e "$dir" ]]; then
    result 'failed' "$name" "$dir exists and is not a git checkout"
    return
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$name" "$dir"
    return
  fi
  if git clone --quiet --depth 1 "$repo" "$dir" >/dev/null 2>&1; then
    result 'installed' "$name" "$(cd "$dir" && git rev-parse --short HEAD 2>/dev/null || echo cloned)"
  else
    result 'failed' "$name" "git clone failed: $repo"
  fi
}

if [[ "${#TOOLS[@]}" -gt 0 ]]; then
  phase 'Tools - git clones in $HOME'
  for tool in "${TOOLS[@]:-}"; do
    [[ -z "$tool" ]] && continue
    dir_var="TOOL_${tool}_DIR"
    repo_var="TOOL_${tool}_REPO"
    desc_var="TOOL_${tool}_DESC"
    git_clone_or_update "${!desc_var:-$tool}" "${!dir_var}" "${!repo_var}"
  done
fi


# mise global runtimes - node, go and java from one shared list, so the three
# platforms cannot drift apart. `mise use -g` merges into the user's global
# config rather than replacing it, so a tool added by hand survives.
MISE_TOOLS_FILE="${SCRIPT_DIR}/../mise/tools.conf"
phase 'mise - global runtimes'
if ! command -v mise >/dev/null 2>&1; then
  result 'missing' 'mise runtimes' 'mise is not installed'
elif [[ ! -r "$MISE_TOOLS_FILE" ]]; then
  result 'failed' 'mise runtimes' "not found at $MISE_TOOLS_FILE"
else
  _mise_have="$(mise ls -g 2>/dev/null | awk '{print $1}')"
  while IFS= read -r _entry || [[ -n "$_entry" ]]; do
    _entry="${_entry%%#*}"
    _entry="$(printf '%s' "$_entry" | tr -d '[:space:]')"
    [[ -z "$_entry" ]] && continue
    _tool="${_entry%%@*}"
    if printf '%s\n' "$_mise_have" | grep -qx "$_tool"; then
      result 'current' "$_entry" "$(mise current "$_tool" 2>/dev/null || echo installed)"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' "$_entry" "mise use -g $_entry"
    elif mise use -g "$_entry" >/dev/null 2>&1; then
      result 'installed' "$_entry" "$(mise current "$_tool" 2>/dev/null || echo ok)"
    else
      result 'failed' "$_entry" "run by hand: mise use -g $_entry"
    fi
  done < "$MISE_TOOLS_FILE"
fi

# zsh

if [[ "${ZSH_ENABLED:-no}" != "yes" ]]; then
  phase 'zsh - disabled in the manifest'
else
  phase 'zsh - completion, keybindings and the managed fragment'

  result 'present' 'zsh' "$(/bin/zsh --version 2>/dev/null | awk '{print $2}' || echo 'system')"

  COMPFIX_DIRS=(
    "${BREW_PREFIX}/share"
    "${BREW_PREFIX}/share/zsh"
    "${BREW_PREFIX}/share/zsh/site-functions"
    "${BREW_PREFIX}/share/zsh-completions"
  )
  INSECURE_DIRS=()
  for d in "${COMPFIX_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    perms="$(stat -f '%Sp' "$d" 2>/dev/null)" || continue
    if [[ "${perms:5:1}" == "w" || "${perms:8:1}" == "w" ]]; then
      INSECURE_DIRS+=("$d")
    fi
  done

  if [[ ${#INSECURE_DIRS[@]} -eq 0 ]]; then
    result 'current' 'completion perms' 'nothing group- or world-writable on fpath'
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'completion perms' "chmod g-w,o-w on ${#INSECURE_DIRS[@]}: ${INSECURE_DIRS[*]##*/}"
  else
    if chmod g-w,o-w "${INSECURE_DIRS[@]}" 2>/dev/null; then
      result 'installed' 'completion perms' "chmod g-w,o-w ${INSECURE_DIRS[*]##*/}"
    else
      result 'failed' 'completion perms' "run by hand: chmod g-w,o-w ${INSECURE_DIRS[*]}"
    fi
  fi

  ZSHENV="${HOME}/.zshenv"
  ZSHENV_FRAGMENT="${HOME}/.zshenv.bootstrap"
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'zshenv config' "$ZSHENV_FRAGMENT"
  else
    mktemp_tracked NEW_ZSHENV "${ZSHENV_FRAGMENT}.XXXXXX"
    chmod 0644 "$NEW_ZSHENV"
    {
      echo
      echo "[ -x \"${BREW_PREFIX}/bin/brew\" ] && eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
    } > "$NEW_ZSHENV"

    if [[ -f "$ZSHENV_FRAGMENT" ]] && cmp -s "$NEW_ZSHENV" "$ZSHENV_FRAGMENT"; then
      rm -f "$NEW_ZSHENV"
      result 'current' 'zshenv config' "$ZSHENV_FRAGMENT"
    elif [[ -f "$ZSHENV_FRAGMENT" ]]; then
      mv "$NEW_ZSHENV" "$ZSHENV_FRAGMENT"
      result 'upgraded' 'zshenv config' "$ZSHENV_FRAGMENT"
    else
      mv "$NEW_ZSHENV" "$ZSHENV_FRAGMENT"
      result 'installed' 'zshenv config' "$ZSHENV_FRAGMENT"
    fi

    ZSHENV_SOURCE_LINE='[ -f "$HOME/.zshenv.bootstrap" ] && source "$HOME/.zshenv.bootstrap"'
    if [[ -f "$ZSHENV" ]] && grep -qE '^[^#]*(source|\.)[[:space:]].*\.zshenv\.bootstrap' "$ZSHENV"; then
      result 'current' 'zshenv hook' "$ZSHENV"
    else
      printf '\n%s\n' "$ZSHENV_SOURCE_LINE" >> "$ZSHENV"
      result 'installed' 'zshenv hook' "appended to $ZSHENV"
    fi
  fi

  ZSHRC="${HOME}/.zshrc"
  FRAGMENT="${HOME}/.zshrc.bootstrap"
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'zsh config' "$FRAGMENT"
  else
    mktemp_tracked NEW_FRAGMENT "${FRAGMENT}.XXXXXX"
    chmod 0644 "$NEW_FRAGMENT"
    {
      echo
      echo "[ -x \"${BREW_PREFIX}/bin/brew\" ] && eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
      echo
      echo "fpath+=(\"${BREW_PREFIX}/share/zsh-completions\")"
      echo
      # The options oh-my-zsh's lib/ used to set, minus the ones set further
      # down for history and the ones a theme would have wanted.
      echo 'setopt EXTENDED_GLOB        # (#q...) qualifiers, used by compinit below'
      echo 'setopt AUTO_CD              # a bare directory name means cd'
      echo 'setopt AUTO_PUSHD           # every cd pushes onto the stack'
      echo 'setopt PUSHD_IGNORE_DUPS'
      echo 'setopt PUSHD_MINUS          # cd -1 is the previous directory'
      echo 'setopt ALWAYS_TO_END        # completion leaves the cursor after the word'
      echo 'setopt COMPLETE_IN_WORD     # complete from the cursor, not the word end'
      echo 'setopt AUTO_MENU            # a second Tab opens the menu'
      echo 'setopt INTERACTIVE_COMMENTS # a # starts a comment on the command line'
      echo 'setopt LONG_LIST_JOBS'
      echo 'setopt MULTIOS              # echo >file1 >file2'
      echo 'unsetopt MENU_COMPLETE      # Tab never picks an entry for you'
      echo 'unsetopt FLOW_CONTROL       # ^S and ^Q stay usable keys'
      echo 'bindkey -e                  # emacs keymap, whatever $EDITOR says'
      echo
      # compinit is the slow half of shell startup. The full security-checked
      # run happens once a day and the cached one covers the rest; the fpath
      # permissions it would warn about are fixed by the phase above.
      echo 'autoload -Uz compinit'
      echo '_zcompdump="$HOME/.zcompdump"'
      echo '_zcompdump_fresh=( ${_zcompdump}(#qN.mh-24) )'
      echo 'if (( $#_zcompdump_fresh )); then'
      echo '  compinit -C -d "$_zcompdump"'
      echo 'else'
      echo '  compinit -d "$_zcompdump"'
      echo 'fi'
      echo 'unset _zcompdump _zcompdump_fresh'
      echo
      echo "WORDCHARS=''                # ^W and Alt-B stop at every punctuation mark"
      echo "zstyle ':completion:*' matcher-list 'm:{[:lower:][:upper:]-_}={[:upper:][:lower:]_-}' 'r:|=*' 'l:|=* r:|=*'"
      echo "zstyle ':completion:*' special-dirs true"
      echo "zstyle ':completion:*' group-name ''"
      echo "zstyle ':completion:*:descriptions' format '%F{yellow}%d%f'"
      echo '[ -d "$HOME/.cache/zsh" ] || mkdir -p "$HOME/.cache/zsh"'
      echo "zstyle ':completion:*' use-cache yes"
      echo 'zstyle '"'"':completion:*'"'"' cache-path "$HOME/.cache/zsh"'
      echo
      # Catppuccin Mocha, the palette starship.toml, ghostty and atuin use.
      # fzf-tab shells out to fzf, so it inherits these too. A heredoc, not
      # echo lines: the value is written with backslash-newline continuations,
      # and those are literal characters inside the single quotes echo needs.
      cat <<'FZF_OPTS'
export FZF_DEFAULT_OPTS="\
  --color=bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8 \
  --color=fg:#cdd6f4,header:#f38ba8,info:#cba6f7,pointer:#f5e0dc \
  --color=marker:#b4befe,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8 \
  --color=selected-bg:#45475a,border:#6c7086,label:#cdd6f4"
FZF_OPTS
      echo
      # What the omz fzf plugin did: Ctrl-R, Ctrl-T, Alt-C and fzf's own
      # completion. Before atuin further down, which takes Ctrl-R back.
      echo 'command -v fzf >/dev/null && source <(fzf --zsh)'
      echo
      echo 'eval "$(starship init zsh)"'
      echo "[ -r \"${BREW_PREFIX}/share/fzf-tab/fzf-tab.zsh\" ] && source \"${BREW_PREFIX}/share/fzf-tab/fzf-tab.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-history-substring-search/zsh-history-substring-search.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-history-substring-search/zsh-history-substring-search.zsh\""
      echo
      echo 'zmodload zsh/terminfo 2>/dev/null'
      echo 'if (( $+widgets[history-substring-search-up] )); then'
      echo "  bindkey '^[[A' history-substring-search-up"
      echo "  bindkey '^[[B' history-substring-search-down"
      echo '  [ -n "${terminfo[kcuu1]}" ] && bindkey "${terminfo[kcuu1]}" history-substring-search-up'
      echo '  [ -n "${terminfo[kcud1]}" ] && bindkey "${terminfo[kcud1]}" history-substring-search-down'
      echo "  bindkey -M vicmd 'k' history-substring-search-up"
      echo "  bindkey -M vicmd 'j' history-substring-search-down"
      echo 'fi'
      echo
      # Home/End/Delete/PageUp/PageDown and word motion: from terminfo where
      # the terminal reports them, from the usual escapes where it does not.
      echo '[ -n "${terminfo[khome]}" ] && bindkey "${terminfo[khome]}" beginning-of-line'
      echo '[ -n "${terminfo[kend]}"   ] && bindkey "${terminfo[kend]}"   end-of-line'
      echo '[ -n "${terminfo[kdch1]}" ] && bindkey "${terminfo[kdch1]}" delete-char'
      echo '[ -n "${terminfo[kpp]}"   ] && bindkey "${terminfo[kpp]}"   up-line-or-history'
      echo '[ -n "${terminfo[knp]}"   ] && bindkey "${terminfo[knp]}"   down-line-or-history'
      echo '[ -n "${terminfo[kcbt]}"  ] && bindkey "${terminfo[kcbt]}"  reverse-menu-complete'
      echo "bindkey '^[[H' beginning-of-line"
      echo "bindkey '^[[F' end-of-line"
      echo "bindkey '^[[3~' delete-char"
      echo "bindkey '^[[1;5C' forward-word"
      echo "bindkey '^[[1;5D' backward-word"
      echo "bindkey '^[[3;5~' kill-word"
      echo "bindkey ' ' magic-space     # !! expands as you type the space"
      echo 'autoload -Uz edit-command-line'
      echo 'zle -N edit-command-line'
      echo "bindkey '^X^E' edit-command-line  # the line so far, in \$EDITOR"
      echo
      echo 'STARSHIP_FULL_PROMPT="$PROMPT"'
      echo 'STARSHIP_FULL_RPROMPT="$RPROMPT"'
      echo 'TRANSIENT_PROMPT="${PROMPT// prompt / prompt --profile transient }"'
      echo 'TRANSIENT_RPROMPT="${PROMPT// prompt / prompt --profile rtransient }"'
      echo 'STARSHIP_CTX_GROUP=""'
      echo 'STARSHIP_TRANSIENT=0'
      echo 'autoload -Uz add-zle-hook-widget'
      echo 'autoload -Uz add-zsh-hook'
      echo 'starship-restore-prompt() {'
      echo '  PROMPT="$STARSHIP_FULL_PROMPT"'
      echo '  RPROMPT="$STARSHIP_FULL_RPROMPT"'
      echo '  STARSHIP_CTX_GROUP=""'
      echo '  STARSHIP_TRANSIENT=0'
      echo '}'
      echo 'add-zsh-hook precmd starship-restore-prompt'
      echo 'transient-prompt() {'
      echo '  STARSHIP_TRANSIENT=1'
      echo '  PROMPT="$TRANSIENT_PROMPT"'
      echo '  RPROMPT="$TRANSIENT_RPROMPT"'
      echo '  zle .reset-prompt'
      echo '}'
      echo 'zle -N transient-prompt'
      echo 'add-zle-hook-widget zle-line-finish transient-prompt'
      echo
      echo 'starship-context-prompt() {'
      echo '  (( STARSHIP_TRANSIENT )) && return'
      echo '  local -a words'
      echo '  words=( ${(z)BUFFER} )'
      echo '  while (( $#words )) && [[ ${words[1]} == *=* || ${words[1]:t} == (sudo|doas|command|env|time|nice|nohup|watch) ]]; do'
      echo '    shift words'
      echo '  done'
      echo '  local group=""'
      echo '  case ${words[1]:t} in'
      echo '    (kubectl|kubectl-*|kubecolor|k|kubectx|kubens|kustomize|k9s|stern|helm|helmfile|flux|argocd|velero|skaffold|kubeseal)'
      echo '      group=kube ;;'
      echo '    (aws|aws-vault|awslocal|eksctl|sam|copilot|yawsso|saml2aws|granted|assume)'
      echo '      group=aws ;;'
      echo '    (az|azd|azcopy|func)'
      echo '      group=azure ;;'
      echo '    (gcloud|gsutil|bq|firebase|gke-gcloud-auth-plugin)'
      echo '      group=gcloud ;;'
      echo '    (terraform|tofu|terragrunt|tflint|terraform-docs|infracost|tfenv|tfswitch)'
      echo '      group=terraform ;;'
      echo '    (dotnet|dotnet-*|msbuild|nuget)'
      echo '      group=dotnet ;;'
      echo '  esac'
      echo '  [[ "$group" == "$STARSHIP_CTX_GROUP" ]] && return'
      echo '  STARSHIP_CTX_GROUP="$group"'
      echo '  if [[ -n "$group" ]]; then'
      echo '    RPROMPT="${STARSHIP_FULL_PROMPT// prompt / prompt --profile ctx_$group }"'
      echo '  else'
      echo '    RPROMPT="$STARSHIP_FULL_RPROMPT"'
      echo '  fi'
      echo '  zle .reset-prompt'
      echo '}'
      echo 'zle -N starship-context-prompt'
      echo 'add-zle-hook-widget zle-line-pre-redraw starship-context-prompt'
      echo
      # What omz's termsupport.zsh did: the directory in the tab title, the
      # command while one is running.
      printf '%s\n' 'zsh-title() { print -Pn "\e]2;$1\a" }'
      echo "zsh-title-precmd()  { zsh-title '%~' }"
      echo 'zsh-title-preexec() { zsh-title "${1%% *} - %~" }'
      echo 'add-zsh-hook precmd zsh-title-precmd'
      echo 'add-zsh-hook preexec zsh-title-preexec'
      echo
      echo 'zstyle '"'"':completion:*'"'"' list-colors "${(s.:.)LS_COLORS}"'
      # The menuselect keymap only exists once complist is loaded; oh-my-zsh
      # used to load it, and without it the bindkey below is an error.
      echo 'zmodload zsh/complist'
      echo "bindkey -M menuselect '^[[Z' reverse-menu-complete"
      echo 'if command -v fzf >/dev/null; then'
      echo "  zstyle ':completion:*' menu no"
      echo "  zstyle ':completion:*:*:*:*:*' menu no"
      echo "  zstyle ':fzf-tab:*' fzf-flags --height=60% --layout=reverse --border --cycle"
      echo "  zstyle ':fzf-tab:*' switch-group ',' '.'"
      echo '  # git checkout offers refs in a meaningful order already; sorting'
      echo "  # them alphabetically buries the branch you just left."
      echo "  zstyle ':completion:*:git-checkout:*' sort false"
      echo "  zstyle ':fzf-tab:complete:cd:*'         fzf-preview 'eza -1 --color=always -- \"\$realpath\" 2>/dev/null || ls -1 \"\$realpath\"'"
      echo "  zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza -1 --color=always -- \"\$realpath\" 2>/dev/null || ls -1 \"\$realpath\"'"
      echo '  # Bound only if the widget exists, so a failed fzf-tab install'
      echo '  # leaves Tab doing the normal thing rather than nothing.'
      echo '  if (( $+functions[fzf-tab-complete] )); then'
      echo "    bindkey -M emacs '^I' fzf-tab-complete"
      echo "    bindkey -M viins '^I' fzf-tab-complete"
      echo '  fi'
      echo 'else'
      echo "  bindkey '^I' menu-select"
      echo 'fi'
      echo
      echo 'HISTFILE="$HOME/.zsh_history"'
      printf 'HISTSIZE=%s\n' "$HISTORY_SIZE"
      printf 'SAVEHIST=%s\n' "$HISTORY_FILE_SIZE"
      echo 'setopt APPEND_HISTORY        # add to the file, never replace it'
      echo 'setopt INC_APPEND_HISTORY    # write as you go, not at exit - a'
      echo '                             # crashed or killed shell loses nothing'
      echo 'setopt SHARE_HISTORY         # every open terminal sees the others'
      echo 'setopt EXTENDED_HISTORY      # timestamp and duration per entry'
      echo 'setopt HIST_IGNORE_ALL_DUPS  # keep only the newest of a repeat'
      echo 'setopt HIST_REDUCE_BLANKS'
      echo 'setopt HIST_VERIFY           # expand !! for review, do not just run it'
      echo 'setopt HIST_IGNORE_SPACE     # a leading space keeps it out of history'
      echo
      echo "alias ..='cd ..'"
      echo "alias ...='cd ../..'"
      echo "alias ....='cd ../../..'"
      echo "alias -- -='cd -'"
      echo
      echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
      # man pages in bat's theme. col -bx strips the overstrike backspaces
      # groff emits for bold and underline, which bat would render literally.
      echo 'command -v bat    >/dev/null && export MANPAGER="sh -c '"'"'col -bx | bat -l man -p'"'"'" MANROFFOPT="-c"'
      echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
      echo 'command -v rg     >/dev/null && alias grep="rg"'
      echo 'command -v fd     >/dev/null && alias find="fd"'
      echo 'command -v dust   >/dev/null && alias du="dust"'
      echo 'command -v duf    >/dev/null && alias df="duf"'
      # doggo answers the same questions as dig and prints them as a table.
      echo 'command -v doggo  >/dev/null && alias dig="doggo"'
      # xh is curl for JSON APIs; xhs is xh --https, a symlink upstream.
      echo 'command -v xh     >/dev/null && alias http="xh"'
      echo 'command -v xh     >/dev/null && alias https="xh --https"'
      # sd deliberately gets no `sed` alias: its pattern and replacement syntax
      # is not sed's, so anything pasted from a script would quietly do
      # something else. It is called as sd.
      echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
      # Last binding wins, so atuin goes after fzf/fzf-tab to take Ctrl+R.
      # --disable-up-arrow keeps Up on history-substring-search, bound above.
      echo 'command -v atuin  >/dev/null && eval "$(atuin init zsh --disable-up-arrow)"'
      # carapace completes the CLIs zsh has nothing for. git is excluded: zsh's
      # own _git is better, and the git-checkout zstyle above is written for it.
      echo 'if command -v carapace >/dev/null; then'
      echo "  export CARAPACE_EXCLUDES='git'"
      echo '  eval "$(carapace _carapace zsh)"'
      echo 'fi'
      # uv's zsh completion is ~570 KB, so it loads on the first Tab after `uv`
      # rather than in every new shell: the stub swaps itself for the real _uv.
      echo 'if command -v uv >/dev/null; then'
      echo '  _uv_lazy() { unfunction _uv_lazy; eval "$(uv generate-shell-completion zsh)"; _uv "$@"; }'
      echo '  compdef _uv_lazy uv'
      echo 'fi'
      echo 'command -v kubectl >/dev/null && alias k="kubectl"'
      # kubecolor hands every argument to kubectl and only adds colour, so the
      # alias is invisible otherwise. After carapace, whose kubectl completer
      # compdef then copies.
      echo 'if command -v kubecolor >/dev/null; then'
      echo '  alias kubectl="kubecolor"'
      echo '  (( $+_comps[kubectl] )) && compdef kubecolor=kubectl'
      echo 'fi'
      # macOS is the one platform where trippy traces without root.
      echo 'command -v trip >/dev/null && alias trip="trip -u"'
      echo
      load_parity_table
      echo 'tools() {'
      echo '  echo'
      group_array _form "GROUP_cli_FORMULA"
      group_array _cask "GROUP_cli_CASK"
      for pkg in "${_form[@]:-}" "${_cask[@]:-}"; do
        [[ -z "$pkg" ]] && continue
        if parity_row "$pkg"; then
          printf "  echo '  %-12s  %-10s  %s'\n" "$pkg" "$_row_cmd" "$_row_desc"
        else
          printf "  echo '  %s'\n" "$pkg"
        fi
      done
      unset _form _cask
      echo '  echo'
      echo '}'
      echo
      echo 'command -v gmake  >/dev/null && alias make="gmake"'
      echo
      echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
      echo
      # mise activate below covers interactive shells, PATH and JAVA_HOME
      # included. The shims directory covers what never sources this file:
      # a non-interactive `ssh host command`, a cron job, a Makefile an IDE
      # runs. Activation takes precedence where both apply.
      # `go install` and the VS Code Go extension drop gopls, dlv and
      # staticcheck in GOPATH/bin, which is ~/go/bin unless GOPATH says
      # otherwise. Nothing else puts it on PATH.
      echo '[ -d "$HOME/go/bin" ] && export PATH="$HOME/go/bin:$PATH"'
      echo
      echo '_mise_shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"'
      echo '[ -d "$_mise_shims" ] && export PATH="$PATH:$_mise_shims"'
      echo 'unset _mise_shims'
      echo
      echo 'command -v mise >/dev/null && eval "$(mise activate zsh)"'
      # mise has no carapace completer; its own script is small and asks mise itself.
      echo 'command -v mise >/dev/null && eval "$(mise completion zsh)"'
    } > "$NEW_FRAGMENT"

    if [[ -f "$FRAGMENT" ]] && cmp -s "$NEW_FRAGMENT" "$FRAGMENT"; then
      rm -f "$NEW_FRAGMENT"
      result 'current' 'zsh config' "$FRAGMENT"
    elif [[ -f "$FRAGMENT" ]]; then
      mv "$NEW_FRAGMENT" "$FRAGMENT"
      result 'upgraded' 'zsh config' "$FRAGMENT"
    else
      mv "$NEW_FRAGMENT" "$FRAGMENT"
      result 'installed' 'zsh config' "$FRAGMENT"
    fi

    SOURCE_LINE='[ -f "$HOME/.zshrc.bootstrap" ] && source "$HOME/.zshrc.bootstrap"'
    if [[ -f "$ZSHRC" ]] && grep -qF '.zshrc.bootstrap' "$ZSHRC"; then
      result 'current' 'zshrc hook' "$ZSHRC"
    else
      printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
      result 'installed' 'zshrc hook' "appended to $ZSHRC"
    fi

  fi
fi

# VS Code extensions

if [[ "${#VSCODE_EXTENSIONS[@]}" -gt 0 ]]; then
  if [[ "$SKIP_VSCODE_EXT" == "yes" ]]; then
    phase 'VS Code extensions - skipped (--skip-vscode-extensions)'
  elif [[ "$HAS_GUI" != "yes" ]]; then
    phase 'VS Code extensions - no desktop, skipping'
    result 'no-gui' 'vscode extensions' 'needs a desktop, none detected'
  elif ! command -v code >/dev/null 2>&1; then
    phase 'VS Code extensions - code CLI not on PATH, skipping'
    result 'missing' 'vscode extensions' 'code CLI not found - install the visual-studio-code cask first'
  else
    phase 'VS Code extensions - install what is missing, never remove'
    vscode_installed="$(code --list-extensions 2>/dev/null || true)"
    for ext in "${VSCODE_EXTENSIONS[@]}"; do
      [[ -z "$ext" ]] && continue
      if grep -qiFx "$ext" <<<"$vscode_installed"; then
        result 'present' "$ext"
      elif [[ "$DRY_RUN" == "yes" ]]; then
        result 'would-install' "$ext"
      elif code --install-extension "$ext" >/dev/null 2>&1; then
        result 'installed' "$ext"
      else
        result 'failed' "$ext" 'code --install-extension failed'
      fi
    done
  fi
fi

# Prompt config
STARSHIP_TOML_SOURCE="${SCRIPT_DIR}/../starship.toml"
if ! command -v starship >/dev/null 2>&1; then
  phase 'Prompt config'
  result 'missing' 'starship.toml' 'starship is not installed'
elif [[ ! -r "$STARSHIP_TOML_SOURCE" ]]; then
  phase 'Prompt config'
  result 'failed' 'starship.toml' "not found at $STARSHIP_TOML_SOURCE"
else
  phase 'Prompt config'
  STARSHIP_TOML_DIR="${HOME}/.config"
  STARSHIP_TOML_TARGET="${STARSHIP_TOML_DIR}/starship.toml"
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'starship.toml' "$STARSHIP_TOML_TARGET"
  else
    mkdir -p "$STARSHIP_TOML_DIR"
    if [[ -f "$STARSHIP_TOML_TARGET" ]] && cmp -s "$STARSHIP_TOML_SOURCE" "$STARSHIP_TOML_TARGET"; then
      result 'current' 'starship.toml' "$STARSHIP_TOML_TARGET"
    elif [[ -f "$STARSHIP_TOML_TARGET" ]]; then
      cp "$STARSHIP_TOML_SOURCE" "$STARSHIP_TOML_TARGET"
      chmod 0644 "$STARSHIP_TOML_TARGET"
      result 'upgraded' 'starship.toml' "$STARSHIP_TOML_TARGET"
    else
      cp "$STARSHIP_TOML_SOURCE" "$STARSHIP_TOML_TARGET"
      chmod 0644 "$STARSHIP_TOML_TARGET"
      result 'installed' 'starship.toml' "$STARSHIP_TOML_TARGET"
    fi
  fi
fi

# Atuin config
deploy_config() {   # deploy_config <source> <target> <label>
  local src="$1" dst="$2" label="$3"
  if [[ ! -r "$src" ]]; then
    result 'failed' "$label" "not found at $src"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$label" "$dst"
  elif [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    result 'current' "$label" "$dst"
  else
    local had=no
    [[ -f "$dst" ]] && had=yes
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    chmod 0644 "$dst"
    if [[ "$had" == "yes" ]]; then
      result 'upgraded' "$label" "$dst"
    else
      result 'installed' "$label" "$dst"
    fi
  fi
}

ATUIN_SOURCE="${SCRIPT_DIR}/../atuin"
if ! command -v atuin >/dev/null 2>&1; then
  phase 'Atuin config'
  result 'missing' 'atuin config' 'atuin is not installed'
else
  phase 'Atuin config'
  deploy_config "${ATUIN_SOURCE}/config.toml" \
                "${HOME}/.config/atuin/config.toml" 'atuin config.toml'
  deploy_config "${ATUIN_SOURCE}/themes/catppuccin-mocha.toml" \
                "${HOME}/.config/atuin/themes/catppuccin-mocha.toml" 'atuin theme'
fi

# bat config - the theme bat, and through it delta, render with
BAT_SOURCE="${SCRIPT_DIR}/../bat"
phase 'bat config'
if ! command -v bat >/dev/null 2>&1; then
  result 'missing' 'bat config' 'bat is not installed'
else
  _bat_cfg="$(bat --config-dir 2>/dev/null)"
  deploy_config "${BAT_SOURCE}/config" "${_bat_cfg}/config" 'bat config'
  deploy_config "${BAT_SOURCE}/themes/Catppuccin Mocha.tmTheme" \
                "${_bat_cfg}/themes/Catppuccin Mocha.tmTheme" 'bat theme'
  # bat since 0.24 reads the themes directory at startup, so this is a no-op
  # on anything current - kept for an older bat, which only sees a theme once
  # it is in the cache.
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'bat cache' 'bat cache --build, if the theme is not listed'
  elif bat --list-themes 2>/dev/null | grep -qx 'Catppuccin Mocha'; then
    result 'current' 'bat cache' 'Catppuccin Mocha is in the theme list'
  elif bat cache --build >/dev/null 2>&1; then
    result 'installed' 'bat cache' 'bat cache --build'
  else
    result 'failed' 'bat cache' 'run by hand: bat cache --build'
  fi
fi

# Carapace specs - completion for CLIs carapace has no completer of its own for
CARAPACE_SOURCE="${SCRIPT_DIR}/../carapace"
phase 'Carapace specs'
if ! command -v carapace >/dev/null 2>&1; then
  result 'missing' 'carapace specs' 'carapace is not installed'
else
  # carapace honours XDG_CONFIG_HOME only when it is an absolute path, and
  # otherwise uses Go's config dir - Application Support on macOS, not ~/.config.
  _carapace_cfg="${XDG_CONFIG_HOME:-}"
  [[ "$_carapace_cfg" == /* ]] || _carapace_cfg="${HOME}/Library/Application Support"
  for _spec in "${CARAPACE_SOURCE}/specs/"*.yaml; do
    [[ -e "$_spec" ]] || continue
    deploy_config "$_spec" "${_carapace_cfg}/carapace/specs/$(basename "$_spec")" \
                  "carapace spec $(basename "$_spec" .yaml)"
  done
fi

# Git config
# Set only when unset: an existing value is somebody's choice, not drift.
phase 'Git config'
if ! command -v git >/dev/null 2>&1; then
  result 'missing' 'git config' 'git is not installed'
else
  GIT_WANT=()
  # Defaults that have nothing to do with the tools below - each one only takes
  # effect where the key is unset, so an existing choice is never overwritten.
  GIT_WANT+=(
    # `git push` on a new branch sets the upstream itself instead of failing
    # with "no upstream branch" and a command to paste. git >= 2.37.
    'push.autoSetupRemote=true'
    # fetch drops remote-tracking refs for branches deleted upstream, so
    # completion stops offering months of dead origin/* names.
    'fetch.prune=true'
    # histogram reads better than the default myers on moved and reindented
    # code; delta and difftastic render whatever this produces.
    'diff.algorithm=histogram'
    # rebase stashes and restores dirty work itself rather than refusing.
    'rebase.autoStash=true'
    # branch and status lists print in columns instead of one name per line.
    'column.ui=auto'
    # zdiff3 adds the common ancestor to a conflict, so it shows what each
    # side changed rather than only the two endings. git >= 2.35.
    'merge.conflictStyle=zdiff3'
    # v1.10.0 above v1.9.0. The field is version:refname - plain `-version`
    # is rejected with "unknown field name: version".
    'tag.sort=-version:refname'
  )
  # delta is the pager for diff, show, log and add -p; `git sdiff` is the same
  # view side by side.
  if command -v delta >/dev/null 2>&1; then
    GIT_WANT+=(
      'core.pager=delta'
      'interactive.diffFilter=delta --color-only'
      "alias.sdiff=-c core.pager='delta --side-by-side' diff"
    )
    # delta highlights through bat's theme store - the same Catppuccin Mocha
    # the bat phase installs, so a diff and a `bat` of the same file match.
    command -v bat >/dev/null 2>&1 && GIT_WANT+=('delta.syntax-theme=Catppuccin Mocha')
  else
    result 'missing' 'delta' 'delta is not installed'
  fi
  # difftastic compares syntax, not lines, and is asked for per command - never
  # diff.external globally, whose output is not a patch `git apply` can read.
  # delta passes its output through untouched, so the pager needs no exception.
  if command -v difft >/dev/null 2>&1; then
    GIT_WANT+=(
      'diff.tool=difftastic'
      'difftool.prompt=false'
      'difftool.difftastic.cmd=difft "$LOCAL" "$REMOTE"'
      'pager.difftool=true'
      'alias.dft=difftool'
      'alias.ddiff=-c diff.external=difft diff'
      'alias.dshow=-c diff.external=difft show --ext-diff'
      'alias.dlog=-c diff.external=difft log -p --ext-diff'
    )
  else
    result 'missing' 'difftastic' 'difft is not installed'
  fi
  # Guarded expansion: bash 3.2 under set -u calls an empty array unbound.
  for _kv in ${GIT_WANT[@]+"${GIT_WANT[@]}"}; do
    _key="${_kv%%=*}"
    _want="${_kv#*=}"
    _have="$(git config --global --get "$_key" 2>/dev/null || true)"
    if [[ "$_have" == "$_want" ]]; then
      result 'current' "$_key" "$_want"
    elif [[ -n "$_have" ]]; then
      result 'present' "$_key" "$_have - left alone"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' "$_key" "$_want"
    elif git config --global "$_key" "$_want"; then
      result 'installed' "$_key" "$_want"
    else
      result 'failed' "$_key" 'git config --global failed'
    fi
  done
fi

# Terminal config

if [[ "${GHOSTTY_ENABLED:-no}" != "yes" ]]; then
  phase 'Terminal config - disabled in the manifest'
elif ! command -v ghostty >/dev/null 2>&1 && [[ ! -d /Applications/Ghostty.app ]]; then
  phase 'Terminal config'
  result 'missing' 'ghostty config' 'ghostty is not installed'
else
  phase 'Terminal config'
  GHOSTTY_DIR="${HOME}/.config/ghostty"
  GHOSTTY_CONF="${GHOSTTY_DIR}/config"

  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'ghostty config' "$GHOSTTY_CONF"
  else
    mkdir -p "$GHOSTTY_DIR"
    mktemp_tracked NEW_GHOSTTY "${GHOSTTY_CONF}.XXXXXX"
    chmod 0644 "$NEW_GHOSTTY"
    {
      echo
      echo "scrollback-limit = ${GHOSTTY_SCROLLBACK_BYTES}"
      echo
      echo "theme = ${GHOSTTY_THEME}"
      echo
      [[ -n "${GHOSTTY_FONT_FAMILY:-}" ]] && echo "font-family = ${GHOSTTY_FONT_FAMILY}"
      echo "font-size = ${GHOSTTY_FONT_SIZE}"
      echo
      echo "macos-option-as-alt = ${GHOSTTY_MACOS_OPTION_AS_ALT}"
      echo
      echo "window-save-state = ${GHOSTTY_WINDOW_SAVE_STATE}"
      echo
      echo "copy-on-select = ${GHOSTTY_COPY_ON_SELECT}"
      echo
      echo "quit-after-last-window-closed = ${GHOSTTY_QUIT_AFTER_LAST_WINDOW}"
      echo
      echo "shell-integration-features = ${GHOSTTY_SHELL_INTEGRATION_FEATURES}"
      echo
      [[ -n "${GHOSTTY_QUICK_TERMINAL_KEYBIND:-}" ]] && echo "keybind = ${GHOSTTY_QUICK_TERMINAL_KEYBIND}"
      echo
      echo "window-padding-x = ${GHOSTTY_WINDOW_PADDING_X}"
      echo "window-padding-y = ${GHOSTTY_WINDOW_PADDING_Y}"
    } > "$NEW_GHOSTTY"

    if [[ -f "$GHOSTTY_CONF" ]] && cmp -s "$NEW_GHOSTTY" "$GHOSTTY_CONF"; then
      rm -f "$NEW_GHOSTTY"
      result 'current' 'ghostty config' "$GHOSTTY_CONF"
    elif [[ -f "$GHOSTTY_CONF" ]]; then
      mv "$NEW_GHOSTTY" "$GHOSTTY_CONF"
      result 'upgraded' 'ghostty config' "$GHOSTTY_CONF"
    else
      mv "$NEW_GHOSTTY" "$GHOSTTY_CONF"
      result 'installed' 'ghostty config' "$GHOSTTY_CONF"
    fi
  fi
fi

# Schedule
#
# A launchd user agent, the macOS counterpart of the systemd timer on Linux and
# the scheduled task on Windows. A user agent and not a daemon on purpose: this
# script refuses to run as root and Homebrew refuses along with it, so the job
# has to belong to the same uid that owns the prefix.
#
# launchd runs a calendar job that came due while the Mac was asleep or shut
# down as soon as it is awake again, so the time is "about then, or the next
# time you open the lid" rather than exactly.
#
# The agent passes --skip-cask-upgrade: a cask that needs an admin password has
# nowhere to ask for one in an unattended run and would fail every night.
# Formulae - the bulk of what moves - still upgrade daily, casks come with the
# next interactive run, and casks that update themselves were never ours.
#
# It also passes --skip-update-check, which only ever prints a line, and needs
# a terminal to be read from. The script is invoked through /bin/bash rather
# than run directly, so a checkout whose exec bit did not survive still works.

if [[ "$SKIP_SCHEDULE" == "yes" ]]; then
  phase 'Schedule - skipped (--skip-schedule)'
elif [[ "${SCHEDULE_ENABLED:-no}" != "yes" ]]; then
  phase 'Schedule - disabled in the manifest'
else
  phase 'Schedule - daily unattended run'

  SCHEDULE_LABEL="${SCHEDULE_LABEL:-com.github.bootstrap.macos}"
  SCHEDULE_TIME="${SCHEDULE_TIME:-04:20}"
  SCHEDULE_LOG_DIR="${SCHEDULE_LOG_DIR:-${HOME}/Library/Logs/bootstrap-macos}"
  SCHEDULE_KEEP_LOG_DAYS="${SCHEDULE_KEEP_LOG_DAYS:-30}"
  PLIST="${HOME}/Library/LaunchAgents/${SCHEDULE_LABEL}.plist"
  LAUNCHD_DOMAIN="gui/$(id -u)"

  # Yesterday's logs, before anything else: the pruning is worth doing even on
  # a run where the agent itself turns out to be current.
  if [[ -d "$SCHEDULE_LOG_DIR" ]]; then
    stale_logs="$(find "$SCHEDULE_LOG_DIR" -type f -name 'bootstrap-*.log' \
                    -mtime "+${SCHEDULE_KEEP_LOG_DAYS}" 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${stale_logs:-0}" -gt 0 ]]; then
      if [[ "$DRY_RUN" == "yes" ]]; then
        result 'would-upgrade' 'log pruning' "$stale_logs older than ${SCHEDULE_KEEP_LOG_DAYS} days"
      else
        find "$SCHEDULE_LOG_DIR" -type f -name 'bootstrap-*.log' \
          -mtime "+${SCHEDULE_KEEP_LOG_DAYS}" -delete 2>/dev/null || true
        result 'upgraded' 'log pruning' "removed $stale_logs older than ${SCHEDULE_KEEP_LOG_DAYS} days"
      fi
    fi
  fi

  if [[ ! "$SCHEDULE_TIME" =~ ^[0-9]{1,2}:[0-9]{2}$ ]]; then
    result 'failed' "$SCHEDULE_LABEL" "SCHEDULE_TIME is '$SCHEDULE_TIME', want HH:MM"
  else
    # 10# so 04:20 is four twenty and not an invalid octal literal, and so the
    # plist gets <integer>4</integer> rather than <integer>04</integer>.
    sched_hour=$((10#${SCHEDULE_TIME%%:*}))
    sched_min=$((10#${SCHEDULE_TIME##*:}))

    # Only the values interpolated below can carry an & or a < - the command
    # itself is fixed, and reaches the job through environment variables rather
    # than being pasted together with paths.
    xml_escape() {
      printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
    }

    mktemp_tracked NEW_PLIST "${TMPDIR:-/tmp}/bootstrap-launchagent.XXXXXX"
    cat > "$NEW_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$SCHEDULE_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>mkdir -p "\$BOOTSTRAP_LOG_DIR" &amp;&amp; exec /bin/bash "\$BOOTSTRAP_SCRIPT" --skip-update-check --skip-cask-upgrade &gt;&gt; "\$BOOTSTRAP_LOG_DIR/bootstrap-\$(date +%Y-%m-%d).log" 2&gt;&amp;1</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BOOTSTRAP_SCRIPT</key>
    <string>$(xml_escape "${SCRIPT_DIR}/bootstrap.sh")</string>
    <key>BOOTSTRAP_LOG_DIR</key>
    <string>$(xml_escape "$SCHEDULE_LOG_DIR")</string>
    <key>PATH</key>
    <string>$(xml_escape "${BREW_PREFIX}/bin:${BREW_PREFIX}/sbin:${HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$SCRIPT_DIR")</string>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${sched_hour}</integer>
    <key>Minute</key>
    <integer>${sched_min}</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
</dict>
</plist>
PLIST

    agent_loaded=no
    launchctl list "$SCHEDULE_LABEL" >/dev/null 2>&1 && agent_loaded=yes
    plist_same=no
    [[ -f "$PLIST" ]] && cmp -s "$NEW_PLIST" "$PLIST" && plist_same=yes

    if [[ "$plist_same" == "yes" && "$agent_loaded" == "yes" ]]; then
      result 'current' "$SCHEDULE_LABEL" "daily at $SCHEDULE_TIME, logs in $SCHEDULE_LOG_DIR"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      sched_action='would-install'
      [[ -f "$PLIST" ]] && sched_action='would-upgrade'
      result "$sched_action" "$SCHEDULE_LABEL" "daily at $SCHEDULE_TIME"
    else
      sched_action='installed'
      [[ -f "$PLIST" ]] && sched_action='upgraded'
      mkdir -p "${HOME}/Library/LaunchAgents" "$SCHEDULE_LOG_DIR"
      mv "$NEW_PLIST" "$PLIST"
      chmod 0644 "$PLIST"
      # bootout first: launchctl will not replace a job that is already loaded,
      # and a bootout of something absent is an error worth ignoring.
      launchctl bootout "${LAUNCHD_DOMAIN}/${SCHEDULE_LABEL}" >/dev/null 2>&1 || true
      if launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST" >/dev/null 2>&1; then
        result "$sched_action" "$SCHEDULE_LABEL" "daily at $SCHEDULE_TIME, logs in $SCHEDULE_LOG_DIR"
      elif launchctl load -w "$PLIST" >/dev/null 2>&1; then
        # The pre-10.11 spelling, and the one that still works over ssh where
        # there is no gui domain to bootstrap into.
        result "$sched_action" "$SCHEDULE_LABEL" "daily at $SCHEDULE_TIME, loaded with launchctl load"
      else
        result 'failed' "$SCHEDULE_LABEL" "written to $PLIST, but launchctl would not load it"
      fi
    fi
  fi
fi

# Manual
#
# Nothing to report is the normal state, so the phase only appears when the
# manifest actually lists something - an empty header is noise in every run.

if [[ "${#MANUAL[@]}" -gt 0 ]]; then
  phase 'Manual - reported only'

  for entry in "${MANUAL[@]:-}"; do
    [[ -z "$entry" ]] && continue
    cmd="${entry%%:*}"
    rest="${entry#*:}"
    name="${rest%%:*}"
    where="${rest#*:}"
    if command -v "$cmd" >/dev/null 2>&1; then
      result 'present' "$name" "$(command -v "$cmd")"
    else
      result 'missing' "$name" "$where"
    fi
  done
fi

# Summary

phase 'Summary'

for action in installed upgraded would-install would-upgrade failed missing no-gui held skipped current present; do
  count=0
  for a in "${RESULT_ACTIONS[@]:-}"; do [[ "$a" == "$action" ]] && count=$((count + 1)); done
  [[ "$count" -gt 0 ]] && printf '  %-16s%s\n' "$action" "$count"
done

failures=0
for a in "${RESULT_ACTIONS[@]:-}"; do [[ "$a" == "failed" ]] && failures=$((failures + 1)); done

echo
if [[ "$failures" -gt 0 ]]; then
  printf '  %s%s step(s) failed.%s\n\n' "$C_RED" "$failures" "$C_RESET"
  exit 1
fi

if [[ "$HAS_GUI" != "yes" ]]; then
  printf '  %sRan with --no-gui, so desktop software was skipped.%s\n' "$C_DIM" "$C_RESET"
fi
printf '  %sOpen a new shell to pick up PATH and shell changes.%s\n\n' "$C_DIM" "$C_RESET"
