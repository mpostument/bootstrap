#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_VERSION='1.37.1'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
SKIP_CLEANUP=no
SKIP_SCHEDULE=no
SKIP_REPOS=no
SKIP_VSCODE_EXT=no
SKIP_UPDATE_CHECK=no
ASSUME_YES=no
GUI_OVERRIDE=auto
ONLY_GROUPS=""
STATUS_ONLY=no
DOCTOR_ONLY=no
HISTORY_ONLY=no
HISTORY_LINES=10

# Run state.
#
# Two paths, because two different users run this script. The systemd timer
# runs it as root - apt needs that - and an interactive run is you, so a single
# $HOME-relative path would record the timer's runs into /root and hide them
# from the person asking. Each writes where it can, and --status reads whichever
# of the two is newer.
RUN_STARTED_EPOCH="$(date +%s)"
RUN_STARTED_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_INTERACTIVE=no
[[ -t 1 ]] && RUN_INTERACTIVE=yes
RUN_RECORDING=no
# What this run moved: "pkg old>new" for an upgrade, "+pkg version" for an
# install, from a snapshot taken before the packages phase against one taken
# after the upgrades.
RUN_CHANGED=''
SNAP_BEFORE=''
STATE_SYSTEM="/var/lib/bootstrap-linux/last-run"
STATE_USER="${XDG_STATE_HOME:-${HOME}/.local/state}/bootstrap-linux/last-run"
FAILED_IDS=()

# Output

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_CYAN=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
fi

RESULT_ACTIONS=()
RESULT_LINES=()

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
  # by then the output has scrolled away or gone into the journal.
  [[ "$action" == "failed" || "$action" == "broken" ]] && FAILED_IDS+=("$id")
  RESULT_ACTIONS+=("$action")
  RESULT_LINES+=("$action")
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
# An unattended run is a run nobody watches: the timer starts it at 04:20, it
# writes to the journal and exits, and the one question worth answering
# afterwards - did last night's run work? - took `journalctl -u bootstrap-linux`
# and a scroll. Every real run now leaves one key=value record behind, written
# from the EXIT trap so a run that dies in preflight records that rather than
# leaving yesterday's success in place, and `--status` reads it back.
#
# Dry runs never write it: a dry run is a question, and it should not overwrite
# the record of the last real answer.

# Where an unattended run's output went. On Linux that is the journal: the
# timer's service inherits no log file, systemd takes stdout. Empty for an
# interactive run, which went to the terminal the reader is sitting at.
log_hint() {
  [[ "$RUN_INTERACTIVE" == "no" ]] || return 0
  printf 'journalctl -u %s' "${SCHEDULE_UNIT_NAME:-bootstrap-linux}"
}

state_file() {
  if [[ "$(id -u)" -eq 0 ]]; then printf '%s' "$STATE_SYSTEM"; else printf '%s' "$STATE_USER"; fi
}

action_count() {   # action_count <action>
  local want="$1" a count=0
  for a in "${RESULT_ACTIONS[@]:-}"; do
    [[ "$a" == "$want" ]] && count=$((count + 1))
  done
  printf '%s' "$count"
}

