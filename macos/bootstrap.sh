#!/usr/bin/env bash
#
# Installs and updates this Mac's software from packages.conf.
#
# Run it on a fresh machine to build it out; run it again any time to take
# updates. Both are the same command - the script works out per package which
# one it is doing.
#
# See README.md.

set -euo pipefail

BOOTSTRAP_VERSION='1.17.0'

# Resolved once, here, so nothing later has to guess where the script lives.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
GUI_OVERRIDE=auto
ONLY_GROUPS=""

# ============================================================
# Output
# ============================================================

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_CYAN=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_BLUE=''
fi

# One line per package, colour-coded by what happened, plus a row for the
# summary. Every code path that decides something about a package ends here, so
# the summary can never disagree with the live output.
RESULT_ACTIONS=()

phase() {
  printf '\n%s== %s %s%s\n' "$C_CYAN" "$1" "$(printf '=%.0s' $(seq 1 $((60 - ${#1} > 0 ? 60 - ${#1} : 0))))" "$C_RESET"
}

result() {
  local action="$1" id="$2" detail="${3:-}" colour=""
  case "$action" in
    installed|upgraded)      colour="$C_GREEN" ;;
    would-install|would-upgrade) colour="$C_BLUE" ;;
    failed)                  colour="$C_RED" ;;
    missing|held|no-gui)     colour="$C_YELLOW" ;;
    *)                       colour="$C_DIM" ;;
  esac
  printf '  %s%-14s%s%-42s %s%s%s\n' \
    "$colour" "$action" "$C_RESET" "$id" "$C_DIM" "$detail" "$C_RESET"
  RESULT_ACTIONS+=("$action")
}

die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ============================================================
# Which Mac is this?
# ============================================================
# Homebrew lives at a different prefix per architecture - /opt/homebrew on
# Apple silicon, /usr/local on Intel - and everything downstream depends on
# getting that right. Install into the wrong one and you do not get an error;
# you get a second, parallel Homebrew that the shell never picks up.
#
# `uname -m` is the obvious way to ask, and on its own it is wrong. Under
# Rosetta - an Intel binary, or a Terminal with "Open using Rosetta" ticked, or
# an `arch -x86_64 zsh` somewhere in your history - `uname -m` reports x86_64
# on an Apple silicon Mac, because that is what the translated process is
# entitled to believe. A script that trusts it would install the Intel Homebrew
# into /usr/local on an M-series machine and quietly leave it there.
#
# sysctl.proc_translated is the question actually worth asking: the kernel sets
# it to 1 when THIS process is being translated. It is absent on Intel Macs, so
# a missing value and a 0 both mean "native".
detect_arch() {
  local machine translated
  machine="$(uname -m)"
  translated="$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)"

  if [[ "$machine" == "arm64" ]]; then
    ARCH=arm64
    ARCH_NOTE="Apple silicon"
  elif [[ "$translated" == "1" ]]; then
    # x86_64 reported, but the kernel says we are translated - so the hardware
    # is Apple silicon and uname is describing the emulation, not the Mac.
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

# ============================================================
# Package state
# ============================================================
# Formulae and casks are looked up SEPARATELY, never with a bare `brew list`.
# The same name can be both: `docker` is a formula (the CLI client on its own)
# and `docker-desktop` is a cask (the engine and the app). A check that does
# not say which kind it means will call a package installed when the other kind
# of it is.
#
# Every one of these goes through "$BREW" rather than a bare `brew`. On a fresh
# machine Homebrew was installed minutes ago and nothing has re-read a profile
# since, so `brew` may well not be on PATH yet.

brew_formula_installed() {
  "$BREW" list --formula --versions "$1" >/dev/null 2>&1
}

brew_cask_installed() {
  "$BREW" list --cask --versions "$1" >/dev/null 2>&1
}

# Known to Homebrew at all. A name that is simply not in the tap should be
# reported as such, not attempted and failed - a typo and a formula that was
# renamed upstream look identical in brew's output and mean very different
# things. Casks answer the same question from the JSON in install_cask, which
# needs it anyway.
brew_formula_available() {
  "$BREW" info --formula "$1" >/dev/null 2>&1
}

brew_formula_version() {
  "$BREW" list --formula --versions "$1" 2>/dev/null | awk '{print $2}' || true
}

brew_cask_version() {
  "$BREW" list --cask --versions "$1" 2>/dev/null | awk '{print $2}' || true
}

# ============================================================
# Arguments
# ============================================================

usage() {
  cat <<'USAGE'
Usage: bootstrap.sh [options]

  --dry-run          Show what would change, touch nothing.
  --groups a,b       Limit to named groups. Default is every group.
  --list-groups      Print the groups in the manifest and exit.
  --list-packages    Print every package name in every group and exit - for
                     when you know something is in here somewhere but not
                     which group.
  --skip-upgrade     Install what is missing, leave installed versions alone.
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
    --gui)          GUI_OVERRIDE=yes ;;
    --no-gui)       GUI_OVERRIDE=no ;;
    --groups)       shift; ONLY_GROUPS="${1:-}" ;;
    --groups=*)     ONLY_GROUPS="${1#*=}" ;;
    --list-groups)  LIST_GROUPS=yes ;;
    --list-packages) LIST_PACKAGES=yes ;;
    --version)      echo "$BOOTSTRAP_VERSION"; exit 0 ;;
    -h|--help)      usage; exit 0 ;;
    *)              die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ============================================================
# Manifest
# ============================================================

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
# shellcheck source=packages.conf
source "$MANIFEST"

