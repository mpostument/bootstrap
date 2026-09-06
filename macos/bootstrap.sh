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

BOOTSTRAP_VERSION='1.0.0'

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
                DOTNET_ENABLED ZSH_ENABLED \
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
# .NET SDK
# ============================================================

if [[ "${DOTNET_ENABLED:-no}" != "yes" ]]; then
  phase 'dotnet - disabled in the manifest'
else
  phase 'dotnet - SDK from the vendor script'
  dotnet_exe="${DOTNET_DIR}/dotnet"
  if [[ -x "$dotnet_exe" ]]; then
    # Every SDK on disk, not just the newest. dotnet-install.sh installs side
    # by side, so a channel rollover leaves the previous major here forever -
    # visible rather than silently accumulating.
    versions="$("$dotnet_exe" --list-sdks 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
    if [[ "$SKIP_UPGRADE" == "yes" ]]; then
      result 'skipped' 'dotnet SDK' "${versions:-present}"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-upgrade' 'dotnet SDK' "channel ${DOTNET_CHANNEL}, have ${versions:-none}"
    else
      tmp_script="$(mktemp)"
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
    tmp_script="$(mktemp)"
    if curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tmp_script" 2>/dev/null &&
       bash "$tmp_script" --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_DIR" >/dev/null 2>&1; then
      result 'installed' 'dotnet SDK' "$("$dotnet_exe" --list-sdks 2>/dev/null | awk '{print $1}' | paste -sd, - || true)"
    else
      result 'failed' 'dotnet SDK' 'dotnet-install.sh failed'
    fi
    rm -f "$tmp_script"
  fi
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

  if [[ -d "$OMZ_DIR" || "$DRY_RUN" == "yes" ]]; then
    git_clone_or_update 'powerlevel10k' "${OMZ_CUSTOM}/themes/powerlevel10k" "$ZSH_THEME_REPO"
    for entry in "${ZSH_CUSTOM_PLUGINS[@]:-}"; do
      [[ -z "$entry" ]] && continue
      git_clone_or_update "plugin: ${entry%%|*}" "${OMZ_CUSTOM}/plugins/${entry%%|*}" "${entry#*|}"
    done
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
      echo '# Homebrew first, and unconditional: nothing below can find a brew-'
      echo '# installed binary until the prefix is on PATH. The prefix differs by'
      echo '# architecture - /opt/homebrew on Apple silicon, /usr/local on Intel -'
      echo '# so this is written for the machine it was generated on.'
      echo "[ -x \"${BREW_PREFIX}/bin/brew\" ] && eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
      echo
      echo "export ZSH=\"$OMZ_DIR\""
      echo "ZSH_THEME=\"$ZSH_THEME\""
      echo
      echo '# Both of these have to precede oh-my-zsh.sh, because the nvm plugin'
      echo '# reads them as it loads. NVM_DIR is where the TOOLS clone put it;'
      echo '# lazy defers sourcing nvm.sh until the first nvm, node or npm, which'
      echo '# keeps a few hundred milliseconds off every shell that never uses it.'
      echo 'export NVM_DIR="$HOME/.nvm"'
      echo "zstyle ':omz:plugins:nvm' lazy yes"
      echo
      printf 'plugins=(%s)\n' "${ZSH_PLUGINS[*]}"
      echo 'source "$ZSH/oh-my-zsh.sh"'
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
      echo 'command -v bat    >/dev/null && alias cat="bat"'
      echo 'command -v eza    >/dev/null && alias ls="eza --icons --group-directories-first"'
      echo 'command -v rg     >/dev/null && alias grep="rg"'
      echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
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
      echo '[ -d "$HOME/.pyenv/bin" ] && export PATH="$HOME/.pyenv/bin:$PATH"'
      echo 'command -v pyenv >/dev/null && eval "$(pyenv init -)"'
      echo '[ -d "$HOME/.tfenv/bin" ] && export PATH="$HOME/.tfenv/bin:$PATH"'
      echo
      echo '# nvm is loaded LAZILY, by the oh-my-zsh plugin rather than by'
      echo '# sourcing nvm.sh here. nvm is a large shell script and sourcing it'
      echo '# eagerly is the single most common reason a zsh startup stops being'
      echo '# instant - it is easily a few hundred milliseconds on every new'
      echo '# terminal. Lazy means the first `nvm`, `node` or `npm` pays that'
      echo '# cost once and no other shell pays it at all.'
      echo '#'
      echo '# NVM_DIR and the zstyle must both be set BEFORE oh-my-zsh.sh is'
      echo '# sourced above, which is why they are not down here with the rest.'
      echo
      echo '# Not managed by any of them: the SDK installs side by side under'
      echo '# its own directory and there is no per-project version to pick.'
      echo '[ -d "$HOME/.dotnet" ] && export PATH="$HOME/.dotnet:$PATH" && export DOTNET_ROOT="$HOME/.dotnet"'
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