write_state() {   # write_state <exit-code>
  local rc="$1" target finished counts='' failed='' action count f
  [[ "$RUN_RECORDING" == "yes" ]] || return 0
  [[ "$DRY_RUN" == "no" ]] || return 0

  target="$(state_file)"
  finished="$(date +%s)"
  for action in installed upgraded failed missing skipped current present held no-gui; do
    count="$(action_count "$action")"
    [[ "$count" -gt 0 ]] && counts="${counts}${counts:+ }${action}=${count}"
  done
  # Comma-separated: an id can contain spaces ("repo: Visual Studio Code").
  for f in "${FAILED_IDS[@]:-}"; do
    [[ -z "$f" ]] && continue
    failed="${failed}${failed:+, }${f}"
  done

  mkdir -p "$(dirname "$target")" 2>/dev/null || return 0
  {
    echo "version=$BOOTSTRAP_VERSION"
    echo "started=$RUN_STARTED_ISO"
    echo "finished_epoch=$finished"
    echo "duration_seconds=$(( finished - RUN_STARTED_EPOCH ))"
    echo "exit=$rc"
    echo "interactive=$RUN_INTERACTIVE"
    echo "failed='${failed//\'/}'"
    echo "counts='$counts'"
    echo "log=$(log_hint)"
    echo "error='$(printf '%s' "${RUN_ABORT_MSG//\'/}" | tr '\n' ' ' | cut -c1-200)'"
    echo "changed='${RUN_CHANGED//\'/}'"
  } > "$target" 2>/dev/null || true
  append_history "$rc" "$finished" "$(( finished - RUN_STARTED_EPOCH ))"
  # The timer's record is read by a person who is not root.
  chmod 0644 "$target" 2>/dev/null || true
  return 0
}

history_file() { printf '%s/history' "$(dirname "$(state_file)")"; }

# One line per run, oldest first, so a week of unattended runs reads at once.
# Bounded at 200 lines - eight months of nightly runs - because a file that
# grows forever is a file somebody eventually has to deal with.
append_history() {   # append_history <exit> <finished-epoch> <duration>
  local hist line tallies tmp
  hist="$(history_file)"
  tallies="$(action_count installed)/$(action_count upgraded)/$(action_count failed)"
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s' \
    "$2" "$1" "$3" "$RUN_INTERACTIVE" "$tallies" "${RUN_CHANGED:0:300}")"
  mkdir -p "$(dirname "$hist")" 2>/dev/null || return 0
  if [[ -f "$hist" ]]; then
    tmp="${hist}.new"
    { tail -n 199 "$hist"; printf '%s\n' "$line"; } > "$tmp" 2>/dev/null && mv "$tmp" "$hist"
  else
    printf '%s\n' "$line" > "$hist" 2>/dev/null
  fi
  chmod 0644 "$hist" 2>/dev/null || true
  return 0
}

print_history() {
  local hist epoch code dur trigger tallies changed when verdict colour shown=0
  # The same two records --status reads from: the timer's, and yours.
  hist="/var/lib/bootstrap-linux/history"
  [[ -r "$hist" ]] || hist="${XDG_STATE_HOME:-${HOME}/.local/state}/bootstrap-linux/history"
  if [[ -r "/var/lib/bootstrap-linux/history" && -r "${XDG_STATE_HOME:-${HOME}/.local/state}/bootstrap-linux/history" ]]; then
    hist="${XDG_STATE_HOME:-${HOME}/.local/state}/bootstrap-linux/history"
    [[ "/var/lib/bootstrap-linux/history" -nt "$hist" ]] && hist="/var/lib/bootstrap-linux/history"
  fi

  phase 'History'
  if [[ ! -r "$hist" ]]; then
    result 'missing' 'history' "nothing recorded yet - $hist"
    echo
    return 0
  fi
  [[ "$HISTORY_LINES" =~ ^[0-9]+$ ]] || HISTORY_LINES=10
  printf '  %s%-17s %-8s %-8s %-7s %s%s\n' \
    "$C_DIM" 'when' 'took' 'result' 'i/u/f' 'what moved' "$C_RESET"
  while IFS="$(printf '\t')" read -r epoch code dur trigger tallies changed; do
    [[ -z "$epoch" ]] && continue
    when="$(date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo '?')"
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
  done < <(tail -n "$HISTORY_LINES" "$hist")
  printf '  %s%s run(s), * = unattended%s\n\n' "$C_DIM" "$shown" "$C_RESET"
  return 0
}

# One desktop notification for a run nobody was watching. The timer runs as
# root, which has no session bus of its own, so the message is handed to each
# logged-in user's bus instead - /run/user/<uid>/bus is the session, and a seat
# with nobody logged in simply has none. Best effort throughout: a headless
# server has no notify-send, no bus and no one to tell, and that is not a
# failure worth reporting.
notify_failure() {   # notify_failure <exit-code>
  local rc="$1" body subtitle n_failed bus uid
  [[ "$rc" -ne 0 ]] || return 0
  [[ "$RUN_RECORDING" == "yes" ]] || return 0
  [[ "$DRY_RUN" == "no" ]] || return 0
  [[ "$RUN_INTERACTIVE" == "no" ]] || return 0
  [[ "${SCHEDULE_NOTIFY_ON_FAILURE:-no}" == "yes" ]] || return 0
  command -v notify-send >/dev/null 2>&1 || return 0

  n_failed="$(action_count failed)"
  if [[ "$n_failed" -gt 0 ]]; then
    subtitle="$n_failed step(s) failed"
    body="${RUN_ABORT_MSG:-$(log_hint)}"
  else
    subtitle="aborted, exit $rc"
    body="${RUN_ABORT_MSG:-$(log_hint)}"
  fi

  if [[ "$(id -u)" -ne 0 ]]; then
    notify-send -u critical "bootstrap-linux: $subtitle" "$body" >/dev/null 2>&1 || true
    return 0
  fi
  for bus in /run/user/*/bus; do
    [[ -S "$bus" ]] || continue
    uid="${bus#/run/user/}"; uid="${uid%/bus}"
    sudo -n -u "#${uid}" \
      env "DBUS_SESSION_BUS_ADDRESS=unix:path=${bus}" \
      notify-send -u critical "bootstrap-linux: $subtitle" "$body" >/dev/null 2>&1 || true
  done
  return 0
}

STATUS_RC=0
print_status() {
  local key value stamp ago dur trigger target
  local s_version='' s_finished='' s_duration='' s_exit='' s_interactive='' \
        s_failed='' s_counts='' s_log='' s_error=''

  # The newer of the two records: the timer writes one as root, you write the
  # other, and the question is always "what happened last", not "who ran it".
  target=''
  if [[ -r "$STATE_SYSTEM" && -r "$STATE_USER" ]]; then
    target="$STATE_USER"
    [[ "$STATE_SYSTEM" -nt "$STATE_USER" ]] && target="$STATE_SYSTEM"
  elif [[ -r "$STATE_SYSTEM" ]]; then
    target="$STATE_SYSTEM"
  elif [[ -r "$STATE_USER" ]]; then
    target="$STATE_USER"
  fi

  phase 'Last run'
  if [[ -z "$target" ]]; then
    result 'missing' 'last run' "nothing recorded yet - $STATE_SYSTEM or $STATE_USER"
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
  done < "$target"

  stamp="$(date -d "@${s_finished:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)"
  ago="$(human_seconds $(( $(date +%s) - ${s_finished:-0} )) ) ago"
  dur="$(human_seconds "${s_duration:-0}")"
  trigger='a terminal'
  [[ "$s_interactive" == "no" ]] && trigger='unattended - the systemd timer, or output redirected'

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
  printf '  %-16s%s%s%s\n' 'record' "$C_DIM" "$target" "$C_RESET"
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


# GitHub's unauthenticated API allows 60 requests/hour per source IP - easy to
# spend on one run with two dozen-plus @releases tools, especially behind a
# shared or NAT'd address (WSL included), and each spent request then fails
# every tool queued behind it for the rest of the hour: the ones that already
# got their tag stay installed, the rest silently never appear. An
# authenticated request gets 5000/hour. GITHUB_TOKEN/GH_TOKEN (what `gh`
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

github_latest_tag() {   # github_latest_tag <owner/repo> [tag prefix]
  local -a auth=()
  [[ -n "$GITHUB_AUTH_HEADER" ]] && auth=(-H "$GITHUB_AUTH_HEADER")

  if [[ -z "${2:-}" ]]; then
    curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
      | grep -m1 '"tag_name"' \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true
    return
  fi
  # A repository that releases several products has one "latest" for all of
  # them - bitwarden/clients: web, desktop, browser, cli. Take the newest tag
  # that is the prefix and a bare version, which also skips -rc tags.
  curl -fsSL "${auth[@]}" "https://api.github.com/repos/$1/releases?per_page=50" 2>/dev/null \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | grep -m1 -E "^${2}[0-9]+(\.[0-9]+)*\$" || true
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

# Is there a desktop on this machine?
has_desktop() {
  local dm
  for dm in gdm3 gdm sddm lightdm lxdm xdm slim ly greetd; do
    if dpkg-query -W -f='${Status}' "$dm" 2>/dev/null | grep -q '^install ok installed'; then
      DESKTOP_REASON="display manager: $dm"
      return 0
    fi
  done

  local dir count
  for dir in /usr/share/xsessions /usr/share/wayland-sessions; do
    count=$(find "$dir" -maxdepth 1 -name '*.desktop' 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
      DESKTOP_REASON="$count session file(s) in $dir"
      return 0
    fi
  done

  DESKTOP_REASON="no display manager and no session files"
  return 1
}

# Package state

apt_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'
}

apt_available() {
  apt-cache show "$1" >/dev/null 2>&1
}

flatpak_installed() {
  flatpak info "$1" >/dev/null 2>&1
}

run_priv() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Arguments

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh [options]

  --dry-run          Show what would change, touch nothing.
  --groups a,b       Limit to named groups. Default is every group.
  --list-groups      Print the groups in the manifest and exit.
  --list-packages    Print every package/tool name this script manages and
                     exit - groups and their uv tools, TOOLS, RELEASES and
                     REPOS packages.
  --status           Print what the last real run did and exit. Exits 1 if
                     that run failed, so a check can use it.
  --history[=n]      Print the last n runs (default 10) and what each one
                     moved, and exit.
  --doctor           Check what a login shell actually sees - tools on PATH,
                     shell integration, config drift, the timer - and exit.
                     Changes nothing. Exits 1 if something is wrong.
  --skip-upgrade     Install what is missing, leave installed versions alone.
  --skip-cleanup     Leave cached .deb downloads on disk.
  --skip-schedule    Leave the systemd timer alone.
  --skip-repos       Add no third-party apt sources and install none of
                     their packages. For a host where something else
                     already owns those repositories.
  --skip-vscode-extensions
                     Install none of the VS Code extensions in the manifest.
  --skip-update-check
                     Don't check the GitHub origin for a newer release tag.
  --gui / --no-gui   Override desktop detection instead of probing for it.
  --yes              Pass -y to apt. Implied when not attached to a terminal.
  --version          Print the version and exit.
  -h, --help         This text.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=yes ;;
    --skip-upgrade)  SKIP_UPGRADE=yes ;;
    --skip-cleanup)  SKIP_CLEANUP=yes ;;
    --skip-schedule) SKIP_SCHEDULE=yes ;;
    --status)        STATUS_ONLY=yes ;;
    --doctor)        DOCTOR_ONLY=yes ;;
    --history)       HISTORY_ONLY=yes ;;
    --history=*)     HISTORY_ONLY=yes; HISTORY_LINES="${1#*=}" ;;
    --skip-repos)    SKIP_REPOS=yes ;;
    --skip-vscode-extensions) SKIP_VSCODE_EXT=yes ;;
    --skip-update-check) SKIP_UPDATE_CHECK=yes ;;
    --yes|-y)        ASSUME_YES=yes ;;
    --gui)           GUI_OVERRIDE=yes ;;
    --no-gui)        GUI_OVERRIDE=no ;;
    --groups)        shift; ONLY_GROUPS="${1:-}" ;;
    --groups=*)      ONLY_GROUPS="${1#*=}" ;;
    --list-groups)   LIST_GROUPS=yes ;;
    --list-packages) LIST_PACKAGES=yes ;;
    --version)       echo "$BOOTSTRAP_VERSION"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

[[ -t 0 ]] || ASSUME_YES=yes

if [[ "$STATUS_ONLY" == "yes" ]]; then
  print_status
  exit "$STATUS_RC"
fi

if [[ "$HISTORY_ONLY" == "yes" ]]; then
  print_history
  exit 0
fi

# Manifest

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
# shellcheck source=packages.conf
source "$MANIFEST"

for required in PKG_GROUPS MANUAL HELD TOOLS REPOS RELEASES ZSH_PLUGIN_REPOS \
                DOTNET_ENABLED ZSH_ENABLED NERD_FONT_ENABLED CLAUDE_CODE_ENABLED \
                MISE_ENABLED VSCODE_EXTENSIONS \
                AWSCLI_ENABLED GHOSTTY_ENABLED SCHEDULE_ENABLED HISTORY_SIZE HISTORY_FILE_SIZE; do
  declare -p "$required" >/dev/null 2>&1 || die "manifest is missing \$$required: $MANIFEST"
done

# Release binaries and uv tools land in RELEASE_BIN_DIR, and later steps look for
# them by name - delta for the git config, atuin and carapace for theirs, uv for
# the Python tools. The zsh fragment puts it on a login's PATH; this, on ours.
export PATH="${RELEASE_BIN_DIR:-$HOME/.local/bin}:${PATH}"

if [[ "${LIST_GROUPS:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    desc_var="GROUP_${g}_DESC"
    gui_var="GROUP_${g}_GUI"
    declare -n _apt="GROUP_${g}_APT"
    declare -n _flat="GROUP_${g}_FLATPAK"
    uv_count=0
    if declare -p "GROUP_${g}_UV" >/dev/null 2>&1; then
      declare -n _uvl="GROUP_${g}_UV"; uv_count=${#_uvl[@]}; unset -n _uvl
    fi
    total=$(( ${#_apt[@]} + ${#_flat[@]} + uv_count ))
    gui_tag='               '
    [[ "${!gui_var:-no}" == "yes" ]] && gui_tag='[needs desktop]'
    printf '  %s%-10s%s %-3s packages  %s%s%s  %s\n' \
      "$C_CYAN" "$g" "$C_RESET" "$total" "$C_DIM" "$gui_tag" "$C_RESET" "${!desc_var}"
    unset -n _apt _flat
  done
  echo
  exit 0
fi

if [[ "${LIST_PACKAGES:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    printf '  %s%s%s\n' "$C_CYAN" "$g" "$C_RESET"
    declare -n _apt="GROUP_${g}_APT"
    declare -n _flat="GROUP_${g}_FLATPAK"
    for pkg in "${_apt[@]:-}" "${_flat[@]:-}"; do
      [[ -z "$pkg" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$pkg" "$C_RESET"
    done
    if declare -p "GROUP_${g}_UV" >/dev/null 2>&1; then
      declare -n _uvl="GROUP_${g}_UV"
      for entry in "${_uvl[@]:-}"; do
        [[ -z "$entry" ]] && continue
        printf '    %s%s  (uv tool)%s\n' "$C_DIM" "${entry%%|*}" "$C_RESET"
      done
      unset -n _uvl
    fi
    unset -n _apt _flat
  done
  if [[ "${#TOOLS[@]}" -gt 0 ]]; then
    printf '  %stools (version managers, git clones)%s\n' "$C_CYAN" "$C_RESET"
    for tool in "${TOOLS[@]:-}"; do
      [[ -z "$tool" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$tool" "$C_RESET"
    done
  fi
  if [[ "${#RELEASES[@]}" -gt 0 ]]; then
    printf '  %srelease binaries (~/.local/bin)%s\n' "$C_CYAN" "$C_RESET"
    for entry in "${RELEASES[@]:-}"; do
      [[ -z "$entry" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$entry" "$C_RESET"
    done
  fi
  if [[ "${#REPOS[@]}" -gt 0 ]]; then
    printf '  %srepository packages%s\n' "$C_CYAN" "$C_RESET"
    for repo in "${REPOS[@]:-}"; do
      [[ -z "$repo" ]] && continue
      declare -n _rpkgs="REPO_${repo}_PACKAGES"
      for pkg in "${_rpkgs[@]:-}"; do
        [[ -z "$pkg" ]] && continue
        printf '    %s%s%s\n' "$C_DIM" "$pkg" "$C_RESET"
      done
      unset -n _rpkgs
    done
  fi
  if [[ "${GHOSTTY_ENABLED:-no}" == "yes" && -n "${GHOSTTY_DEB_REPO:-}" ]]; then
    printf '  %scommunity .deb%s\n    %sghostty%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
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

# The zsh function behind `tools`, written to stdout. It takes the table as
# package/command/description triples, so each platform gathers its own rows and
# the part with the quoting is shared - and testable on its own. The rows also
# stay in a global array, so `cheat` can search the list `tools` prints.
#
# printf reuses its format for as many arguments as it is given, so one format
# over a flat array of triples is the whole table. Package dimmed, command
# green, description plain - and no escapes when the output is piped, so
# `tools | rg fd` stays text. Every value is single-quoted, a ' inside one
# included. The replacement goes through a quoted variable: written inline,
# bash's handling of backslashes there garbles it, and 5.2+ would also expand
# an & in it.
emit_tools_function() {   # emit_tools_function [<package> <command> <description>]...
  # A row is emitted single-quoted, so a literal ' has to become '\'' . The
  # replacement is written bare rather than as "$q": bash 3.2 - still what
  # macOS ships as /bin/bash - takes double quotes inside ${x//pat/repl}
  # literally and would bake them into the description.
  local q="'\\''"
  echo '_TOOLS_ROWS=('
  while (( $# >= 3 )); do
    printf "  '%s' '%s' '%s'\n" "${1//\'/$q}" "${2//\'/$q}" "${3//\'/$q}"
    shift 3
  done
  echo ')'
  echo 'tools() {'
  echo '  local d= c= o='
  echo "  [[ -t 1 ]] && d=\$'\\e[2m' c=\$'\\e[32m' o=\$'\\e[0m'"
  echo '  echo'
  echo '  (( ${#_TOOLS_ROWS[@]} )) && printf "  ${d}%-12s${o}  ${c}%-10s${o}  %s\n" "${_TOOLS_ROWS[@]}"'
  echo '  echo'
  echo '}'
}

# Doctor
#
# Every other phase asserts that a package is installed. This one asserts that
# it is in *effect*, which is not the same thing and is where the bugs have
# been: ~/go/bin missing from PATH, an apt fd-find shadowing the real fd, the
# mise shims never reaching a login shell, Tab never getting to fzf-tab. Every
# one was found months later by somebody noticing, because a phase that
# installs a package has no idea whether the shell you type into can see it.
#
# So the checks run inside a real login shell - zsh -lic - which is the
# environment they are about. One probe emitting every fact at once, in about a
# second; a shell per check would take a minute to say the same thing.
#
# It reports and never fixes. The fix is bootstrap.sh itself.

DOCTOR_OK=0
DOCTOR_BROKEN=0
DOCTOR_PROBE_OUT=''
declare -A DOCTOR_CMD=() DOCTOR_ORIGIN=()

doctor_ok()     { DOCTOR_OK=$((DOCTOR_OK + 1)); result 'ok' "$1" "${2:-}"; }
doctor_broken() { DOCTOR_BROKEN=$((DOCTOR_BROKEN + 1)); result 'broken' "$1" "${2:-}"; }
doctor_note()   { result 'present' "$1" "${2:-}"; }

probe_get() { printf '%s\n' "$DOCTOR_PROBE_OUT" | sed -n "s|^$1=||p" | head -1; }

# package -> command and where that command should live, from the table CI
# enforces. Two rows name no single binary of their own (cifs-utils mounts
# through mount, exfatprogs is a pair of mkfs/fsck tools) and two are written
# for a reader rather than for this: zoxide's cell is the `z` function it
# defines, and 7zip's names all three platforms' binaries at once.
doctor_load_tools() {
  local can lx cmd desc
  [[ -r "$SCRIPT_DIR/../tools/cli-parity.conf" ]] || return 0
  # The macos, windows and note columns are read into the throwaway `_` - the
  # fields still have to be counted, they are just not wanted here.
  while IFS='|' read -r can lx _ _ _ cmd desc; do
    can="$(printf '%s' "$can" | tr -d '[:space:]')"
    [[ -z "$can" || "$can" == \#* ]] && continue
    lx="$(printf '%s' "$lx" | tr -d '[:space:]')"
    [[ -z "$lx" || "$lx" == '-' ]] && continue
    case "$can" in
      cifs-utils|exfatprogs) continue ;;
      zoxide) cmd='zoxide' ;;
      # The parity table's cmd cell names all three platforms at once
      # ("7z (macOS: 7zz; Windows: ...)"); apt's own 7zip package puts 7z on
      # PATH, not 7zz - that name is macOS's.
      7zip)   cmd='7z' ;;
      *)      cmd="$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]].*$//')" ;;
    esac
    [[ -z "$cmd" ]] && continue
    DOCTOR_CMD["$can"]="$cmd"
    if [[ "$lx" == '@releases' ]]; then
      DOCTOR_ORIGIN["$can"]='release'
    else
      DOCTOR_ORIGIN["$can"]='apt'
    fi
  done < "$SCRIPT_DIR/../tools/cli-parity.conf"
  return 0
}

doctor_probe() {
  local probe cmds can
  cmds=''
  for can in "${!DOCTOR_CMD[@]}"; do cmds="$cmds ${DOCTOR_CMD[$can]}"; done
  # Not in the cli parity table, but just as load-bearing.
  # gs is here for the gs picker, which steps aside where Ghostscript has the name.
  cmds="$cmds starship atuin carapace mise uv git gh node go java kubectl code gs"

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
print -r -- "fn:tools=$(( $+functions[tools] ))"
print -r -- "tools:rows=$(( ${#_TOOLS_ROWS[@]} / 3 ))"
print -r -- "fn:gb=$(( $+functions[gb] ))"
print -r -- "fn:gs=$(( $+functions[gs] ))"
print -r -- "fn:fkill=$(( $+functions[fkill] ))"
print -r -- "fn:cheat=$(( $+functions[cheat] ))"
print -r -- "fn:y=$(( $+functions[y] ))"
print -r -- "bind:tab=$(bindkey '^I' 2>/dev/null | head -1)"
print -r -- "bind:up=$(bindkey '^[[A' 2>/dev/null | head -1)"
print -r -- "alias:cat=${aliases[cat]:-}"
print -r -- "alias:ls=${aliases[ls]:-}"
PROBE
  } > "$probe"

  # A login shell runs the user's own .zshrc, which can do anything including
  # fail; the probe's lines are what matters, and stderr is not.
  DOCTOR_PROBE_OUT="$(zsh -lic "source '$probe'" 2>/dev/null || true)"
  [[ -n "$DOCTOR_PROBE_OUT" ]]
}

doctor_check_tools() {
  local can cmd path want shims bindir
  shims="${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
  bindir="${RELEASE_BIN_DIR:-$HOME/.local/bin}"
  for can in $(printf '%s\n' "${!DOCTOR_CMD[@]}" | sort); do
    cmd="${DOCTOR_CMD[$can]}"
    path="$(probe_get "resolve:$cmd")"
    if [[ "${DOCTOR_ORIGIN[$can]}" == 'release' ]]; then
      want="${bindir}/${cmd}"
    else
      want="/usr/bin/${cmd}"
    fi
    if [[ -z "$path" ]]; then
      doctor_broken "$cmd" "not on PATH in a login shell (expected $want)"
    elif [[ "$path" == "$want" || "$path" == "/bin/${cmd}" ]]; then
      doctor_ok "$cmd" "$path"
    elif [[ "$path" == "$shims"/* ]]; then
      # A mise shim runs the same program through one more exec, so it is not
      # broken - but a shim for a tool mise does not manage is a leftover.
      doctor_note "$cmd" "a mise shim answers first, ahead of $want"
    else
      doctor_broken "$cmd" "resolves to $path, not $want - something shadows it"
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

  # The probe runs `zsh -lic` explicitly, so it passes even when the account
  # starts bash - which is exactly when none of this reaches a real login.
  doctor_shell="$(getent passwd "$(id -un)" | cut -d: -f7)"
  if [[ "$(basename "${doctor_shell:-}")" == "zsh" ]]; then
    doctor_ok 'login shell' "$doctor_shell"
  else
    doctor_broken 'login shell' "${doctor_shell:-unset}, not zsh - run: chsh -s $(command -v zsh)"
  fi

  [[ "$(probe_get 'env:starship')" == 'yes' ]] \
    && doctor_ok 'starship' 'initialised - STARSHIP_SESSION_KEY is set' \
    || doctor_broken 'starship' 'not initialised in a login shell'

  [[ "$(probe_get 'widget:atuin')" == '1' ]] \
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

  for v in cat ls; do
    if [[ -n "$(probe_get "alias:$v")" ]]; then
      doctor_ok "alias $v" "$(probe_get "alias:$v")"
    else
      doctor_broken "alias $v" 'not aliased - the fragment did not reach this shell'
    fi
  done
}

# A binary can be on PATH, at the right path, and still not run: the wrong
# architecture, a library the distro does not have. doctor_check_tools cannot
# see that. Asking for --version is the cheapest way to make the loader try, and
# any answer at all - even "unknown option", exit 2 - proves it launched; only
# the shell's own exec failures (126 not executable, 127 not found) and a crash
# (132 illegal instruction, 134 abort, 139 segfault) mean it did not. Release
# binaries only: apt's are the distro's to keep working.
doctor_check_launch() {
  local can cmd path rc launched=0
  local -a limit=()
  command -v timeout >/dev/null 2>&1 && limit=(timeout 5)
  for can in $(printf '%s\n' "${!DOCTOR_CMD[@]}" | sort); do
    [[ "${DOCTOR_ORIGIN[$can]}" == 'release' ]] || continue
    cmd="${DOCTOR_CMD[$can]}"
    path="$(probe_get "resolve:$cmd")"
    # Missing or shadowed is doctor_check_tools' finding, not a second one here.
    [[ -n "$path" && -x "$path" ]] || continue
    rc=0
    "${limit[@]}" "$path" --version </dev/null >/dev/null 2>&1 || rc=$?
    case "$rc" in
      126|127|132|134|139) doctor_broken "$cmd launches" "exit $rc from $path --version - wrong architecture, or a library it needs is missing" ;;
      124) doctor_note "$cmd launches" "gave no answer to --version in 5 seconds" ;;
      *)   launched=$((launched + 1)) ;;
    esac
  done
  [[ "$launched" -gt 0 ]] && doctor_ok 'release binaries launch' "$launched answered --version"
  return 0
}

# `tools` and the pickers come from ~/.zshrc.bootstrap and tools-list, so a
# fragment that is deployed but never sourced, or a list that generated empty,
# shows up here as a missing function, not as a broken alias somewhere else.
doctor_check_workflow() {
  local rows fn
  if [[ "$(probe_get 'fn:tools')" != '1' ]]; then
    doctor_broken 'tools' 'no tools function in a login shell'
  else
    rows="$(probe_get 'tools:rows')"
    if [[ "${rows:-0}" -gt 0 ]]; then
      doctor_ok 'tools' "${rows} tools listed"
    else
      doctor_broken 'tools' 'defined, but its list is empty'
    fi
  fi

  if [[ -z "$(probe_get 'resolve:yazi')" ]]; then
    doctor_note 'y' 'yazi is not on PATH, so the y wrapper is not defined'
  elif [[ "$(probe_get 'fn:y')" == '1' ]]; then
    doctor_ok 'y' 'defined'
  else
    doctor_broken 'y' 'not defined in a login shell'
  fi

  if [[ -z "$(probe_get 'resolve:fzf')" ]]; then
    doctor_note 'workflow pickers' 'fzf is not on PATH, so gb, gs, fkill and cheat are not defined'
    return 0
  fi
  for fn in gb fkill cheat; do
    [[ "$(probe_get "fn:$fn")" == '1' ]] \
      && doctor_ok "$fn" 'defined' \
      || doctor_broken "$fn" 'not defined in a login shell'
  done
  if [[ -n "$(probe_get 'resolve:gs')" ]]; then
    doctor_note 'gs' "not defined on purpose - $(probe_get 'resolve:gs') is Ghostscript's, not the stash picker's"
  elif [[ "$(probe_get 'fn:gs')" == '1' ]]; then
    doctor_ok 'gs' 'defined'
  else
    doctor_broken 'gs' 'not defined in a login shell'
  fi
}

# tealdeer keeps its pages in a cache it fills on first use (auto_update in
# tealdeer/config.toml), so an empty cache heals itself and is a note. What is
# worth saying is when it is stale. The directory is read, never asked: even
# `tldr --show-paths` downloads the pages when they are missing, and a doctor
# that changes the machine is not one.
doctor_check_tldr_cache() {
  local dir="${XDG_CACHE_HOME:-$HOME/.cache}/tealdeer/tldr-pages" count
  command -v tldr >/dev/null 2>&1 || return 0   # the config check has said so
  if [[ ! -d "$dir" ]]; then
    doctor_note 'tldr pages' 'not downloaded yet - the first tldr fetches them'
    return 0
  fi
  count="$(find "$dir" -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "${count:-0}" -eq 0 ]]; then
    doctor_note 'tldr pages' "$dir is empty - the next tldr fetches them"
  elif [[ -z "$(find "$dir" -type f -name '*.md' -mtime -30 -print -quit 2>/dev/null)" ]]; then
    doctor_note 'tldr pages' "$count pages, none newer than 30 days - the next tldr refreshes them"
  else
    doctor_ok 'tldr pages' "$count pages in $dir"
  fi
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
  local dir
  for dir in "${RELEASE_BIN_DIR:-$HOME/.local/bin}" "${HOME}/go/bin"; do
    case ":$path:" in
      *":${dir}:"*) doctor_ok "PATH $dir" 'present' ;;
      *) doctor_broken "PATH $dir" 'missing from a login shell PATH' ;;
    esac
  done

  # The fragment itself only adds this once `dotnet tool install -g` has
  # created it - nothing else does - so its absence from both disk and PATH
  # is the fragment working as intended, not broken.
  dir="${HOME}/.dotnet/tools"
  if [[ -d "$dir" ]]; then
    case ":$path:" in
      *":${dir}:"*) doctor_ok "PATH $dir" 'present' ;;
      *) doctor_broken "PATH $dir" 'missing from a login shell PATH' ;;
    esac
  fi
}

# btop_theme_of <btop.conf> - the theme named in it, empty when the file or the
# key is absent. btop.conf is `key = "value"` lines, not YAML, so this is sed's
# job rather than yq's. Read by the doctor as well as the phase that sets it.
btop_theme_of() {
  [[ -f "$1" ]] || return 0
  sed -n 's/^color_theme[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" \
    | tail -1
}

# k9s_paths - the config file and skins directory, into _K9S_CFG and _K9S_SKINS.
# `k9s info` is the only answer that is right everywhere: the directory moved
# to XDG in 0.30 and differs by platform regardless. The output is coloured,
# hence the escape strip, and k9s has spelled the line both Config and
# Configuration. Defined up here because the doctor runs and exits long before
# the phase that deploys the skin.
k9s_paths() {
  local info
  info="$(k9s info 2>/dev/null | sed $'s/\033\[[0-9;]*m//g')"
  _K9S_CFG="$(printf '%s\n' "$info" | sed -n 's/^Config[a-z]*:[[:space:]]*//p' | head -1)"
  _K9S_SKINS="$(printf '%s\n' "$info" | sed -n 's/^Skins:[[:space:]]*//p' | head -1)"
  [[ -n "$_K9S_SKINS" || -z "$_K9S_CFG" ]] || _K9S_SKINS="$(dirname "$_K9S_CFG")/skins"
  [[ -n "$_K9S_CFG" ]]
}

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

# The three themes the bootstrap activates rather than owns. The failure worth
# catching here is a theme file deployed with nothing naming it: every install
# step says ok, and the colours never change.
doctor_check_themes() {
  local skin lazygit_dir theme
  if ! command -v k9s >/dev/null 2>&1; then
    :
  elif ! k9s_paths; then
    doctor_broken 'k9s skin' 'k9s info named no config file'
  else
    doctor_config 'k9s skin' "${SCRIPT_DIR}/../k9s/skins/catppuccin-mocha.yaml" \
                  "${_K9S_SKINS}/catppuccin-mocha.yaml"
    skin=''
    [[ -f "$_K9S_CFG" ]] && command -v yq >/dev/null 2>&1 \
      && skin="$(yq '.k9s.ui.skin // ""' "$_K9S_CFG" 2>/dev/null || true)"
    case "$skin" in
      catppuccin-mocha) doctor_ok 'k9s ui.skin' 'catppuccin-mocha' ;;
      '') doctor_broken 'k9s ui.skin' "unset in $_K9S_CFG - nothing tells k9s to use the skin" ;;
      *)  doctor_note 'k9s ui.skin' "$skin - yours, not the repo's" ;;
    esac
  fi

  if command -v lazygit >/dev/null 2>&1; then
    lazygit_dir="$(lazygit --print-config-dir 2>/dev/null || true)"
    if [[ -z "$lazygit_dir" ]]; then
      doctor_broken 'lazygit config' 'lazygit --print-config-dir said nothing'
    else
      doctor_config 'lazygit config' "${SCRIPT_DIR}/../lazygit/config.yml" \
                    "${lazygit_dir}/config.yml"
    fi
  fi

  if command -v btop >/dev/null 2>&1; then
    doctor_config 'btop theme' "${SCRIPT_DIR}/../btop/themes/catppuccin_mocha.theme" \
                  "${XDG_CONFIG_HOME:-$HOME/.config}/btop/themes/catppuccin_mocha.theme"
    theme="$(btop_theme_of "${XDG_CONFIG_HOME:-$HOME/.config}/btop/btop.conf")"
    case "$theme" in
      catppuccin_mocha) doctor_ok 'btop color_theme' 'catppuccin_mocha' ;;
      ''|Default) doctor_broken 'btop color_theme' 'unset in btop.conf - nothing tells btop to use the theme' ;;
      *) doctor_note 'btop color_theme' "$theme - yours, not the repo's" ;;
    esac
  fi
}

