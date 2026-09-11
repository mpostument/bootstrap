#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_VERSION='1.27.0'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
GUI_OVERRIDE=auto
ONLY_GROUPS=""

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

# Arrays, the bash 3.2 way
group_array() {   # group_array <dest> <source-array-name>
  eval "$1=()"
  declare -p "$2" >/dev/null 2>&1 || return 0
  eval "if (( \${#$2[@]} )); then $1=(\"\${$2[@]}\"); fi"
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
  echo
  exit 0
fi

# Preflight

phase 'Preflight'

[[ "$(uname -s)" == "Darwin" ]] || die "this script targets macOS (uname says $(uname -s))"

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
    elif "$BREW" tap "$tap_name" >/dev/null 2>&1; then
      result 'installed' "tap: $tap_desc" "$tap_name"
    else
      result 'failed' "tap: $tap_desc" "brew tap $tap_name failed"
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
  elif "$BREW" upgrade --formula >/dev/null 2>&1; then
    result 'upgraded' 'brew formulae' "$n_formulae package(s)"
  else
    result 'failed' 'brew formulae' 'brew upgrade failed'
  fi

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

  self_updating="$(comm -13 \
    <(printf '%s\n' "$outdated_casks" | grep . | sort || true) \
    <(brew_outdated --cask --greedy | grep . | sort || true) || true)"
  if [[ -n "$self_updating" ]]; then
    result 'present' 'self-updating casks' "$(tr '\n' ' ' <<< "$self_updating")- left to their own updaters"
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

# zsh

if [[ "${ZSH_ENABLED:-no}" != "yes" ]]; then
  phase 'zsh - disabled in the manifest'
else
  phase 'zsh - oh-my-zsh, theme and plugins'

  OMZ_DIR="${ZSH:-$HOME/.oh-my-zsh}"
  OMZ_CUSTOM="${OMZ_DIR}/custom"

  result 'present' 'zsh' "$(/bin/zsh --version 2>/dev/null | awk '{print $2}' || echo 'system')"

  if [[ -d "$OMZ_DIR" ]]; then
    result 'current' 'oh-my-zsh' "$OMZ_DIR"
  elif [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' 'oh-my-zsh' "$OMZ_DIR"
  else
    if RUNZSH=no CHSH=no sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
        "" --unattended >/dev/null 2>&1; then
      result 'installed' 'oh-my-zsh' "$OMZ_DIR"
    else
      result 'failed' 'oh-my-zsh' 'installer failed'
    fi
  fi

  if [[ -d "$OMZ_DIR" || "$DRY_RUN" == "yes" ]]; then
    for entry in ${ZSH_CUSTOM_PLUGINS[@]+"${ZSH_CUSTOM_PLUGINS[@]}"}; do
      [[ -z "$entry" ]] && continue
      git_clone_or_update "plugin: ${entry%%|*}" "${OMZ_CUSTOM}/plugins/${entry%%|*}" "${entry#*|}"
    done
  fi

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
    NEW_ZSHENV="$(mktemp "${ZSHENV_FRAGMENT}.XXXXXX")"
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
    NEW_FRAGMENT="$(mktemp "${FRAGMENT}.XXXXXX")"
    chmod 0644 "$NEW_FRAGMENT"
    {
      echo
      echo "[ -x \"${BREW_PREFIX}/bin/brew\" ] && eval \"\$(${BREW_PREFIX}/bin/brew shellenv)\""
      echo
      echo "export ZSH=\"$OMZ_DIR\""
      echo "ZSH_THEME=\"$ZSH_THEME\""
      echo
      echo "fpath+=(\"${BREW_PREFIX}/share/zsh-completions\")"
      echo
      printf 'plugins=(%s)\n' "${ZSH_PLUGINS[*]}"
      echo 'source "$ZSH/oh-my-zsh.sh"'
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
      echo '    (kubectl|kubectl-*|k|kubectx|kubens|kustomize|k9s|stern|helm|helmfile|flux|argocd|velero|skaffold|kubeseal)'
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
      echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
      echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
      echo 'command -v rg     >/dev/null && alias grep="rg"'
      echo 'command -v fd     >/dev/null && alias find="fd"'
      echo 'command -v dust   >/dev/null && alias du="dust"'
      echo 'command -v duf    >/dev/null && alias df="duf"'
      echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
      echo
      _parity_pkg=() _parity_cmd=() _parity_desc=()
      if [[ -r "$SCRIPT_DIR/../tools/cli-parity.conf" ]]; then
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
      fi
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
      echo 'command -v pyenv >/dev/null && eval "$(pyenv init -)"'
      echo 'command -v pyenv-virtualenv-init >/dev/null && eval "$(pyenv virtualenv-init -)"'
      echo
      echo 'export NVM_DIR="$HOME/.nvm"'
      echo '[ -d "$NVM_DIR" ] || mkdir -p "$NVM_DIR"'
      echo
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

    SOURCE_LINE='[ -f "$HOME/.zshrc.bootstrap" ] && source "$HOME/.zshrc.bootstrap"'
    if [[ -f "$ZSHRC" ]] && grep -qF '.zshrc.bootstrap' "$ZSHRC"; then
      result 'current' 'zshrc hook' "$ZSHRC"
    else
      printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
      result 'installed' 'zshrc hook' "appended to $ZSHRC"
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

# Git config
# Set only when unset: an existing value is somebody's choice, not drift.
phase 'Git config'
if ! command -v git >/dev/null 2>&1; then
  result 'missing' 'delta' 'git is not installed'
elif ! command -v delta >/dev/null 2>&1; then
  result 'missing' 'delta' 'delta is not installed'
else
  GIT_WANT=('core.pager=delta' 'interactive.diffFilter=delta --color-only')
  for _kv in "${GIT_WANT[@]}"; do
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
    NEW_GHOSTTY="$(mktemp "${GHOSTTY_CONF}.XXXXXX")"
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

# Manual

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