# Checked here, once, rather than discovered halfway through a run. A manifest
# that sources cleanly is not a manifest that is complete.
#
# The *_ENABLED switches are in this list for a reason worth stating. Every one
# of them is read as "${X_ENABLED:-no}", which means a manifest that never
# mentions X and a manifest that deliberately sets X to no produce the same
# output - "disabled in the manifest" - and one of those two is a bug. The
# Linux manifest lost its Claude Code keys to a bad edit and the run went on
# reporting the phase as disabled, which is what it would have said if the
# absence had been intended.
for required in PKG_GROUPS MANUAL HELD TOOLS TAPS ZSH_PLUGINS ZSH_CUSTOM_PLUGINS \
                ZSH_ENABLED \
                GHOSTTY_ENABLED HISTORY_SIZE HISTORY_FILE_SIZE; do
  declare -p "$required" >/dev/null 2>&1 || die "manifest is missing \$$required: $MANIFEST"
done

if [[ "${LIST_GROUPS:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    desc_var="GROUP_${g}_DESC"
    gui_var="GROUP_${g}_GUI"
    # Nameref rather than eval: it is what bash provides for exactly this, and
    # it keeps the array an array instead of round-tripping through a string.
    declare -n _form="GROUP_${g}_FORMULA"
    declare -n _cask="GROUP_${g}_CASK"
    total=$(( ${#_form[@]} + ${#_cask[@]} ))
    gui_tag='               '
    [[ "${!gui_var:-no}" == "yes" ]] && gui_tag='[needs desktop]'
    printf '  %s%-10s%s %-3s packages  %s%s%s  %s\n' \
      "$C_CYAN" "$g" "$C_RESET" "$total" "$C_DIM" "$gui_tag" "$C_RESET" "${!desc_var}"
    unset -n _form _cask
  done
  echo
  exit 0
fi

if [[ "${LIST_PACKAGES:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    printf '  %s%s%s\n' "$C_CYAN" "$g" "$C_RESET"
    declare -n _form="GROUP_${g}_FORMULA"
    declare -n _cask="GROUP_${g}_CASK"
    for pkg in "${_form[@]:-}" "${_cask[@]:-}"; do
      [[ -z "$pkg" ]] && continue
      printf '    %s%s%s\n' "$C_DIM" "$pkg" "$C_RESET"
    done
    unset -n _form _cask
  done
  echo
  exit 0
fi

# ============================================================
# Preflight
# ============================================================

phase 'Preflight'

[[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS (uname says $(uname -s))"

# The inverse of the Linux script, and worth being loud about. That one calls
# sudo for the steps that need root; this one must never run as root at all.
# Homebrew refuses to operate as root, and a `sudo ./bootstrap.sh` that got far
# enough would leave root-owned files in the prefix and in $HOME that later
# unprivileged runs cannot write - a mess to unpick, and easy to avoid here.
[[ "$(id -u)" -ne 0 ]] || die "do not run this with sudo - Homebrew refuses to run as root, and it would leave root-owned files in your home directory"

detect_arch

printf '  %-16s%s\n' 'bootstrap' "v$BOOTSTRAP_VERSION"
printf '  %-16s%s\n' 'macOS' "$(sw_vers -productVersion 2>/dev/null || echo unknown) ($(sw_vers -buildVersion 2>/dev/null || echo '?'))"
printf '  %-16s%s  %s(%s)%s\n' 'arch' "$ARCH" "$C_DIM" "$ARCH_NOTE" "$C_RESET"
printf '  %-16s%s\n' 'user' "$(id -un) (uid $(id -u))"

if [[ "$ARCH_NOTE" == *Rosetta* ]]; then
  printf '  %-16s%sthis shell is running under Rosetta - targeting the native prefix anyway%s\n' \
    'note' "$C_YELLOW" "$C_RESET"
fi

if [[ "$GUI_OVERRIDE" == "auto" ]]; then
  # No probe here, unlike the Linux script, and that is the honest answer
  # rather than a missing feature. Linux can ask whether a display manager or
  # any session files are installed, and a machine with none of them cannot
  # start a desktop. Every Mac can: the window server is part of the OS, and
  # the signals that differ between a laptop and a rack-mounted mini - whether
  # anyone is logged in at the console, whether $SSH_CONNECTION is set - all
  # describe THIS SESSION, which is exactly the mistake the Linux script goes
  # out of its way not to make. So default to yes and take the override.
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

# Xcode's Command Line Tools, checked before Homebrew rather than reported at
# the end: brew cannot compile, and for many formulae cannot even install a
# bottle, without them. `xcode-select --install` is deliberately NOT run here -
# it opens a modal dialog and waits for a human, which would hang an unattended
# run with no output explaining why. Homebrew's own installer does install
# them, so this only has to be fatal when Homebrew is already present.
CLT_PRESENT=no
if xcode-select -p >/dev/null 2>&1; then
  CLT_PRESENT=yes
  printf '  %-16s%s%s%s\n' 'xcode CLT' "$C_DIM" "$(xcode-select -p)" "$C_RESET"
else
  printf '  %-16s%s%s%s\n' 'xcode CLT' "$C_YELLOW" 'not installed' "$C_RESET"
fi

# ------------------------------------------------------------
# Homebrew itself
# ------------------------------------------------------------

BREW="${BREW_PREFIX}/bin/brew"

if [[ ! -x "$BREW" ]]; then
  # Not on PATH and not at the expected prefix. Before installing a second one,
  # check whether it is simply somewhere else - a Homebrew moved by hand, or an
  # Intel install on a machine that has since been migrated to Apple silicon.
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
    # NONINTERACTIVE stops the installer waiting for a RETURN it will never
    # get. It still calls sudo to create the prefix, so the first run on a
    # fresh machine asks for a password once - there is no way around that and
    # pretending otherwise would just hang.
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

# brew needs its own environment - PATH, MANPATH and the prefix variables -
# and this script cannot assume the calling shell already has it. On a first
# run it demonstrably does not: Homebrew was installed thirty lines ago and
# nothing has re-read a profile since.
if [[ -x "$BREW" ]]; then
  eval "$("$BREW" shellenv)"
fi

# One index refresh for the whole run. HOMEBREW_NO_AUTO_UPDATE then stops brew
# repeating it before every single install, which on a fresh machine with
# forty packages is forty needless fetches of the same repository.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

if [[ "$DRY_RUN" == "no" && -x "$BREW" ]]; then
  printf '  %-16s' 'brew index'
  if "$BREW" update --quiet >/dev/null 2>&1; then
    printf '%supdated%s\n' "$C_DIM" "$C_RESET"
  else
    printf '%scould not refresh - continuing with what is cached%s\n' "$C_YELLOW" "$C_RESET"
  fi
fi

# ============================================================
# Held
# ============================================================

for entry in "${HELD[@]:-}"; do
  [[ -z "$entry" ]] && continue
  result 'held' "${entry%%:*}" "${entry#*:}"
done

# ============================================================
# Taps
# ============================================================
# Homebrew's third-party repositories. Empty in the shipped manifest, and the
# mechanism is here anyway so that adding one is a manifest edit rather than a
# script edit. A tap is a git repository of build recipes: once tapped it can
# define what `brew install <name>` does, which is the same class of trust
# decision as an apt signing key even though it looks like one word.

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
    elif "$BREW" tap "$tap_name" >/dev/null 2>&1; then
      result 'installed' "tap: $tap_desc" "$tap_name"
    else
      result 'failed' "tap: $tap_desc" "brew tap $tap_name failed"
    fi
  done
fi

# ============================================================
# Packages
# ============================================================

selected=("${PKG_GROUPS[@]}")
if [[ -n "$ONLY_GROUPS" ]]; then
  IFS=',' read -r -a selected <<< "$ONLY_GROUPS"
  for g in "${selected[@]}"; do
    printf '%s\n' "${PKG_GROUPS[@]}" | grep -qx "$g" || die "unknown group: $g (try --list-groups)"
  done
fi

install_formula() {
  local pkg="$1"
  if brew_formula_installed "$pkg"; then
    local version
    version="$(brew_formula_version "$pkg")"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' "$pkg" "$version"
      return
    fi
    # Upgrades are taken for everything in one pass below rather than per
    # package: brew resolves dependencies across the set, and upgrading one
    # formula at a time is both slower and more likely to rebuild a dependency
    # several times over.
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
  if "$BREW" install --formula "$pkg" >/dev/null 2>&1; then
    result 'installed' "$pkg" "$(brew_formula_version "$pkg")"
  else
    result 'failed' "$pkg" 'brew install failed'
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

  # One `brew info` for both questions below: whether the cask exists at all,
  # and what it would put in /Applications. Asking twice doubles the cost for
  # every cask on a fresh machine, and they are the same lookup.
  local json
  if ! json="$("$BREW" info --cask --json=v2 "$token" 2>/dev/null)"; then
    result 'missing' "$token" 'no such cask - tokens get renamed, check brew search'
    return
  fi

  # An app already in /Applications that Homebrew did not put there is left
  # alone, not overwritten. Two installers owning one .app is how a machine
  # ends up disagreeing with itself about which version is installed.
  #
  # The name comes out of the JSON with sed and grep rather than jq, because
  # jq is a package this script installs and cannot assume on a first run.
  # Everything before "artifacts" is discarded first so a .app named in a zap
  # or uninstall stanza cannot be mistaken for the thing being installed.
  local appname
  # shellcheck disable=SC2001
  # ${json##*'"artifacts"'} is the suggested replacement and is not used here
  # on purpose. It is only equivalent because `.*` is greedy - it has to strip
  # to the LAST "artifacts", not the first, or a cask mentioning the word
  # earlier truncates in the wrong place. Writing that as a parameter expansion
  # means remembering which of # and ## is the greedy one, in a line whose
  # correctness already rests on greediness. sed says it once, visibly.
  appname="$(sed 's/.*"artifacts"//' <<< "$json" | grep -o '"[^"]*\.app"' | head -1 | tr -d '"' || true)"
  if [[ -n "$appname" && -d "/Applications/${appname}" ]]; then
    result 'present' "$token" "/Applications/${appname} - installed by something else"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "$token" 'cask'
    return
  fi
  if "$BREW" install --cask "$token" >/dev/null 2>&1; then
    result 'installed' "$token" "$(brew_cask_version "$token")"
  else
    result 'failed' "$token" 'brew install --cask failed'
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

# ============================================================
# Upgrades
# ============================================================
# `brew upgrade` exits 0 whether it moved forty packages or none, so its exit
# code cannot be read as "something changed". Ask what is outdated first, and
# the count is both the decision and the thing worth printing.

brew_outdated() {
  # --quiet gives bare names, one per line, and nothing when everything is
  # current. Casks are asked for separately because the two lists are.
  "$BREW" outdated --quiet "$@" 2>/dev/null || true
}

count_lines() {
  # grep -c rather than wc -l: an empty string is one empty line to wc, which
  # would report 1 outdated package on a fully up-to-date machine.
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
  elif "$BREW" upgrade --formula >/dev/null 2>&1; then
    result 'upgraded' 'brew formulae' "$n_formulae package(s)"
  else
    result 'failed' 'brew formulae' 'brew upgrade failed'
  fi

  # No --greedy, on purpose. Casks that declare auto_updates - Chrome, VS Code,
  # Docker Desktop - keep themselves current, and --greedy makes Homebrew
  # download and reinstall them anyway, on top of an app that has already
  # updated itself. That is two installers fighting over one .app, and the
  # visible symptom is a large download every single run for something that was
  # never out of date. They are reported below instead.
  outdated_casks="$(brew_outdated --cask)"
  n_casks="$(count_lines "$outdated_casks")"
  if [[ "$n_casks" -eq 0 ]]; then
    result 'current' 'brew casks' 'nothing outdated'
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-upgrade' 'brew casks' "$n_casks outdated: $(tr '\n' ' ' <<< "$outdated_casks")"
  elif "$BREW" upgrade --cask >/dev/null 2>&1; then
    result 'upgraded' 'brew casks' "$n_casks app(s)"
  else
    result 'failed' 'brew casks' 'brew upgrade --cask failed'
  fi

  # The self-updaters, named rather than silently left out, so the output does
  # not look like Homebrew is keeping something current that it is not.
  self_updating="$(comm -13 \
    <(printf '%s\n' "$outdated_casks" | grep . | sort || true) \
    <(brew_outdated --cask --greedy | grep . | sort || true) || true)"
  if [[ -n "$self_updating" ]]; then
    result 'present' 'self-updating casks' "$(tr '\n' ' ' <<< "$self_updating")- left to their own updaters"
  fi
fi

# ============================================================
# Tools that install themselves into $HOME
# ============================================================
# git clones, not Homebrew formulae. See the note in packages.conf for why
# these are not `brew install pyenv` - the short version is that $HOME/.pyenv
# is the same path on Linux and macOS, so one managed zsh fragment works on
# both, and Homebrew never gets a second claim on them.

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
      # A pull that cannot fast-forward means somebody has local commits or the
      # branch moved. Reported, never forced: this is the user's checkout.
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

# Guarded rather than unconditional: TOOLS has been empty before and will be
# again, and a phase header printed over nothing reads like something failed.
# git_clone_or_update is used either way - the zsh theme and every custom
# plugin go through it.
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

# ============================================================
# zsh
# ============================================================
# oh-my-zsh, powerlevel10k and the plugins, matching the Linux script and the
# fleet's zsh role so a shell is the same wherever you land.

if [[ "${ZSH_ENABLED:-no}" != "yes" ]]; then
  phase 'zsh - disabled in the manifest'
else
  phase 'zsh - oh-my-zsh, theme and plugins'

  OMZ_DIR="${ZSH:-$HOME/.oh-my-zsh}"
  OMZ_CUSTOM="${OMZ_DIR}/custom"

  # macOS has shipped zsh as the default login shell since Catalina, so unlike
  # the Linux script there is nothing to install and nothing to chsh. Reported
  # so the version is on the record next to everything else.
  result 'present' 'zsh' "$(/bin/zsh --version 2>/dev/null | awk '{print $2}' || echo 'system')"

  if [[ -d "$OMZ_DIR" ]]; then
    result 'current' 'oh-my-zsh' "$OMZ_DIR"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'oh-my-zsh' "$OMZ_DIR"
  else
    # --unattended so the installer neither starts a shell nor rewrites the
    # login shell behind our back. CHSH=no matters more here than on Linux:
    # the login shell is already zsh, so the only thing chsh could do is point
    # it somewhere else.
    if RUNZSH=no CHSH=no sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended >/dev/null 2>&1; then
      result 'installed' 'oh-my-zsh' "$OMZ_DIR"
    else
      result 'failed' 'oh-my-zsh' 'installer failed'
    fi
  fi

  # ZSH_CUSTOM_PLUGINS is empty on macOS and the theme is a formula, so in
  # practice this loop does nothing here - every one of them comes from
  # Homebrew and is sourced by path in the fragment below. The loop stays
  # because the category has not stopped existing: an oh-my-zsh plugin with no
  # formula would still be cloned, and the Linux script uses the same shape.
  if [[ -d "$OMZ_DIR" || "$DRY_RUN" == "yes" ]]; then
    for entry in ${ZSH_CUSTOM_PLUGINS[@]+"${ZSH_CUSTOM_PLUGINS[@]}"}; do
      [[ -z "$entry" ]] && continue
      git_clone_or_update "plugin: ${entry%%|*}" "${OMZ_CUSTOM}/plugins/${entry%%|*}" "${entry#*|}"
    done
  fi

  # Completion directory permissions, and this is here because the fragment
  # below is what causes the problem. Adding <prefix>/share/zsh-completions to
  # fpath brings it, and its parents, into what oh-my-zsh audits at startup.
  #
  # Homebrew creates <prefix>/share group-writable for the admin group. zsh
  # treats a group-writable directory on fpath as untrusted, and oh-my-zsh
  # turns that into a refusal: it prints "Insecure completion-dependent
  # directories detected" and then loads NO completions at all - not merely the
  # ones from the offending directory. So installing zsh-completions can leave
  # you with fewer completions than before it, which is a memorable afternoon.
  #
  # Fixed rather than reported, because this script created the condition. It
  # is the same chmod the zsh-completions formula prints in its own caveat.
  # Note that `brew` may recreate the group bit on a later install into share/;
  # a re-run puts it back.
  COMPFIX_DIRS=(
    "${BREW_PREFIX}/share"
    "${BREW_PREFIX}/share/zsh"
    "${BREW_PREFIX}/share/zsh/site-functions"
    "${BREW_PREFIX}/share/zsh-completions"
  )
  INSECURE_DIRS=()
  for d in "${COMPFIX_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    # stat -f is the BSD spelling; %Sp gives the symbolic mode, so the group
    # write bit is character 6 and the other write bit is character 9.
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

  # ~/.zshenv, and it is here because it is the only file zsh reads on EVERY
  # invocation - login, interactive, script, `zsh -c`, and the one-shot shell
  # an editor or a GUI app spawns to run a command. Neither place this script
  # already writes `brew shellenv` covers that: ~/.zprofile is login-only and
  # the fragment below is interactive-only. So `zsh -c 'bat file'` ran with no
  # Homebrew on PATH and failed on a binary the manifest had just installed.
  #
  # What may go in this file is therefore narrow. It must be silent, because
  # anything printed here corrupts the output of every script; and it must be
  # fast, because every zsh pays for it. `brew shellenv` only exports
  # variables, so it qualifies - and almost nothing else does.
  #
  # The .zprofile line stays as well, and is not redundant: shellenv PREPENDS,
  # so re-running it in a login shell re-asserts the prefix ahead of anything
  # that reordered PATH in between. The duplicate entry is one a modern
  # shellenv dedupes.
  #
  # Fragment plus a source line, the same shape as .zshrc below and for the
  # same reason: a .zshenv that already exists is somebody's own work.
  ZSHENV="${HOME}/.zshenv"
  ZSHENV_FRAGMENT="${HOME}/.zshenv.bootstrap"
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'zshenv config' "$ZSHENV_FRAGMENT"
  else
    NEW_ZSHENV="$(mktemp "${ZSHENV_FRAGMENT}.XXXXXX")"
    chmod 0644 "$NEW_ZSHENV"
    {
      echo "# managed by macos/bootstrap.sh - edit the manifest, not this file"
      echo '#'
      echo '# Sourced from ~/.zshenv, which zsh reads on every invocation - scripts'
      echo '# included. Keep it silent and cheap: no echo, no prompts, nothing slow.'
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

    # Matched on a line that actually sources the fragment, not on any mention
    # of the name, so a comment about this file is not mistaken for the hook.
    # grep's exit 1 is the `if` condition here, not inside a command
    # substitution, so pipefail has nothing to kill.
    ZSHENV_SOURCE_LINE='[ -f "$HOME/.zshenv.bootstrap" ] && source "$HOME/.zshenv.bootstrap"'
    if [[ -f "$ZSHENV" ]] && grep -qE '^[^#]*(source|\.)[[:space:]].*\.zshenv\.bootstrap' "$ZSHENV"; then
      result 'current' 'zshenv hook' "$ZSHENV"
    else
      printf '\n%s\n' "$ZSHENV_SOURCE_LINE" >> "$ZSHENV"
      result 'installed' 'zshenv hook' "appended to $ZSHENV"
    fi
  fi

  # The managed fragment, not the whole .zshrc. Anything else in that file is
  # somebody's own work; this writes one clearly-marked block and leaves the
  # rest alone, the same rule the Windows profile and the Linux script follow.
  ZSHRC="${HOME}/.zshrc"
  FRAGMENT="${HOME}/.zshrc.bootstrap"
  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'zsh config' "$FRAGMENT"
  else
    # Rendered to a temp file beside the target and compared, so a run that
    # changes nothing says `current` instead of claiming an install. Same
    # filesystem, so the replace is an atomic rename; the mode is set here
    # rather than inherited from mktemp's 0600.
    NEW_FRAGMENT="$(mktemp "${FRAGMENT}.XXXXXX")"
    chmod 0644 "$NEW_FRAGMENT"
    {
      echo "# managed by macos/bootstrap.sh - edit the manifest, not this file"
      echo
      echo '# The powerlevel10k instant prompt, and it is FIRST for a reason: it'
      echo '# replays a cached prompt before the rest of this file runs, so the'
      echo '# terminal is usable immediately instead of after every eval below.'
      echo '# Anything that writes to the console above it corrupts the replay,'
      echo '# which is why it precedes even brew shellenv.'
      echo '#'
      echo '# The consequence for ~/.zshrc is that the line sourcing THIS file'
      echo '# has to be near the top of it. Code that prompts for input - a'
      echo '# password, a [y/n] - is the one thing that must go above it.'
      echo '#'
      echo '# The cache does not exist on the first run, so the guard fails and'
      echo '# the prompt is simply not instant that once.'
      echo 'if [ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]; then'
      echo '  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"'
      echo 'fi'
      echo
      echo '# Homebrew first, and unconditional: nothing below can find a brew-'
      echo '# installed binary until the prefix is on PATH. The prefix differs by'
      echo '# architecture - /opt/homebrew on Apple silicon, /usr/local on Intel -'
      echo '# so this is written for the machine it was generated on.'
      echo "[ -x \"${BREW_PREFIX}/bin/brew\" ] && eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
      echo
      echo "export ZSH=\"$OMZ_DIR\""
      echo "ZSH_THEME=\"$ZSH_THEME\""
      echo
      echo '# zsh-completions ships completion FUNCTIONS, not a plugin to'
      echo '# source, so its directory has to be on fpath before compinit runs'
      echo '# - and oh-my-zsh runs compinit inside oh-my-zsh.sh. Adding it'
      echo '# afterwards is the classic way to install this and see no new'
      echo '# completions at all.'
      echo "fpath+=(\"${BREW_PREFIX}/share/zsh-completions\")"
      echo
      # No NVM_DIR or nvm zstyle here any more. The oh-my-zsh nvm plugin is not
      # in the macOS plugin list at all - see packages.conf for why - so there
      # is nothing left that has to be set before oh-my-zsh.sh is sourced. nvm
      # is configured further down with the other version managers instead.
      printf 'plugins=(%s)\n' "${ZSH_PLUGINS[*]}"
      echo 'source "$ZSH/oh-my-zsh.sh"'
      echo
      echo '# The theme and the four add-on plugins, sourced by path because'
      echo '# Homebrew installed them and oh-my-zsh only finds things under'
      echo '# $ZSH_CUSTOM. On the Linux side these are clones there and are'
      echo '# named in plugins=() instead; this is the same set, loaded'
      echo '# differently.'
      echo '#'
      echo '# ORDER IS LOAD-BEARING and it is the same set of rules the plugin'
      echo '# list used to encode, now that nothing else enforces them:'
      echo '#'
      echo '#   fzf-tab must come AFTER compinit, which oh-my-zsh.sh just ran,'
      echo '#   and BEFORE anything that wraps ZLE widgets.'
      echo '#'
      echo '#   zsh-syntax-highlighting must be LAST but one. It wraps every ZLE'
      echo '#   widget that exists when it loads, so a plugin sourced after it'
      echo '#   defines its widgets outside that wrapping and goes unhighlighted.'
      echo '#'
      echo '#   history-substring-search is the documented exception and must'
      echo '#   come after the highlighter, which is why it is last.'
      echo "[ -r \"${BREW_PREFIX}/share/powerlevel10k/powerlevel10k.zsh-theme\" ] && source \"${BREW_PREFIX}/share/powerlevel10k/powerlevel10k.zsh-theme\""
      echo "# fzf-tab.zsh, NOT fzf-tab.plugin.zsh. The upstream repository names"
      echo "# it the second way and every oh-my-zsh guide says so; the Homebrew"
      echo "# formula installs it as the first. Getting this wrong fails the -r"
      echo "# guard and loads nothing, with no error anywhere."
      echo "[ -r \"${BREW_PREFIX}/share/fzf-tab/fzf-tab.zsh\" ] && source \"${BREW_PREFIX}/share/fzf-tab/fzf-tab.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-autosuggestions/zsh-autosuggestions.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh\""
      echo "[ -r \"${BREW_PREFIX}/share/zsh-history-substring-search/zsh-history-substring-search.zsh\" ] && source \"${BREW_PREFIX}/share/zsh-history-substring-search/zsh-history-substring-search.zsh\""
      echo
      echo '# Sourcing history-substring-search is not enough to USE it. The'
      echo '# plugin ships no keybindings at all - upstream leaves that to the'
      echo '# caller - so without these lines it loads, defines its widgets, and'
      echo '# nothing you press ever reaches them. oh-my-zsh bundles a copy that'
      echo '# does bind keys, which is exactly why this is easy to miss: drop the'
      echo '# omz plugin for the newer standalone one and the feature silently'
      echo '# stops working.'
      echo '#'
      echo '# Both spellings of up/down are bound. A terminal in application'
      echo '# cursor mode sends the terminfo sequence and a terminal outside it'
      echo '# sends the raw escape, and which one you get varies by terminal and'
      echo '# by whether zle has started - so binding one of the two works'
      echo '# everywhere except where it does not.'
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
      echo '# The prompt configuration itself, which is NOT part of the formula.'
      echo '# powerlevel10k without it runs its configuration wizard on every new'
      echo '# shell until you answer it, and answering writes ~/.p10k.zsh - which'
      echo '# then has to be sourced or the answers do nothing. This file is'
      echo '# yours, not managed here; the theme has to come first, above.'
      echo '[ -r "$HOME/.p10k.zsh" ] && source "$HOME/.p10k.zsh"'
      echo
      echo '# The right prompt - kube context, node version, clock - earns its'
      echo '# place while you type and is noise the moment the command scrolls'
      echo '# away: it sits at the far right of every line in the scrollback, so'
      echo '# selecting a command to copy drags "system kube-ctx 17:17" along'
      echo '# with it. TRANSIENT_RPROMPT erases it when the line is accepted, so'
      echo '# only the prompt you are typing at carries it. The left side is the'
      echo '# same idea under POWERLEVEL9K_TRANSIENT_PROMPT, which lives in'
      echo '# ~/.p10k.zsh - yours, not managed here.'
      echo 'setopt TRANSIENT_RPROMPT'
      echo
      echo '# Completion styling, and the fzf-tab settings without which fzf-tab'
      echo '# is inert. `menu no` is the load-bearing one: zsh menu selection and'
      echo '# fzf-tab both want to own the completion UI, and if zsh has it,'
      echo '# fzf-tab is sourced, working, and never invoked - the same silent'
      echo '# nothing as the keybindings above.'
      echo 'zstyle '"'"':completion:*'"'"' list-colors "${(s.:.)LS_COLORS}"'
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
      echo '# History, sized so a busy week does not quietly drop the command'
      echo '# you wanted. HISTSIZE is what the running shell holds; SAVEHIST is'
      echo '# what reaches the file, and it must not be smaller or the file is'
      echo '# truncated on every exit - the classic way to lose history while'
      echo '# believing it is being kept.'
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
      echo '# Aliases guard on command -v so the fragment still works on a machine'
      echo '# where one of these failed to install - a blind alias to a missing'
      echo '# binary breaks the normal command entirely. Unlike Debian, Homebrew'
      echo '# does not rename bat or fd, so there is no batcat/fdfind dance here.'
      echo '#'
      echo '# Two of the flags are about behaving like the command being'
      echo '# replaced rather than like the replacement. `bat` pages by default'
      echo '# and `cat` does not, so --paging=never; `eza --icons` emits icons'
      echo '# even into a pipe, where they become mojibake in whatever reads'
      echo '# them, so --icons=auto ties them to stdout being a terminal.'
      echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
      echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
      echo 'command -v rg     >/dev/null && alias grep="rg"'
      echo 'command -v fd     >/dev/null && alias find="fd"'
      echo '#'
      echo '# du/df to dust/duf are a bigger change of shape than the pairs above:'
      echo '# dust prints a tree with bars, duf a table with different columns, and'
      echo '# neither is a drop-in for a script parsing `du -sh` or `df -h` output -'
      echo '# that script should keep calling the real binary, not this alias.'
      echo 'command -v dust   >/dev/null && alias du="dust"'
      echo 'command -v duf    >/dev/null && alias df="duf"'
      echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
      echo
      echo '# `tools` prints every package this bootstrap manages, grouped the same'
      echo '# way `--list-packages` does. Baked in at THIS run, same as the aliases'
      echo '# above - it goes stale exactly the way they would if the manifest'
      echo '# changed and the script did not run again since.'
      echo 'tools() {'
      echo '  echo'
      for g in "${PKG_GROUPS[@]}"; do
        declare -n _form="GROUP_${g}_FORMULA"
        declare -n _cask="GROUP_${g}_CASK"
        printf "  echo '  %s'\n" "$g"
        for pkg in "${_form[@]:-}" "${_cask[@]:-}"; do
          [[ -z "$pkg" ]] && continue
          printf "  echo '    %s'\n" "$pkg"
        done
        unset -n _form _cask
      done
      echo '  echo'
      echo '}'
      echo
      echo '# GNU make arrives as gmake because /usr/bin/make is BSD make and'
      echo '# Homebrew will not shadow the system one. Almost every Makefile worth'
      echo '# running expects GNU; if you need the BSD one, /usr/bin/make is still'
      echo '# there under its full path.'
      echo 'command -v gmake  >/dev/null && alias make="gmake"'
      echo
      echo '# Nothing on macOS puts this on PATH by default, and it is where a'
      echo '# `pip install --user` and any hand-installed binary land - so a'
      echo '# command can be on disk and not exist without this line.'
      echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
      echo
      echo '# Version managers, ahead of anything the platform ships, so a'
      echo '# project pin wins over the machine default whenever there is one.'
      echo '#'
      echo '# All four come from Homebrew here, so none of them needs a PATH'
      echo '# entry of its own - brew shellenv above already put its bin'
      echo '# directory in front. The Linux fragment prepends $HOME/.pyenv/bin'
      echo '# and $HOME/.tofuenv/bin because there they are git clones.'
      echo 'command -v pyenv >/dev/null && eval "$(pyenv init -)"'
      echo '# pyenv-virtualenv is a separate init and a separate formula. Without'
      echo '# this line the plugin is installed and does nothing: `pyenv'
      echo '# virtualenv` still creates environments, but none of them ever'
      echo '# activate on cd.'
      echo 'command -v pyenv-virtualenv-init >/dev/null && eval "$(pyenv virtualenv-init -)"'
      echo
      echo '# nvm, and the two halves of it are deliberately different places.'
      echo '#'
      echo '# NVM_DIR is the DATA directory - where installed node versions'
      echo '# live - and it must NOT be the brew prefix. Homebrew says so'
      echo '# itself: leaving it at the Cellar path "will destroy any'
      echo '# nvm-installed Node installations upon upgrade/reinstall", because'
      echo '# `brew upgrade nvm` replaces that directory wholesale. ~/.nvm'
      echo '# survives, and is also where the Linux side keeps the same data.'
      echo '#'
      echo '# nvm.sh itself comes from the brew prefix, since that is the copy'
      echo '# brew installed. The oh-my-zsh nvm plugin cannot express this split'
      echo '# - it sources $NVM_DIR/nvm.sh and nothing else - which is why the'
      echo '# plugin is not in the list and this is written out by hand.'
      echo 'export NVM_DIR="$HOME/.nvm"'
      echo '[ -d "$NVM_DIR" ] || mkdir -p "$NVM_DIR"'
      echo
      echo '# LAZY, for the reason the plugin was lazy: nvm is a large shell'
      echo '# script and sourcing it eagerly is the single most common reason a'
      echo '# zsh startup stops being instant - easily a few hundred'
      echo '# milliseconds on every new terminal. These stubs replace themselves'
      echo '# with the real thing on first use, so the first `nvm`, `node` or'
      echo '# `npm` pays that cost once and no other shell pays it at all.'
      echo "_bootstrap_load_nvm() {"
      echo "  unfunction nvm node npm npx _bootstrap_load_nvm 2>/dev/null"
      echo "  [ -s \"${BREW_PREFIX}/opt/nvm/nvm.sh\" ] && . \"${BREW_PREFIX}/opt/nvm/nvm.sh\""
      echo "  [ -s \"${BREW_PREFIX}/opt/nvm/etc/bash_completion.d/nvm\" ] && . \"${BREW_PREFIX}/opt/nvm/etc/bash_completion.d/nvm\""
      echo "}"
      echo "if [ -s \"${BREW_PREFIX}/opt/nvm/nvm.sh\" ]; then"
      echo '  for _cmd in nvm node npm npx; do'
      echo '    eval "${_cmd}() { _bootstrap_load_nvm; ${_cmd} \"\$@\"; }"'
      echo '  done'
      echo '  unset _cmd'
      echo 'fi'
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

    # Sourced from .zshrc rather than written into it, so re-running this never
    # has to parse or rewrite a file the user owns.
    SOURCE_LINE='[ -f "$HOME/.zshrc.bootstrap" ] && source "$HOME/.zshrc.bootstrap"'
    if [[ -f "$ZSHRC" ]] && grep -qF '.zshrc.bootstrap' "$ZSHRC"; then
      result 'current' 'zshrc hook' "$ZSHRC"
    else
      printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
      result 'installed' 'zshrc hook' "appended to $ZSHRC"
    fi

    # Appending is safe but not always right, and the difference is visible
    # rather than silent, so it is reported instead of guessed at. The fragment
    # now opens with the powerlevel10k instant prompt, which only does anything
    # if it runs before the rest of the file - so a hook sitting under 80 lines
    # of somebody's own config is a working shell with a feature quietly
    # switched off. Rewriting a file the user owns to fix that is not this
    # script's call to make; saying so is.
    if [[ -f "$ZSHRC" ]]; then
      # Matched on a line that actually SOURCES the fragment, not on any
      # mention of it. A comment naming the file - and this script encourages
      # writing one - is not the hook, and counting from it measures nothing.
      # grep exits 1 with no match, which under pipefail would kill the script
      # from inside `$(...)`. That is a real path here: the outer if guarded
      # only on a literal filename mention, so a `.zshrc` that names the file
      # in a comment but never sources it reaches this line with no match.
      # `|| true` on the pipeline, and the intended fallback below still runs.
      HOOK_LINE="$(grep -nE '^[^#]*(source|\.)[[:space:]].*\.zshrc\.bootstrap' "$ZSHRC" | head -1 | cut -d: -f1 || true)"
      [[ -z "$HOOK_LINE" ]] && HOOK_LINE=1
      # grep -c exits 1 when the count is zero - the case where the file above
      # the hook is entirely comments and blanks, which is exactly the shape a
      # tidy .zshrc has. Under `set -euo pipefail` that kills the script mid-
      # phase, so the pipeline is guarded and the count defaulted to 0.
      CODE_ABOVE="$(head -n "$(( HOOK_LINE - 1 ))" "$ZSHRC" | grep -cvE '^[[:space:]]*(#|$)' || true)"
      CODE_ABOVE="${CODE_ABOVE:-0}"
      if [[ "${CODE_ABOVE:-0}" -gt 0 ]]; then
        result 'missing' 'zshrc hook order' \
          "$CODE_ABOVE lines run before it - move the source line to the top for the instant prompt"
      fi
    fi
  fi
fi

# ============================================================
# Terminal config
# ============================================================
# The payoff for choosing ghostty: its config is a plain text file, so it gets
# the same treatment as the zsh fragment - rendered, compared, and reported as
# `current` when nothing moved.
#
# ~/.config/ghostty/config on both platforms. macOS also reads a path under
# ~/Library/Application Support, but it honours the XDG one too, and one path
# in the script beats two.

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
    NEW_GHOSTTY="$(mktemp "${GHOSTTY_CONF}.XXXXXX")"
    chmod 0644 "$NEW_GHOSTTY"
    {
      echo "# managed by bootstrap.sh - edit the manifest, not this file"
      echo
      echo "# Bytes, not lines, and there is no unlimited setting - ghostty says an"
      echo "# unlimited buffer is a planned feature, not a current one. This is"
      echo "# 256MB, and it is PER SURFACE: every tab and split gets its own, and"
      echo "# the buffer lives in RAM. A cap, not a preallocation, so an idle tab"
      echo "# costs nothing."
      echo "#"
      echo "# Note what this does NOT cover. Scrollback belongs to the window and"
      echo "# dies with it, and inside tmux it is bypassed entirely - tmux owns"
      echo "# the screen and keeps its own buffer. For output you want to still"
      echo "# have tomorrow, redirect it to a file."
      echo "scrollback-limit = ${GHOSTTY_SCROLLBACK_BYTES}"
      echo
      echo "# A name that matches a row from \`ghostty +list-themes\`. Ghostty ships"
      echo "# 463 of them; changing this line is the whole change of palette."
      echo "theme = ${GHOSTTY_THEME}"
      echo
      echo "# The Meslo Nerd Font the manifest installs. Family name from the face"
      echo "# table (spaces), not the ttf filename. Blank falls back to SF Mono."
      [[ -n "${GHOSTTY_FONT_FAMILY:-}" ]] && echo "font-family = ${GHOSTTY_FONT_FAMILY}"
      echo "font-size = ${GHOSTTY_FONT_SIZE}"
      echo
      echo "# Option is Meta, so Option-f/b/arrows produce the word-wise escape"
      echo "# sequences readline, zsh and vim recognise. macOS's default reverses"
      echo "# this to keep the typographic bindings, which nobody uses at a terminal."
      echo "macos-option-as-alt = ${GHOSTTY_MACOS_OPTION_AS_ALT}"
      echo
      echo "# Restore tabs and splits across a plain quit-and-relaunch. The default"
      echo "# only restores when the OS asks; \`always\` covers Cmd-Q too."
      echo "window-save-state = ${GHOSTTY_WINDOW_SAVE_STATE}"
      echo
      echo "# Select-to-copy. Cmd-Shift-C still works and is unaffected; this is"
      echo "# the extra convenience, at the cost of a stray selection replacing"
      echo "# whatever was on the clipboard."
      echo "copy-on-select = ${GHOSTTY_COPY_ON_SELECT}"
      echo
      echo "# End the process when the last window closes, matching CLI convention."
      echo "# macOS's default keeps the app alive with no visible window."
      echo "quit-after-last-window-closed = ${GHOSTTY_QUIT_AFTER_LAST_WINDOW}"
      echo
      echo "# Ghostty auto-installs the shell hooks; this opts INTO the extras."
      echo "# \`cursor\` follows zsh vi-mode, \`sudo\` preserves prompt state through"
      echo "# sudo, \`title\` tracks cwd in the terminal title."
      echo "shell-integration-features = ${GHOSTTY_SHELL_INTEGRATION_FEATURES}"
      echo
      echo "# Quake-style drop-down terminal on Cmd-\`, global so it fires from any"
      echo "# app including full-screen ones. Blank in the manifest disables it."
      [[ -n "${GHOSTTY_QUICK_TERMINAL_KEYBIND:-}" ]] && echo "keybind = ${GHOSTTY_QUICK_TERMINAL_KEYBIND}"
      echo
      echo "# Padding between content and window edge. Ghostty's default of 2/2 is"
      echo "# visually cramped at 16pt - the prompt sits right against the frame."
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

# ============================================================
# Manual
# ============================================================
# Reported, never touched. Each of these is owned by an installer this script
# will not drive, or is a decision to make by hand.

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

# ============================================================
# Summary
# ============================================================

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