doctor_check_configs() {
  local bat_cfg
  doctor_config 'starship.toml' "${SCRIPT_DIR}/../starship.toml" "${HOME}/.config/starship.toml"
  doctor_config 'atuin config' "${SCRIPT_DIR}/../atuin/config.toml" "${HOME}/.config/atuin/config.toml"

  if bat_cfg="$(bat --config-dir 2>/dev/null)" && [[ -n "$bat_cfg" ]]; then
    doctor_config 'bat config' "${SCRIPT_DIR}/../bat/config" "${bat_cfg}/config"
  else
    doctor_broken 'bat config' 'bat is not installed, so nothing reads the theme'
  fi

  if command -v tldr >/dev/null 2>&1; then
    doctor_config 'tealdeer config' "${SCRIPT_DIR}/../tealdeer/config.toml" \
                  "${XDG_CONFIG_HOME:-$HOME/.config}/tealdeer/config.toml"
  else
    doctor_broken 'tealdeer config' 'tldr is not installed'
  fi
  doctor_check_tldr_cache

  if [[ "${GHOSTTY_ENABLED:-no}" == "yes" ]]; then
    [[ -r "${HOME}/.config/ghostty/config" ]] \
      && doctor_ok 'ghostty config' "${HOME}/.config/ghostty/config" \
      || doctor_note 'ghostty config' 'not deployed - a desktop-only phase'
  fi
}

doctor_check_schedule() {
  local unit="${SCHEDULE_UNIT_NAME:-bootstrap-linux}"
  if [[ "${SCHEDULE_ENABLED:-no}" != "yes" ]]; then
    doctor_note 'systemd timer' 'SCHEDULE_ENABLED is not yes'
  elif [[ ! -d /run/systemd/system ]]; then
    doctor_note 'systemd timer' 'systemd is not running as init - the timer cannot exist here'
  elif [[ ! -f "/etc/systemd/system/${unit}.timer" ]]; then
    doctor_broken 'systemd timer' "no ${unit}.timer - the daily run has never been installed"
  elif systemctl is-active --quiet "${unit}.timer" 2>/dev/null; then
    doctor_ok 'systemd timer' "${unit}.timer is active"
  else
    doctor_broken 'systemd timer' "${unit}.timer exists but is not active"
  fi
}

run_doctor() {
  doctor_load_tools

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
  doctor_check_launch

  phase 'Doctor - shell integration'
  doctor_check_shell
  doctor_check_workflow

  phase 'Doctor - runtimes and PATH'
  doctor_check_runtimes

  phase 'Doctor - deployed config'
  doctor_check_configs
  doctor_check_themes

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

# What the machine has, name and version, one per line: every dpkg package,
# because `apt-get upgrade` moves plenty this script never names, plus the
# flatpaks.
# Each listing is allowed to fail: flatpak may not be installed at all, and a
# snapshot taken for the history is never worth ending a run over - which, with
# `set -e` and a pipeline, is exactly what a non-zero exit here would do.
pkg_snapshot() {   # pkg_snapshot <file>
  {
    dpkg-query -W -f '${Package} ${Version}\n' 2>/dev/null || true
    if command -v flatpak >/dev/null 2>&1; then
      flatpak list --columns=application,version 2>/dev/null || true
    fi
  } | awk 'NF >= 2 { print $1, $2 }' | sort > "$1" || true
  return 0
}

snapshot_before() {
  [[ "$DRY_RUN" == "no" ]] || return 0
  command -v dpkg-query >/dev/null 2>&1 || return 0
  mktemp_tracked SNAP_BEFORE "${TMPDIR:-/tmp}/bootstrap-before.XXXXXX"
  pkg_snapshot "$SNAP_BEFORE"
  return 0
}

# Everything that moved between the two snapshots, which is what the upgrade
# actually did as opposed to what it said while scrolling past. A dist-upgrade
# can move a hundred packages, so the list is capped at something readable and
# says how many it left out.
snapshot_after() {
  local snap_after count
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
  if [[ -n "$RUN_CHANGED" ]]; then
    count="$(awk -F', ' '{ print NF }' <<< "$RUN_CHANGED")"
    if [[ "$count" -gt 8 ]]; then
      RUN_CHANGED="$(cut -d',' -f1-8 <<< "$RUN_CHANGED"), +$(( count - 8 )) more"
    fi
    result 'present' 'versions moved' "$RUN_CHANGED"
  fi
  return 0
}

# Preflight
#
# Past this line the run counts: the EXIT trap records what happened, whether
# it gets to the summary or dies in the middle.

[[ "$DOCTOR_ONLY" == "yes" ]] || RUN_RECORDING=yes

phase 'Preflight'

command -v apt-get >/dev/null 2>&1 || die "this script targets Debian-family systems (no apt-get found)"

DISTRO="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  DISTRO="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
fi

printf '  %-16s%s\n' 'bootstrap' "v$BOOTSTRAP_VERSION"
printf '  %-16s%s\n' 'distro' "$DISTRO"
printf '  %-16s%s\n' 'user' "$(id -un) (uid $(id -u))"
check_bootstrap_update

if [[ "$GUI_OVERRIDE" == "auto" ]]; then
  if has_desktop; then HAS_GUI=yes; else HAS_GUI=no; fi
  GUI_NOTE="$DESKTOP_REASON"
else
  HAS_GUI="$GUI_OVERRIDE"
  GUI_NOTE="forced with --${GUI_OVERRIDE/yes/gui}"
  [[ "$GUI_OVERRIDE" == "no" ]] && GUI_NOTE="forced with --no-gui"
fi

if [[ "$HAS_GUI" == "yes" ]]; then
  printf '  %-16s%syes%s  %s(%s)%s\n' 'desktop' "$C_GREEN" "$C_RESET" "$C_DIM" "$GUI_NOTE" "$C_RESET"
else
  printf '  %-16s%sno%s   %s(%s)%s\n' 'desktop' "$C_YELLOW" "$C_RESET" "$C_DIM" "$GUI_NOTE" "$C_RESET"
  printf '  %-16s%s%s%s\n' '' "$C_DIM" 'groups needing a desktop will be skipped' "$C_RESET"
fi

if grep -qi microsoft /proc/version 2>/dev/null; then
  printf '  %-16s%s%s%s\n' 'note' "$C_DIM" 'running under WSL' "$C_RESET"
fi

[[ "$DRY_RUN" == "yes" ]] && printf '  %-16s%s%s%s\n' 'mode' "$C_BLUE" 'dry run - nothing will change' "$C_RESET"

APT_OPTS=()
[[ "$ASSUME_YES" == "yes" ]] && APT_OPTS+=(-y)

if [[ "$DRY_RUN" == "no" ]]; then
  printf '  %-16s' 'apt index'
  if run_priv apt-get update -qq >/dev/null 2>&1; then
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

if [[ "$DOCTOR_ONLY" == "yes" ]]; then
  run_doctor
  exit $?
fi

# Packages

selected=("${PKG_GROUPS[@]}")
if [[ -n "$ONLY_GROUPS" ]]; then
  IFS=',' read -r -a selected <<< "$ONLY_GROUPS"
  for g in "${selected[@]}"; do
    printf '%s\n' "${PKG_GROUPS[@]}" | grep -qx "$g" || die "unknown group: $g (try --list-groups)"
  done
fi

install_apt() {
  local pkg="$1" group="$2"
  if apt_installed "$pkg"; then
    local version
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$pkg" "$version"
      return
    fi
    result 'current' "$pkg" "$version"
    return
  fi
  if ! apt_available "$pkg"; then
    if [[ "$DRY_RUN" == "yes" ]]; then
      result 'missing' "$pkg" 'not in the index yet - may come from a repo this run would add'
    else
      result 'missing' "$pkg" 'not carried by this release'
    fi
    return
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$pkg"
    return
  fi
  if run_priv apt-get install "${APT_OPTS[@]}" -qq "$pkg" >/dev/null 2>&1; then
    result 'installed' "$pkg" "$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  else
    result 'failed' "$pkg" 'apt-get install failed'
  fi
}

install_flatpak() {
  local ref="$1"
  if ! command -v flatpak >/dev/null 2>&1; then
    result 'missing' "$ref" 'flatpak not installed'
    return
  fi
  if flatpak_installed "$ref"; then
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$ref"
    else
      result 'current' "$ref"
    fi
    return
  fi
  # Flathub builds some apps for x86_64 only - Blender, Zoom, Bruno - and on
  # arm64 their install failed like a real error. Missing on this arch but
  # present on x86_64 is the case to name; anything else (offline, no remote)
  # falls through to the install and its own failure.
  if ! flatpak remote-info flathub "$ref" >/dev/null 2>&1 </dev/null &&
     flatpak remote-info --arch=x86_64 flathub "$ref" >/dev/null 2>&1 </dev/null; then
    result 'missing' "$ref" "Flathub has no ${UNAME_ARCH} build"
    return
  fi
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$ref" 'flathub'
    return
  fi
  if flatpak install -y --noninteractive flathub "$ref" >/dev/null 2>&1; then
    result 'installed' "$ref" 'flathub'
  else
    result 'failed' "$ref" 'flatpak install failed'
  fi
}

# Third-party repositories

KEYRING_DIR=/etc/apt/keyrings
REPOS_CHANGED=no

setup_repo() {
  local name="$1"
  local desc_var="REPO_${name}_DESC" gui_var="REPO_${name}_GUI"
  local key_var="REPO_${name}_KEY_URL" uri_var="REPO_${name}_URI"
  local suites_var="REPO_${name}_SUITES" comp_var="REPO_${name}_COMPONENTS"
  local desc="${!desc_var:-$name}"

  if [[ "${!gui_var:-no}" == "yes" && "$HAS_GUI" != "yes" ]]; then
    result 'no-gui' "$desc" 'repository skipped, needs a desktop'
    return
  fi

  # A vendor can lag a distribution release: packages.microsoft.com had no
  # azure-cli suite for trixie, so apt-get update failed on every run.
  # REPO_<name>_CODENAME_MAP entries (release:published) point {CODENAME} at
  # the release the vendor does publish.
  local codename="$OS_CODENAME" entry
  declare -n _cmap="REPO_${name}_CODENAME_MAP"
  for entry in "${_cmap[@]:-}"; do
    [[ "${entry%%:*}" == "$OS_CODENAME" ]] && codename="${entry#*:}"
  done
  unset -n _cmap

  local key_url="${!key_var}" uri="${!uri_var}" suites="${!suites_var}"
  key_url="${key_url//\{ID\}/$OS_ID}"; key_url="${key_url//\{CODENAME\}/$codename}"
  uri="${uri//\{ID\}/$OS_ID}";         uri="${uri//\{CODENAME\}/$codename}"
  suites="${suites//\{ID\}/$OS_ID}";   suites="${suites//\{CODENAME\}/$codename}"

  local keyring="${KEYRING_DIR}/${name}.gpg"
  local sources="/etc/apt/sources.list.d/${name}.sources"

  local want
  if [[ -z "${!comp_var}" ]]; then
    want="$(printf 'Types: deb\nURIs: %s\nSuites: %s\nArchitectures: %s\nSigned-By: %s\n' \
      "$uri" "$suites" "$DPKG_ARCH" "$keyring")"
  else
    want="$(printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n' \
      "$uri" "$suites" "${!comp_var}" "$DPKG_ARCH" "$keyring")"
  fi

  if [[ -f "$sources" && -s "$keyring" ]] && [[ "$(cat "$sources" 2>/dev/null)" == "$want" ]]; then
    result 'current' "repo: $desc" "$sources"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "repo: $desc" "$uri $suites"
    return
  fi

  run_priv install -m 0755 -d "$KEYRING_DIR"
  local keytmp keyok=no
  mktemp_tracked keytmp
  if curl -fsSL "$key_url" -o "$keytmp" 2>/dev/null; then
    # Most vendors publish an ASCII-armoured key; GitHub CLI publishes a binary
    # keyring, which gpg --dearmor rejects. Only the armoured kind is converted.
    if grep -q -- '-----BEGIN PGP' "$keytmp"; then
      run_priv gpg --dearmor --yes -o "$keyring" < "$keytmp" 2>/dev/null && keyok=yes
    else
      run_priv install -m 0644 "$keytmp" "$keyring" && keyok=yes
    fi
  fi
  rm -f "$keytmp"
  if [[ "$keyok" != "yes" ]]; then
    result 'failed' "repo: $desc" "could not fetch or dearmour $key_url"
    return
  fi
  run_priv chmod a+r "$keyring"
  if printf '%s\n' "$want" | run_priv tee "$sources" >/dev/null; then
    result 'installed' "repo: $desc" "$sources"
    REPOS_CHANGED=yes
  else
    result 'failed' "repo: $desc" "could not write $sources"
  fi
}

snapshot_before

phase 'Repositories - third-party apt sources'

DPKG_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
UNAME_ARCH="$(uname -m 2>/dev/null || echo x86_64)"
case "$UNAME_ARCH" in
  aarch64|arm64) GORELEASER_ARCH=arm64 ;;
  *)             GORELEASER_ARCH=x86_64 ;;
esac
OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-debian}")"
OS_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-stable}")"
OS_VERSION_ID="$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")"

# --skip-repos is for a host where something else already owns these
# repositories. Two definitions of one repo with different Signed-By keyrings
# is not a duplicate apt tolerates: it refuses to read ANY source, so every
# later package lookup fails. Seen on a Pi whose Docker repo is managed by
# Ansible with docker.asc while this script writes docker.gpg.
if [[ "$SKIP_REPOS" == "yes" ]]; then
  result 'skipped' 'third-party repositories' '--skip-repos'
else
  for repo in "${REPOS[@]:-}"; do
    [[ -z "$repo" ]] && continue
    setup_repo "$repo"
  done

  if [[ "$REPOS_CHANGED" == "yes" && "$DRY_RUN" == "no" ]]; then
    if run_priv apt-get update -qq >/dev/null 2>&1; then
      result 'current' 'apt index' 'refreshed for new repositories'
    else
      result 'failed' 'apt index' 'apt-get update failed after adding repositories'
    fi
  fi
fi

phase 'Repository packages'

if [[ "$SKIP_REPOS" == "yes" ]]; then
  result 'skipped' 'repository packages' '--skip-repos'
else
  for repo in "${REPOS[@]:-}"; do
    [[ -z "$repo" ]] && continue
    gui_var="REPO_${repo}_GUI"
    desc_var="REPO_${repo}_DESC"
    if [[ "${!gui_var:-no}" == "yes" && "$HAS_GUI" != "yes" ]]; then
      result 'no-gui' "${!desc_var:-$repo}" 'needs a desktop, none detected'
      continue
    fi
    declare -n _rpkgs="REPO_${repo}_PACKAGES"
    for pkg in "${_rpkgs[@]:-}"; do
      [[ -z "$pkg" ]] && continue
      install_apt "$pkg" "$repo"
    done
    unset -n _rpkgs
  done
fi

for group in "${selected[@]}"; do
  desc_var="GROUP_${group}_DESC"
  gui_var="GROUP_${group}_GUI"
  needs_gui="${!gui_var:-no}"

  phase "$group - ${!desc_var}"

  if [[ "$needs_gui" == "yes" && "$HAS_GUI" != "yes" ]]; then
    eval "pkgs=(\"\${GROUP_${group}_APT[@]:-}\" \"\${GROUP_${group}_FLATPAK[@]:-}\")"
    for pkg in "${pkgs[@]}"; do
      [[ -z "$pkg" ]] && continue
      result 'no-gui' "$pkg" 'needs a desktop, none detected'
    done
    continue
  fi

  eval "apt_pkgs=(\"\${GROUP_${group}_APT[@]:-}\")"
  for pkg in "${apt_pkgs[@]}"; do
    [[ -z "$pkg" ]] && continue
    install_apt "$pkg" "$group"
  done

  eval "flat_pkgs=(\"\${GROUP_${group}_FLATPAK[@]:-}\")"
  for ref in "${flat_pkgs[@]}"; do
    [[ -z "$ref" ]] && continue
    install_flatpak "$ref"
  done
done

# Upgrades

snapshot_after_upgrades=yes

apt_pending_count() {
  apt-get --just-print upgrade 2>/dev/null | grep -c '^Inst ' || true
}

flatpak_commits() {
  flatpak list --columns=application,active 2>/dev/null | sort || true
}

if [[ "$SKIP_UPGRADE" == "yes" ]]; then
  phase 'Upgrades - skipped (--skip-upgrade)'
elif [[ "$DRY_RUN" == "yes" ]]; then
  phase 'Upgrades'
  pending="$(apt_pending_count)"
  if [[ "$pending" -eq 0 ]]; then
    result 'current' 'apt packages' 'nothing pending'
  else
    result 'would-upgrade' 'apt packages' "$pending pending"
  fi
  if command -v flatpak >/dev/null 2>&1; then
    result 'would-upgrade' 'flatpak apps' 'flatpak update'
  fi
else
  phase 'Upgrades'
  pending="$(apt_pending_count)"
  if [[ "$pending" -eq 0 ]]; then
    result 'current' 'apt packages' 'nothing pending'
  elif run_priv apt-get upgrade "${APT_OPTS[@]}" -qq >/dev/null 2>&1; then
    result 'upgraded' 'apt packages' "$pending package(s)"
  else
    result 'failed' 'apt packages' 'apt-get upgrade failed'
  fi
  if command -v flatpak >/dev/null 2>&1; then
    flatpak_before="$(flatpak_commits)"
    if flatpak update -y --noninteractive >/dev/null 2>&1; then
      flatpak_after="$(flatpak_commits)"
      if [[ "$flatpak_before" == "$flatpak_after" ]]; then
        result 'current' 'flatpak apps' 'flathub'
      else
        changed="$(comm -13 <(printf '%s\n' "$flatpak_before") <(printf '%s\n' "$flatpak_after") | grep -c . || true)"
        result 'upgraded' 'flatpak apps' "$changed ref(s)"
      fi
    else
      result 'failed' 'flatpak apps' 'flatpak update failed'
    fi
  fi
fi

[[ "${snapshot_after_upgrades:-no}" == "yes" ]] && snapshot_after

# Housekeeping
#
# apt keeps every .deb it downloads in /var/cache/apt/archives and never
# removes one: on a machine that upgrades itself nightly from the timer that is
# the whole of every package it has ever installed, sitting in a directory
# nobody looks at. Pruning by age is the apt-get counterpart of
# `brew cleanup --prune=N` on macOS - a cached .deb is a download, and a
# download can always be fetched again.
#
# Everything that would *uninstall* something is reported and never run, the
# same line this script takes with HELD: `apt-get autoremove` is usually right
# about orphaned packages and old kernels, and "usually" is not good enough to
# do unattended at 04:20.

if [[ "$SKIP_CLEANUP" == "yes" ]]; then
  phase 'Housekeeping - skipped (--skip-cleanup)'
elif [[ "${APT_CLEANUP_ENABLED:-no}" != "yes" ]]; then
  phase 'Housekeeping - disabled in the manifest'
else
  phase 'Housekeeping - cached downloads, and what is no longer needed'

  PRUNE_DAYS="${APT_CLEANUP_PRUNE_DAYS:-30}"
  APT_CACHE=/var/cache/apt/archives

  if [[ -d "$APT_CACHE" ]]; then
    # GNU find: -printf is not POSIX, and this file only ever runs on Debian.
    stale_bytes="$(find "$APT_CACHE" -maxdepth 1 -type f -name '*.deb' \
                     -mtime "+${PRUNE_DAYS}" -printf '%s\n' 2>/dev/null \
                     | awk '{t += $1} END {printf "%d", t}')"
    stale_debs="$(find "$APT_CACHE" -maxdepth 1 -type f -name '*.deb' \
                    -mtime "+${PRUNE_DAYS}" 2>/dev/null | grep -c . || true)"
    stale_mb="$(awk -v b="${stale_bytes:-0}" 'BEGIN { printf "%.1f MB", b / 1048576 }')"

    if [[ "${stale_debs:-0}" -eq 0 ]]; then
      result 'current' 'apt cache' "nothing cached over ${PRUNE_DAYS} days"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-upgrade' 'apt cache' "$stale_debs .deb(s), $stale_mb to reclaim"
    elif run_priv find "$APT_CACHE" -maxdepth 1 -type f -name '*.deb' \
           -mtime "+${PRUNE_DAYS}" -delete 2>/dev/null; then
      result 'upgraded' 'apt cache' "$stale_debs .deb(s) removed, $stale_mb reclaimed"
    else
      result 'failed' 'apt cache' "could not prune $APT_CACHE"
    fi
  fi

  # Reported, never run. --dry-run needs no privileges and changes nothing.
  orphans="$(apt-get autoremove --dry-run 2>/dev/null \
               | sed -n 's/^Remv \([^ ]*\).*/\1/p' | tr '\n' ' ')"
  if [[ -n "${orphans// /}" ]]; then
    result 'present' 'unused packages' "${orphans}- apt autoremove, if you agree"
  fi

  # No flatpak equivalent of the apt block above: `uninstall` has never had a
  # --dry-run - that flag exists only on `flatpak prune`, which prunes the
  # OSTree object store, not installed-but-unused runtime refs. The nearest
  # real preview would be reading `--unused`'s own confirmation prompt, but
  # that prompt defaults to yes on --noninteractive and on EOF, so scripting
  # around it risks doing the removal this phase promises never to do.
  # `flatpak uninstall --unused` by hand is still the way to check.

  # The journal is where every unattended run's output ends up, and it is the
  # one thing here that grows without anybody installing anything. Reported
  # with the command, not vacuumed: the journal is the whole system's, not ours.
  if command -v journalctl >/dev/null 2>&1; then
    # journalctl exits non-zero on WSL and anywhere else the journal is not
    # persistent (empty or no /var/log/journal) - stderr goes to /dev/null,
    # so under pipefail that killed the whole run here without a word.
    journal_size="$(journalctl --disk-usage 2>/dev/null \
                      | sed -n 's/.*take up \([0-9.]*[KMGT]*\).*/\1/p' || true)"
    if [[ -n "$journal_size" ]]; then
      result 'present' 'journal' "$journal_size - journalctl --vacuum-time=30d to trim"
    fi
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

# .NET SDK

if [[ "${DOTNET_ENABLED:-no}" != "yes" ]]; then
  phase 'dotnet - disabled in the manifest'
else
  phase 'dotnet - SDK from the vendor script'
  dotnet_exe="${DOTNET_DIR}/dotnet"
  if [[ -x "$dotnet_exe" ]]; then
    versions="$("$dotnet_exe" --list-sdks 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' 'dotnet SDK' "${versions:-present}"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-upgrade' 'dotnet SDK' "channel ${DOTNET_CHANNEL}, have ${versions:-none}"
    else
      mktemp_tracked tmp_script
      if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp_script" 2>/dev/null &&
         bash "$tmp_script" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_DIR" >/dev/null 2>&1; then
        after="$("$dotnet_exe" --list-sdks 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
        if [[ "$versions" == "$after" ]]; then
          result 'current' 'dotnet SDK' "$after"
        else
          result 'upgraded' 'dotnet SDK' "$versions -> $after"
        fi
      else
        result 'failed' 'dotnet SDK' 'dotnet-install.sh failed'
      fi
      rm -f "$tmp_script"
    fi
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'dotnet SDK' "channel ${DOTNET_CHANNEL} into ${DOTNET_DIR}"
  else
    mktemp_tracked tmp_script
    if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp_script" 2>/dev/null &&
       bash "$tmp_script" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_DIR" >/dev/null 2>&1; then
      result 'installed' 'dotnet SDK' "$("$dotnet_exe" --list-sdks 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
    else
      result 'failed' 'dotnet SDK' 'dotnet-install.sh failed'
    fi
    rm -f "$tmp_script"
  fi
fi

# Release binaries
# github_latest_tag is defined near the top, alongside check_bootstrap_update
# which is its other caller.

binary_version() {
  local bin="$1" out v a
  local -a attempts=('--version' 'version --short' 'version')
  # RELEASE_<name>_VERSION_ARGS, for a binary that answers the guesses above
  # with some other program's version.
  [[ -n "${2:-}" ]] && attempts=("$2")

  for a in "${attempts[@]}"; do
    # shellcheck disable=SC2086
    out="$("$bin" $a 2>/dev/null || true)"

    v="$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

    if [[ -n "$v" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done
}

install_release_bins() {
  local b found
  for b in $1; do
    found="$(find . -type f -name "$b" -print -quit)"
    [[ -n "$found" ]] || return 1
    install -m 0755 "$found" "${RELEASE_BIN_DIR}/$b" || return 1
  done
}

unpack_asset() {
  local url="$1" file="$2" binname="$3"
  case "$url" in
    *.zip)    unzip -q "$file" ;;
    *.tar.gz|*.tgz) tar -xzf "$file" ;;
    *.tar.xz) tar -xJf "$file" ;;
    *[!./]) cp "$file" "$binname" ;;
    *)        return 1 ;;
  esac
}

install_release() {
  local name="$1"
  local repo_var="RELEASE_${name}_REPO"
  local bin_var="RELEASE_${name}_BIN" asset_var="RELEASE_${name}_ASSET"
  local repo="${!repo_var}"
  local binname="${!bin_var}" asset="${!asset_var}"
  local bins_var="RELEASE_${name}_BINS"
  local bins="${!bins_var:-$binname}"
  local verargs_var="RELEASE_${name}_VERSION_ARGS"
  local verargs="${!verargs_var:-}"
  local target="${RELEASE_BIN_DIR}/${binname}"

  local have=""
  [[ -x "$target" ]] && have="$(binary_version "$target" "$verargs")"

  if [[ -n "$have" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' "$name" "$have"
    return
  fi

  local tag want
  local prefix_var="RELEASE_${name}_TAG_PREFIX"
  tag="$(github_latest_tag "$repo" "${!prefix_var:-}")"
  if [[ -z "$tag" ]]; then
    if [[ -n "$have" ]]; then
      result 'current' "$name" "$have (could not reach the GitHub API)"
    else
      result 'failed' "$name" "could not reach the GitHub API for $repo"
    fi
    return
  fi
  # Most tags are v1.2.3 or 1.2.3; a few carry the project name (jq-1.8.2,
  # gping-v1.21.0), and the binary reports only the number.
  want="${tag#v}"
  [[ "$want" =~ ^[0-9] ]] || want="$(printf '%s' "$tag" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"

  if [[ "$have" == "$want" ]]; then
    result 'current' "$name" "$have"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    if [[ -n "$have" ]]; then
      result 'would-upgrade' "$name" "$have -> $want"
    else
      result 'would-install' "$name" "$want into $RELEASE_BIN_DIR"
    fi
    return
  fi

  # RELEASE_<name>_ASSET_<dpkg arch>, for upstreams that name one architecture's
  # file with the architecture and the other without it.
  local asset_arch_var="RELEASE_${name}_ASSET_${DPKG_ARCH}"
  [[ -n "${!asset_arch_var:-}" ]] && asset="${!asset_arch_var}"

  local url_var="RELEASE_${name}_URL"
  local url="${!url_var:-}"
  [[ -z "$url" ]] && url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  url="${url//\{ARCH\}/$DPKG_ARCH}"
  url="${url//\{UNAME_ARCH\}/$UNAME_ARCH}"
  url="${url//\{GORELEASER_ARCH\}/$GORELEASER_ARCH}"
  url="${url//\{TAG\}/$tag}"
  url="${url//\{VERSION\}/$want}"

  local tmp
  mktemp_tracked tmp -d
  if (
    cd "$tmp" &&
    curl -fsSL -o asset "$url" 2>curl.err &&
    unpack_asset "$url" asset "$binname" &&
    mkdir -p "$RELEASE_BIN_DIR" &&
    install_release_bins "$bins"
  ); then
    local now
    now="$(binary_version "$target" "$verargs")"
    if [[ -z "$have" ]]; then
      result 'installed' "$name" "${now:-$want}"
    elif [[ "$now" == "$have" ]]; then
      result 'current' "$name" "$have (release $tag carries the same build)"
    else
      result 'upgraded' "$name" "$have -> ${now:-$want}"
    fi
  else
    local why=""
    [[ -s "$tmp/curl.err" ]] && why="$(tail -1 "$tmp/curl.err" | sed 's/^curl: //')"
    result 'failed' "$name" "${why:-could not fetch or unpack}: $url"
  fi
  rm -rf "$tmp"
}

if [[ "${#RELEASES[@]}" -gt 0 ]]; then
  phase 'Release binaries - static builds in ~/.local/bin'
  for entry in "${RELEASES[@]:-}"; do
    [[ -z "$entry" ]] && continue
    install_release "$entry"
  done
fi

# Python tools - uv tool, per group

uv_tool_version() {   # uv_tool_version <name> - the installed version, or nothing
  uv tool list 2>/dev/null | awk -v n="$1" '$1 == n { sub(/^v/, "", $2); print $2; exit }'
}

uv_entries=()
for group in "${selected[@]}"; do
  gui_var="GROUP_${group}_GUI"
  [[ "${!gui_var:-no}" == "yes" && "$HAS_GUI" != "yes" ]] && continue
  declare -p "GROUP_${group}_UV" >/dev/null 2>&1 || continue
  declare -n _uvl="GROUP_${group}_UV"
  for entry in "${_uvl[@]:-}"; do
    [[ -n "$entry" ]] && uv_entries+=("$entry")
  done
  unset -n _uvl
done

if [[ "${#uv_entries[@]}" -gt 0 ]]; then
  phase 'Python tools - uv tool, one environment each'
  if ! command -v uv >/dev/null 2>&1; then
    result 'missing' 'uv tools' 'uv is not installed'
  else
    for entry in "${uv_entries[@]}"; do
      tool="${entry%%|*}"
      tool_args=""
      [[ "$entry" == *"|"* ]] && tool_args="${entry#*|}"
      have="$(uv_tool_version "$tool")"
      if [[ -n "$have" && "$SKIP_UPGRADE" == "yes" ]]; then
        result 'skipped' "$tool" "$have - --skip-upgrade"
      elif [[ "$DRY_RUN" == "yes" ]]; then
        if [[ -n "$have" ]]; then
          result 'present' "$tool" "$have - would run uv tool upgrade"
        else
          result 'would-install' "$tool" "uv tool install $tool${tool_args:+ $tool_args}"
        fi
      elif [[ -z "$have" ]]; then
        # shellcheck disable=SC2086  # tool_args is a list of flags, split on purpose
        if uv tool install --quiet "$tool" $tool_args >/dev/null 2>&1; then
          result 'installed' "$tool" "$(uv_tool_version "$tool")"
        else
          result 'failed' "$tool" "uv tool install $tool failed"
        fi
      elif uv tool upgrade --quiet "$tool" >/dev/null 2>&1; then
        now="$(uv_tool_version "$tool")"
        if [[ "$now" == "$have" ]]; then
          result 'current' "$tool" "$have"
        else
          result 'upgraded' "$tool" "$have -> $now"
        fi
      else
        result 'failed' "$tool" "uv tool upgrade $tool failed"
      fi
    done
  fi
fi

# Ghostty - community .deb

# mkasberg/ghostty-ubuntu, where ghostty.org sends Debian and Ubuntu. The asset
# is chosen the way that project's install.sh chooses - Ubuntu by VERSION_ID,
# Debian by codename - and handed to apt instead of piping the script to bash.
if [[ "${GHOSTTY_ENABLED:-no}" == "yes" && -n "${GHOSTTY_DEB_REPO:-}" ]]; then
  phase 'Ghostty - community .deb'
  ghostty_have="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' ghostty 2>/dev/null || true)"
  if [[ "$ghostty_have" == ii* ]]; then ghostty_have="${ghostty_have#*|}"; else ghostty_have=""; fi
  case "$OS_ID" in
    ubuntu) ghostty_suffix="${DPKG_ARCH}_${OS_VERSION_ID}" ;;
    debian) ghostty_suffix="${DPKG_ARCH}_${OS_CODENAME}" ;;
    *)      ghostty_suffix="" ;;
  esac

  if [[ "$HAS_GUI" != "yes" ]]; then
    result 'no-gui' 'ghostty' 'needs a desktop, none detected'
  elif [[ -n "$ghostty_have" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' 'ghostty' "$ghostty_have - --skip-upgrade"
  elif [[ -z "$ghostty_suffix" ]]; then
    result 'missing' 'ghostty' "no community .deb for $OS_ID"
  else
    ghostty_auth=()
    [[ -n "$GITHUB_AUTH_HEADER" ]] && ghostty_auth=(-H "$GITHUB_AUTH_HEADER")
    ghostty_url="$(curl -fsSL "${ghostty_auth[@]}" "https://api.github.com/repos/${GHOSTTY_DEB_REPO}/releases/latest" 2>/dev/null \
      | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https[^"]*\)"$/\1/' \
      | grep "_${ghostty_suffix}\.deb\$" | head -1 || true)"
    ghostty_want="$(basename "${ghostty_url:-none}" .deb | cut -s -d_ -f2)"

    if [[ -z "$ghostty_url" ]]; then
      result 'missing' 'ghostty' "no ${ghostty_suffix} .deb in the latest ${GHOSTTY_DEB_REPO} release"
    # The package calls itself 1.3.1-0~ppa2; GitHub turns the ~ into a dot in the
    # asset name, so compare with that one character folded.
    elif [[ "${ghostty_have//\~/.}" == "$ghostty_want" ]]; then
      result 'current' 'ghostty' "$ghostty_have"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      if [[ -n "$ghostty_have" ]]; then
        result 'would-upgrade' 'ghostty' "$ghostty_have -> $ghostty_want"
      else
        result 'would-install' 'ghostty' "$ghostty_want"
      fi
    else
      mktemp_tracked ghostty_tmp -d
      # apt reads a local .deb as the _apt user, so it has to be world-readable.
      chmod 0755 "$ghostty_tmp"
      if curl -fsSL -o "$ghostty_tmp/ghostty.deb" "$ghostty_url" \
         && chmod 0644 "$ghostty_tmp/ghostty.deb" \
         && run_priv apt-get install "${APT_OPTS[@]}" -qq "$ghostty_tmp/ghostty.deb" >/dev/null 2>&1; then
        if [[ -n "$ghostty_have" ]]; then
          result 'upgraded' 'ghostty' "$ghostty_have -> $ghostty_want"
        else
          result 'installed' 'ghostty' "$ghostty_want"
        fi
      else
        result 'failed' 'ghostty' "could not download or install $ghostty_url"
      fi
      rm -rf "$ghostty_tmp"
    fi
  fi
fi

# AWS CLI v2

if [[ "${AWSCLI_ENABLED:-no}" != "yes" ]]; then
  phase 'AWS CLI - disabled in the manifest'
else
  phase 'AWS CLI v2'

  aws_exe="${RELEASE_BIN_DIR}/aws"
  aws_have=""
  [[ -x "$aws_exe" ]] && aws_have="$("$aws_exe" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

  if [[ -n "$aws_have" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' 'AWS CLI v2' "$aws_have"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    if [[ -n "$aws_have" ]]; then
      result 'would-upgrade' 'AWS CLI v2' "have $aws_have"
    else
      result 'would-install' 'AWS CLI v2' "$AWSCLI_DIR"
    fi
  else
    aws_url="${AWSCLI_URL//\{UNAME_ARCH\}/$UNAME_ARCH}"
    mktemp_tracked aws_tmp -d
    aws_mode=()
    [[ -n "$aws_have" ]] && aws_mode=(--update)
    if (
      cd "$aws_tmp" &&
      curl -fsSL -o awscliv2.zip "$aws_url" &&
      unzip -q awscliv2.zip &&
      ./aws/install --install-dir "$AWSCLI_DIR" --bin-dir "$RELEASE_BIN_DIR" "${aws_mode[@]+"${aws_mode[@]}"}" >/dev/null 2>&1
    ); then
      aws_now="$("$aws_exe" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
      if [[ -z "$aws_have" ]]; then
        result 'installed' 'AWS CLI v2' "${aws_now:-installed}"
      elif [[ "$aws_have" == "$aws_now" ]]; then
        result 'current' 'AWS CLI v2' "$aws_now"
      else
        result 'upgraded' 'AWS CLI v2' "$aws_have -> $aws_now"
      fi
    else
      result 'failed' 'AWS CLI v2' "could not fetch or install $aws_url"
    fi
    rm -rf "$aws_tmp"
  fi
fi

# Nerd Font

if [[ "${NERD_FONT_ENABLED:-no}" != "yes" ]]; then
  phase 'Nerd Font - disabled in the manifest'
elif [[ "$HAS_GUI" != "yes" ]]; then
  phase 'Nerd Font'
  result 'no-gui' "font: $NERD_FONT_NAME" 'rendered by the terminal you type at, not this machine'
else
  phase 'Nerd Font'

  font_present=no
  if command -v fc-list >/dev/null 2>&1; then
    fc-list 2>/dev/null | grep -qi 'MesloLG.*Nerd Font' && font_present=yes
  fi
  if [[ "$font_present" == "no" && -d "$NERD_FONT_DIR" ]]; then
    compgen -G "${NERD_FONT_DIR}/${NERD_FONT_MATCH}*" >/dev/null && font_present=yes
  fi

  if [[ "$font_present" == "yes" ]]; then
    result 'current' "font: $NERD_FONT_NAME" "$NERD_FONT_DIR"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "font: $NERD_FONT_NAME" "$NERD_FONT_DIR"
  else
    font_url="https://github.com/${NERD_FONT_REPO}/releases/latest/download/${NERD_FONT_NAME}.tar.xz"
    mktemp_tracked font_tmp -d
    if (
      cd "$font_tmp" &&
      curl -fsSL -o font.tar.xz "$font_url" &&
      tar -xJf font.tar.xz &&
      mkdir -p "$NERD_FONT_DIR" &&
      find . -type f -name "${NERD_FONT_MATCH}*.ttf" -exec cp {} "$NERD_FONT_DIR/" \; &&
      compgen -G "${NERD_FONT_DIR}/${NERD_FONT_MATCH}*" >/dev/null
    ); then
      command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$NERD_FONT_DIR" >/dev/null 2>&1
      result 'installed' "font: $NERD_FONT_NAME" "$NERD_FONT_DIR"
    else
      result 'failed' "font: $NERD_FONT_NAME" "could not fetch or unpack $font_url"
    fi
    rm -rf "$font_tmp"
  fi
fi

# Claude Code

if [[ "${CLAUDE_CODE_ENABLED:-no}" != "yes" ]]; then
  phase 'Claude Code - disabled in the manifest'
else
  phase 'Claude Code'
  claude_exe=""
  if command -v claude >/dev/null 2>&1; then
    claude_exe="$(command -v claude)"
  elif [[ -x "${HOME}/.local/bin/claude" ]]; then
    claude_exe="${HOME}/.local/bin/claude"
  fi

  if [[ -n "$claude_exe" ]]; then
    claude_version="$("$claude_exe" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    result 'present' 'Claude Code' "${claude_version:-installed} - self-updating, $claude_exe"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'Claude Code' "$CLAUDE_CODE_INSTALLER"
  else
    mktemp_tracked claude_script
    if curl -fsSL "$CLAUDE_CODE_INSTALLER" -o "$claude_script" 2>/dev/null &&
       bash "$claude_script" >/dev/null 2>&1 &&
       [[ -x "${HOME}/.local/bin/claude" ]]; then
      result 'installed' 'Claude Code' "$("${HOME}/.local/bin/claude" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo 'installed')"
    else
      result 'failed' 'Claude Code' "installer failed: $CLAUDE_CODE_INSTALLER"
    fi
    rm -f "$claude_script"
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
    result 'missing' 'vscode extensions' 'code CLI not found - install the vscode repo package first'
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

# mise

mise_version() { "$1" --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true; }

if [[ "${MISE_ENABLED:-no}" != "yes" ]]; then
  phase 'mise - disabled in the manifest'
else
  phase 'mise - runtime version manager'
  mise_exe=""
  if command -v mise >/dev/null 2>&1; then
    mise_exe="$(command -v mise)"
  elif [[ -x "${HOME}/.local/bin/mise" ]]; then
    mise_exe="${HOME}/.local/bin/mise"
  fi

  if [[ -n "$mise_exe" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' 'mise' "$(mise_version "$mise_exe") - --skip-upgrade"
  elif [[ -n "$mise_exe" && "$DRY_RUN" == "yes" ]]; then
    result 'present' 'mise' "$(mise_version "$mise_exe") - would run mise self-update"
  elif [[ -n "$mise_exe" ]]; then
    # Vendor-installed, so self-update is the supported path; it exits non-zero
    # when a distro package owns the binary, which is reported rather than fixed.
    mise_had="$(mise_version "$mise_exe")"
    if "$mise_exe" self-update -y >/dev/null 2>&1; then
      mise_now="$(mise_version "$mise_exe")"
      if [[ "$mise_now" == "$mise_had" ]]; then
        result 'current' 'mise' "$mise_had"
      else
        result 'upgraded' 'mise' "$mise_had -> $mise_now"
      fi
    else
      result 'present' 'mise' "$mise_had - self-update declined, another installer owns $mise_exe"
    fi
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'mise' "$MISE_INSTALLER"
  else
    mktemp_tracked mise_script
    if curl -fsSL "$MISE_INSTALLER" -o "$mise_script" 2>/dev/null &&
       sh "$mise_script" >/dev/null 2>&1 &&
       [[ -x "${HOME}/.local/bin/mise" ]]; then
      result 'installed' 'mise' "$(mise_version "${HOME}/.local/bin/mise")"
    else
      result 'failed' 'mise' "installer failed: $MISE_INSTALLER"
    fi
    rm -f "$mise_script"
  fi
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

  # Homebrew packages these on macOS; here they are git checkouts the fragment
  # sources by absolute path. They used to live under oh-my-zsh's custom/.
  ZSH_PLUGIN_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/plugins"

  if ! command -v zsh >/dev/null 2>&1; then
    result 'missing' 'zsh' 'install the shell group first'
  else
    [[ "$DRY_RUN" == "yes" ]] || mkdir -p "$ZSH_PLUGIN_DIR"
    for entry in "${ZSH_PLUGIN_REPOS[@]:-}"; do
      [[ -z "$entry" ]] && continue
      git_clone_or_update "plugin: ${entry%%|*}" "${ZSH_PLUGIN_DIR}/${entry%%|*}" "${entry#*|}"
    done

    COMPFIX_DIRS=("$ZSH_PLUGIN_DIR")
    for entry in "${ZSH_PLUGIN_REPOS[@]:-}"; do
      [[ -z "$entry" ]] && continue
      COMPFIX_DIRS+=("${ZSH_PLUGIN_DIR}/${entry%%|*}")
      [[ -d "${ZSH_PLUGIN_DIR}/${entry%%|*}/src" ]] && \
        COMPFIX_DIRS+=("${ZSH_PLUGIN_DIR}/${entry%%|*}/src")
    done

    INSECURE_DIRS=()
    for d in "${COMPFIX_DIRS[@]}"; do
      [[ -d "$d" ]] || continue
      perms="$(stat -c '%A' "$d" 2>/dev/null)" || continue
      if [[ "${perms:5:1}" == "w" || "${perms:8:1}" == "w" ]]; then
        INSECURE_DIRS+=("$d")
      fi
    done

    if [[ ${#INSECURE_DIRS[@]} -eq 0 ]]; then
      result 'current' 'completion perms' 'nothing group- or world-writable on fpath'
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' 'completion perms' "chmod g-w,o-w on ${#INSECURE_DIRS[@]} directories"
    else
      if chmod g-w,o-w "${INSECURE_DIRS[@]}" 2>/dev/null; then
        result 'installed' 'completion perms' "chmod g-w,o-w on ${#INSECURE_DIRS[@]} directories"
      else
        result 'failed' 'completion perms' "run by hand: chmod g-w,o-w ${INSECURE_DIRS[*]}"
      fi
    fi

    ZSHRC="${HOME}/.zshrc"
    FRAGMENT="${HOME}/.zshrc.bootstrap"
    if [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' 'zsh config' "$FRAGMENT"
      result 'would-install' 'login shell' 'zsh, if the account still starts another'
    else
      mktemp_tracked NEW_FRAGMENT "${FRAGMENT}.XXXXXX"
      chmod 0644 "$NEW_FRAGMENT"
      {
        echo
        echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
        echo
        echo "fpath+=(\"${ZSH_PLUGIN_DIR}/zsh-completions/src\")"
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
        # What omz's command-not-found plugin did: the apt hook that turns an
        # unknown command into the package that would provide it.
        echo '[ -r /etc/zsh_command_not_found ] && source /etc/zsh_command_not_found'
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
        # fzf's file source and previews. fd rather than fzf's own walker: it
        # honours .gitignore, so Ctrl-T inside a repo does not wade through
        # node_modules or build output. --hidden keeps .env and .github
        # findable; .git itself is only noise. Ctrl-T previews a file in bat,
        # Alt-C a directory as an eza tree. Resolved when the shell starts, not
        # here: fd and bat may be the apt fdfind and batcat on this machine.
        # $commands, not command -v: it holds only executables on PATH, so the
        # fd=fdfind alias further down cannot answer for it on a re-source.
        cat <<'FZF_FILES'
_fzf_fd=; _fzf_bat=
if (( $+commands[fd] )); then _fzf_fd=fd; elif (( $+commands[fdfind] )); then _fzf_fd=fdfind; fi
if (( $+commands[bat] )); then _fzf_bat=bat; elif (( $+commands[batcat] )); then _fzf_bat=batcat; fi
if [ -n "$_fzf_fd" ]; then
  export FZF_DEFAULT_COMMAND="$_fzf_fd --type f --hidden --follow --exclude .git"
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND="$_fzf_fd --type d --hidden --follow --exclude .git"
fi
[ -n "$_fzf_bat" ] && export FZF_CTRL_T_OPTS="--preview '$_fzf_bat --color=always --style=numbers --line-range=:300 {}' --preview-window=right,60%,border-left"
command -v eza >/dev/null && export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --color=always --icons=auto {} | head -200'"
unset _fzf_fd _fzf_bat
FZF_FILES
        echo
        # What the omz fzf plugin did: Ctrl-R, Ctrl-T, Alt-C and fzf's own
        # completion. Before atuin further down, which takes Ctrl-R back.
        # Silenced so a pre-0.48 distro fzf leaves the keys unbound rather
        # than printing on every shell.
        echo 'command -v fzf >/dev/null && source <(fzf --zsh 2>/dev/null)'
        echo
        echo 'eval "$(starship init zsh)"'
        echo
        # Sourced by path, in the order oh-my-zsh's plugins=() implied:
        # fzf-tab after compinit, syntax-highlighting before the history
        # search that wraps its widgets.
        echo "[ -r \"${ZSH_PLUGIN_DIR}/fzf-tab/fzf-tab.plugin.zsh\" ] && source \"${ZSH_PLUGIN_DIR}/fzf-tab/fzf-tab.plugin.zsh\""
        echo "[ -r \"${ZSH_PLUGIN_DIR}/zsh-autosuggestions/zsh-autosuggestions.zsh\" ] && source \"${ZSH_PLUGIN_DIR}/zsh-autosuggestions/zsh-autosuggestions.zsh\""
        echo "[ -r \"${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\" ] && source \"${ZSH_PLUGIN_DIR}/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\""
        echo "[ -r \"${ZSH_PLUGIN_DIR}/zsh-history-substring-search/zsh-history-substring-search.zsh\" ] && source \"${ZSH_PLUGIN_DIR}/zsh-history-substring-search/zsh-history-substring-search.zsh\""
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
        # carapace hands zsh the bare file name to display and the full path as
        # the value, without a compadd prefix. fzf-tab then finds no prefix to
        # strip and seeds the fzf query with the whole typed word, so
        # `cat scripts/aws/<Tab>` searches for "scripts/aws/" among names like
        # "import.py" and shows 0/14 with an empty list. Seed the query from the
        # candidates' common prefix instead, which is the right answer with or
        # without carapace.
        echo "  zstyle ':fzf-tab:*' query-string prefix"
        echo '  # git checkout offers refs in a meaningful order already; sorting'
        echo '  # them alphabetically buries the branch you just left.'
        echo "  zstyle ':completion:*:git-checkout:*' sort false"
        echo "  zstyle ':fzf-tab:complete:cd:*'         fzf-preview 'eza -1 --color=always -- \"\$realpath\" 2>/dev/null || ls -1 \"\$realpath\"'"
        echo "  zstyle ':fzf-tab:complete:__zoxide_z:*' fzf-preview 'eza -1 --color=always -- \"\$realpath\" 2>/dev/null || ls -1 \"\$realpath\"'"
        echo '  # Bound only if the widget exists, so a failed fzf-tab clone'
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
        echo 'command -v batcat >/dev/null && alias cat="batcat --paging=never"'
        echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
        # man pages in bat's theme. col -bx strips the overstrike backspaces
        # groff emits for bold and underline, which bat would render literally.
        # batcat first, bat second, so bat wins where both exist.
        echo 'command -v batcat >/dev/null && export MANPAGER="sh -c '"'"'col -bx | batcat -l man -p'"'"'" MANROFFOPT="-c"'
        echo 'command -v bat    >/dev/null && export MANPAGER="sh -c '"'"'col -bx | bat -l man -p'"'"'" MANROFFOPT="-c"'
        echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
        echo 'command -v fdfind >/dev/null && alias find="fdfind"'
        echo 'command -v fd     >/dev/null && alias find="fd"'
        # Only where no real fd exists: an apt fd-find left from before the
        # release binary would otherwise shadow it.
        echo 'command -v fd >/dev/null || { command -v fdfind >/dev/null && alias fd="fdfind"; }'
        echo 'command -v rg     >/dev/null && alias grep="rg"'
        echo 'command -v dust   >/dev/null && alias du="dust"'
        echo 'command -v duf    >/dev/null && alias df="duf"'
        # doggo answers the same questions as dig and prints them as a table.
        # Debian has no dnsutils here, so on a fresh box this is the only one.
        echo 'command -v doggo  >/dev/null && alias dig="doggo"'
        # xh is curl for JSON APIs. Upstream ships xhs (xh --https) as a symlink
        # inside the tarball, which install_release_bins does not copy.
        echo 'command -v xh     >/dev/null && alias http="xh"'
        echo 'command -v xh     >/dev/null && alias https="xh --https"'
        echo 'command -v lazygit >/dev/null && alias lg="lazygit"'
        echo 'command -v lazydocker >/dev/null && alias lzd="lazydocker"'
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
        # trippy needs raw sockets, and has no unprivileged mode on Linux. The full
        # path, resolved when the alias is defined: sudo's secure_path does not
        # include ~/.local/bin, where the release binary lives.
        echo 'command -v trip >/dev/null && alias trip="sudo $(command -v trip)"'
        echo
        declare -A _cli_cmd=() _cli_desc=()
        _cli_rel=()
        if [[ -r "$SCRIPT_DIR/../tools/cli-parity.conf" ]]; then
          while IFS='|' read -r _pty_can _pty_lx _pty_mac _pty_win _pty_note _pty_cmd _pty_desc; do
            _pty_can="$(printf '%s' "$_pty_can" | tr -d '[:space:]')"
            [[ -z "$_pty_can" || "$_pty_can" == \#* ]] && continue
            _pty_lx="$(printf '%s' "$_pty_lx" | tr -d '[:space:]')"
            [[ -z "$_pty_lx" || "$_pty_lx" == '-' ]] && continue
            # A cli tool taken as a release binary is in no apt list, so it is
            # listed by its canonical name - the RELEASES entry, with - for _.
            if [[ "$_pty_lx" == '@releases' ]]; then
              [[ " ${RELEASES[*]:-} " == *" ${_pty_can//-/_} "* ]] || continue
              _pty_lx="$_pty_can"
              _cli_rel+=("$_pty_can")
            fi
            _pty_cmd="$(printf '%s' "$_pty_cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            _pty_desc="$(printf '%s' "$_pty_desc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
            _cli_cmd["$_pty_lx"]="$_pty_cmd"
            _cli_desc["$_pty_lx"]="$_pty_desc"
          done < "$SCRIPT_DIR/../tools/cli-parity.conf"
        fi
        declare -n _apt="GROUP_cli_APT"
        declare -n _flat="GROUP_cli_FLATPAK"
        _tools_rows=()
        for pkg in "${_apt[@]:-}" "${_flat[@]:-}" "${_cli_rel[@]:-}"; do
          [[ -z "$pkg" ]] && continue
          _tools_rows+=("$pkg" "${_cli_cmd[$pkg]:-}" "${_cli_desc[$pkg]:-}")
        done
        unset -n _apt _flat
        emit_tools_function "${_tools_rows[@]}"
        unset _tools_rows
        echo
        cat <<'WORKFLOW'
# Workflow pickers: fzf over git branches, stashes, processes and the tools
# list. Each one only picks; what runs afterwards is an ordinary git or kill
# command, printed or in the history, so nothing happens that you cannot read.
if (( $+commands[fzf] )); then
  # gb - switch branch. Local and remote, newest commit first, log as preview.
  # A remote branch is checked out with --track, which makes the local branch.
  # `command grep`: grep is an alias for rg in this file, and aliases expand in
  # a function body when it is defined.
  gb() {
    git rev-parse --git-dir >/dev/null 2>&1 || { print -u2 'gb: not a git repository'; return 1; }
    local pick
    pick=$(git for-each-ref --sort=-committerdate --format='%(refname:short)' refs/heads refs/remotes \
      | command grep -v '/HEAD$' \
      | fzf --height=50% --reverse --prompt='branch> ' \
            --preview 'git log --oneline --graph --decorate --color=always -30 {}') || return
    if git show-ref --verify --quiet "refs/heads/$pick"; then
      git switch "$pick"
    else
      git switch --track "$pick"
    fi
  }

  # gs - browse stashes with the diff as preview (through delta when there is
  # one). Enter applies, ctrl-p pops, ctrl-x drops; apply is the default because
  # it leaves the stash behind. Not defined where Ghostscript owns gs.
  if ! (( $+commands[gs] )); then
    gs() {
      git rev-parse --git-dir >/dev/null 2>&1 || { print -u2 'gs: not a git repository'; return 1; }
      local show='git stash show -p --color=always {1}' out key pick
      (( $+commands[delta] )) && show='git stash show -p {1} | delta --paging=never'
      out=$(git stash list \
        | fzf --height=60% --reverse --delimiter=: --prompt='stash> ' \
              --header='enter apply / ctrl-p pop / ctrl-x drop' \
              --expect=ctrl-p,ctrl-x --preview "$show") || return
      key=${out%%$'\n'*}
      pick=${${out#*$'\n'}%%:*}
      [[ -n "$pick" ]] || return
      case $key in
        ctrl-p) git stash pop "$pick" ;;
        ctrl-x) git stash drop "$pick" ;;
        *)      git stash apply "$pick" ;;
      esac
    }
  fi

  # fkill [signal] - pick some of your own processes and signal them, TERM unless
  # told otherwise. Tab marks several. -U, not -u: on macOS -u is a format.
  fkill() {
    local sig=${1:-TERM} pick line
    local -a pids
    pick=$(ps -U "$USER" -o pid,pcpu,pmem,comm \
      | fzf --multi --header-lines=1 --height=60% --reverse --prompt="kill -$sig> " \
            --preview 'ps -p {1} -o pid,ppid,etime,command' --preview-window=down,4) || return
    for line in ${(f)pick}; do pids+=(${${=line}[1]}); done
    (( ${#pids} )) || return
    print -r -- "kill -$sig ${pids[*]}"
    kill -"$sig" "${pids[@]}"
  }

  # cheat - search the list `tools` prints. The preview is the command's tldr
  # page (its --help when there is none); Enter puts the command on the prompt.
  cheat() {
    (( ${#_TOOLS_ROWS} )) || { print -u2 'cheat: the tools list is not loaded'; return 1; }
    local -a lines
    local i cmd page pick
    for (( i = 1; i + 2 <= ${#_TOOLS_ROWS}; i += 3 )); do
      cmd=${_TOOLS_ROWS[i+1]}
      page=${${=cmd}[1]}
      [[ -n "$page" ]] || continue
      lines+=("$(printf '%-12s  %-10s  %s' "${_TOOLS_ROWS[i]}" "$cmd" "${_TOOLS_ROWS[i+2]}")"$'\t'"$page")
    done
    pick=$(print -rl -- $lines \
      | fzf --delimiter=$'\t' --with-nth=1 --height=70% --reverse --prompt='tool> ' \
            --preview 'tldr --color always {2} 2>/dev/null || {2} --help 2>&1 | head -40') || return
    print -z -- "${pick##*$'\t'}"
  }
fi

# y - yazi, then cd to wherever you quit it. yazi writes that directory to the
# file named by --cwd-file; without a wrapper you always come back to where you
# started. Not inside the fzf guard above: yazi has a finder of its own.
if (( $+commands[yazi] )); then
  y() {
    local tmp cwd
    tmp=$(mktemp -t yazi-cwd.XXXXXX) || return
    yazi "$@" --cwd-file="$tmp"
    cwd=$(<"$tmp")
    rm -f -- "$tmp"
    if [[ -n "$cwd" && "$cwd" != "$PWD" ]]; then
      builtin cd -- "$cwd"
    fi
  }
fi
WORKFLOW
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
        echo
        echo '[ -d "$HOME/.dotnet" ] && export PATH="$HOME/.dotnet:$PATH" && export DOTNET_ROOT="$HOME/.dotnet"'
        # `dotnet tool install -g` installs here. macOS gets this from the
        # SDK installer's /etc/paths.d entry; on Windows the installer adds it
        # to the user PATH. Nothing adds it here.
        echo '[ -d "$HOME/.dotnet/tools" ] && export PATH="$HOME/.dotnet/tools:$PATH"'
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

      # Everything above is inert until zsh is what a login starts: sshd and
      # the terminal launch the shell named in /etc/passwd, and bash never
      # reads ~/.zshrc. chsh needs the shell listed in /etc/shells, which the
      # zsh package does itself; run through run_priv, it skips the password
      # prompt chsh would give the account and works from an unattended run.
      ZSH_BIN="$(command -v zsh)"
      LOGIN_USER="$(id -un)"
      CURRENT_SHELL="$(getent passwd "$LOGIN_USER" | cut -d: -f7)"
      if [[ "$CURRENT_SHELL" == "$ZSH_BIN" || "$(basename "${CURRENT_SHELL:-}")" == "zsh" ]]; then
        result 'current' 'login shell' "$CURRENT_SHELL"
      elif ! grep -qxF "$ZSH_BIN" /etc/shells 2>/dev/null; then
        result 'failed' 'login shell' "$ZSH_BIN is not in /etc/shells - add it, then: chsh -s $ZSH_BIN"
      elif run_priv chsh -s "$ZSH_BIN" "$LOGIN_USER" >/dev/null 2>&1; then
        result 'installed' 'login shell' "${CURRENT_SHELL:-unset} -> $ZSH_BIN (takes effect at next login)"
      else
        result 'failed' 'login shell' "run by hand: sudo chsh -s $ZSH_BIN $LOGIN_USER"
      fi

    fi
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

# tealdeer config - turns on auto_update: the tldr pages download on first use
# and refresh themselves every 30 days. tldr itself is never run here; with
# that key set, any tldr call can reach the network, a dry run's included.
# The path is tealdeer's own XDG rule, not `tldr --show-paths`, for that reason.
TEALDEER_SOURCE="${SCRIPT_DIR}/../tealdeer"
phase 'tealdeer config'
if ! command -v tldr >/dev/null 2>&1; then
  result 'missing' 'tealdeer config' 'tldr is not installed'
else
  deploy_config "${TEALDEER_SOURCE}/config.toml" \
                "${XDG_CONFIG_HOME:-$HOME/.config}/tealdeer/config.toml" 'tealdeer config'
fi

# bat config - the theme bat, and through it delta, render with
BAT_SOURCE="${SCRIPT_DIR}/../bat"
phase 'bat config'
_bat_bin="$(command -v bat 2>/dev/null || command -v batcat 2>/dev/null || true)"
if [[ -z "$_bat_bin" ]]; then
  result 'missing' 'bat config' 'bat is not installed'
else
  _bat_cfg="$("$_bat_bin" --config-dir 2>/dev/null)"
  deploy_config "${BAT_SOURCE}/config" "${_bat_cfg}/config" 'bat config'
  deploy_config "${BAT_SOURCE}/themes/Catppuccin Mocha.tmTheme" \
                "${_bat_cfg}/themes/Catppuccin Mocha.tmTheme" 'bat theme'
  # bat since 0.24 reads the themes directory at startup, so this is a no-op
  # on anything current - kept for an older bat, which only sees a theme once
  # it is in the cache.
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'bat cache' 'bat cache --build, if the theme is not listed'
  elif "$_bat_bin" --list-themes 2>/dev/null | grep -qx 'Catppuccin Mocha'; then
    result 'current' 'bat cache' 'Catppuccin Mocha is in the theme list'
  elif "$_bat_bin" cache --build >/dev/null 2>&1; then
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
  # carapace honours XDG_CONFIG_HOME only when it is an absolute path.
  _carapace_cfg="${XDG_CONFIG_HOME:-}"
  [[ "$_carapace_cfg" == /* ]] || _carapace_cfg="${HOME}/.config"
  for _spec in "${CARAPACE_SOURCE}/specs/"*.yaml; do
    [[ -e "$_spec" ]] || continue
    deploy_config "$_spec" "${_carapace_cfg}/carapace/specs/$(basename "$_spec")" \
                  "carapace spec $(basename "$_spec" .yaml)"
  done
fi

# Theme activation - k9s, lazygit and btop
#
# The theme file is the repo's and is copied like every config above. The key
# that *names* it is not: k9s rewrites its config.yaml on every quit and btop
# rewrites btop.conf on every exit, so those two files cannot be owned here.
# The key in them is set only when it is unset - a theme you picked is a
# choice, the same rule the git config below follows. lazygit has no separate
# theme file at all, so there the whole config.yml is the repo's.

# set_yaml_key <file> <yq path> <value> <label> - set one key, only when unset.
# yq is in the cli group on all three platforms; without it the step says so
# rather than guessing at somebody's YAML with sed.
set_yaml_key() {
  local file="$1" key="$2" want="$3" label="$4" have=''
  if ! command -v yq >/dev/null 2>&1; then
    result 'missing' "$label" 'yq is not installed, so nothing can set the key'
    return
  fi
  [[ -f "$file" ]] && have="$(yq "${key} // \"\"" "$file" 2>/dev/null || true)"
  if [[ "$have" == "$want" ]]; then
    result 'current' "$label" "$want"
  elif [[ -n "$have" ]]; then
    result 'skipped' "$label" "yours is ${have} - set ${key} to ${want} by hand to switch"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$label" "${key} = ${want} in ${file}"
  elif mkdir -p "$(dirname "$file")" && touch "$file" \
       && yq -i "${key} = \"${want}\"" "$file"; then
    result 'installed' "$label" "${key} = ${want} in ${file}"
  else
    result 'failed' "$label" "yq could not set ${key} in ${file}"
  fi
}

# btop_set_theme <btop.conf> <theme> - the same rule as set_yaml_key, for a
# file that is not YAML. "Default" counts as unset: it is btop's built-in.
btop_set_theme() {
  local conf="$1" want="$2" have
  have="$(btop_theme_of "$conf")"
  case "$have" in
    "$want")
      result 'current' 'btop color_theme' "$want" ;;
    ''|Default)
      if [[ "$DRY_RUN" == "yes" ]]; then
        result 'would-install' 'btop color_theme' "${want} in ${conf}"
      elif [[ -f "$conf" ]] && grep -q '^color_theme' "$conf"; then
        if sed -i "s/^color_theme.*/color_theme = \"${want}\"/" "$conf"; then
          result 'upgraded' 'btop color_theme' "$conf"
        else
          result 'failed' 'btop color_theme' "sed could not rewrite $conf"
        fi
      else
        mkdir -p "$(dirname "$conf")"
        printf 'color_theme = "%s"\n' "$want" >> "$conf"
        result 'installed' 'btop color_theme' "$conf"
      fi ;;
    *)
      result 'skipped' 'btop color_theme' \
             "yours is ${have} - set color_theme to ${want} by hand to switch" ;;
  esac
}

K9S_SOURCE="${SCRIPT_DIR}/../k9s"
phase 'k9s skin'
if ! command -v k9s >/dev/null 2>&1; then
  result 'missing' 'k9s skin' 'k9s is not installed'
elif ! k9s_paths; then
  result 'failed' 'k9s skin' 'k9s info named no config file'
else
  deploy_config "${K9S_SOURCE}/skins/catppuccin-mocha.yaml" \
                "${_K9S_SKINS}/catppuccin-mocha.yaml" 'k9s skin'
  set_yaml_key "$_K9S_CFG" '.k9s.ui.skin' 'catppuccin-mocha' 'k9s ui.skin'
fi

# lazygit config. Its colours live in the one config file, so there is no theme
# to copy beside it: config.yml is the repo's, and a run replaces a copy that
# has drifted from it. The first replacement of a config that was not ours is
# kept as .bak - the courtesy Deploy-ManagedFile already does on Windows.
LAZYGIT_SOURCE="${SCRIPT_DIR}/../lazygit"
phase 'lazygit config'
if ! command -v lazygit >/dev/null 2>&1; then
  result 'missing' 'lazygit config' 'lazygit is not installed'
else
  _lazygit_dir="$(lazygit --print-config-dir 2>/dev/null || true)"
  if [[ -z "$_lazygit_dir" ]]; then
    result 'failed' 'lazygit config' 'lazygit --print-config-dir said nothing'
  else
    _lazygit_cfg="${_lazygit_dir}/config.yml"
    if [[ "$DRY_RUN" != "yes" && -f "$_lazygit_cfg" && ! -f "${_lazygit_cfg}.bak" ]] \
       && ! cmp -s "${LAZYGIT_SOURCE}/config.yml" "$_lazygit_cfg"; then
      cp "$_lazygit_cfg" "${_lazygit_cfg}.bak"
      result 'installed' 'lazygit config backup' "${_lazygit_cfg}.bak"
    fi
    deploy_config "${LAZYGIT_SOURCE}/config.yml" "$_lazygit_cfg" 'lazygit config'
  fi
fi

# btop theme. There is no btop on Windows - btop4win is a separate port, and
# cli-parity.conf says so - which is why this step has no counterpart there.
BTOP_SOURCE="${SCRIPT_DIR}/../btop"
phase 'btop theme'
if ! command -v btop >/dev/null 2>&1; then
  result 'missing' 'btop theme' 'btop is not installed'
else
  _btop_dir="${XDG_CONFIG_HOME:-$HOME/.config}/btop"
  _btop_conf="${_btop_dir}/btop.conf"
  deploy_config "${BTOP_SOURCE}/themes/catppuccin_mocha.theme" \
                "${_btop_dir}/themes/catppuccin_mocha.theme" 'btop theme'
  btop_set_theme "$_btop_conf" 'catppuccin_mocha'
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
    { command -v bat >/dev/null 2>&1 || command -v batcat >/dev/null 2>&1; } && \
      GIT_WANT+=('delta.syntax-theme=Catppuccin Mocha')
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
elif ! command -v ghostty >/dev/null 2>&1; then
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
      echo "copy-on-select = ${GHOSTTY_COPY_ON_SELECT}"
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

phase 'Schedule'

if [[ "$SKIP_SCHEDULE" == "yes" ]]; then
  result 'skipped' 'schedule' '--skip-schedule'
elif [[ "${SCHEDULE_ENABLED:-no}" != "yes" ]]; then
  result 'skipped' 'schedule' 'disabled in the manifest'
elif [[ ! -d /run/systemd/system ]]; then
  result 'skipped' 'schedule' 'systemd is not running as init (e.g. WSL without systemd enabled)'
else
  SERVICE_UNIT="/etc/systemd/system/${SCHEDULE_UNIT_NAME}.service"
  TIMER_UNIT="/etc/systemd/system/${SCHEDULE_UNIT_NAME}.timer"

  mktemp_tracked NEW_SERVICE
  {
    echo '[Unit]'
    echo "Description=Runs $SCRIPT_DIR/bootstrap.sh unattended, taking package and script updates"
    echo
    echo '[Service]'
    echo 'Type=oneshot'
    echo "WorkingDirectory=$SCRIPT_DIR"
    echo "ExecStart=$SCRIPT_DIR/bootstrap.sh --yes"
  } > "$NEW_SERVICE"

  mktemp_tracked NEW_TIMER
  {
    echo '[Unit]'
    echo "Description=Daily trigger for ${SCHEDULE_UNIT_NAME}.service"
    echo
    echo '[Timer]'
    echo "OnCalendar=*-*-* ${SCHEDULE_TIME}:00"
    echo 'Persistent=true'
    echo 'RandomizedDelaySec=5m'
    echo
    echo '[Install]'
    echo 'WantedBy=timers.target'
  } > "$NEW_TIMER"

  if [[ -f "$SERVICE_UNIT" ]] && cmp -s "$NEW_SERVICE" "$SERVICE_UNIT"; then
    SERVICE_CHANGED=no
  else
    SERVICE_CHANGED=yes
  fi
  if [[ -f "$TIMER_UNIT" ]] && cmp -s "$NEW_TIMER" "$TIMER_UNIT"; then
    TIMER_CHANGED=no
  else
    TIMER_CHANGED=yes
  fi
  TIMER_ACTIVE=no
  if systemctl is-active --quiet "${SCHEDULE_UNIT_NAME}.timer" 2>/dev/null; then
    TIMER_ACTIVE=yes
  fi

  if [[ "$SERVICE_CHANGED" == "no" && "$TIMER_CHANGED" == "no" && "$TIMER_ACTIVE" == "yes" ]]; then
    rm -f "$NEW_SERVICE" "$NEW_TIMER"
    result 'current' "$SCHEDULE_UNIT_NAME" "daily at $SCHEDULE_TIME"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    rm -f "$NEW_SERVICE" "$NEW_TIMER"
    action='would-install'
    [[ -f "$SERVICE_UNIT" ]] && action='would-upgrade'
    result "$action" "$SCHEDULE_UNIT_NAME" "daily at $SCHEDULE_TIME"
  else
    action='installed'
    [[ -f "$SERVICE_UNIT" ]] && action='upgraded'
    run_priv install -m 0644 "$NEW_SERVICE" "$SERVICE_UNIT"
    run_priv install -m 0644 "$NEW_TIMER" "$TIMER_UNIT"
    rm -f "$NEW_SERVICE" "$NEW_TIMER"
    if run_priv systemctl daemon-reload && run_priv systemctl enable --now "${SCHEDULE_UNIT_NAME}.timer" >/dev/null; then
      result "$action" "$SCHEDULE_UNIT_NAME" "daily at $SCHEDULE_TIME"
    else
      result 'failed' "$SCHEDULE_UNIT_NAME" 'systemctl daemon-reload/enable failed'
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
  printf '  %sNo desktop detected, so desktop software was skipped.%s\n' "$C_DIM" "$C_RESET"
  printf '  %sRun with --gui to install it anyway.%s\n' "$C_DIM" "$C_RESET"
fi
printf '  %sOpen a new shell to pick up PATH and shell changes.%s\n\n' "$C_DIM" "$C_RESET"
