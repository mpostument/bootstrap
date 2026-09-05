#!/usr/bin/env bash
#
# Installs and updates this machine's software from packages.conf.
#
# Run it on a fresh machine to build it out; run it again any time to take
# updates. Both are the same command - the script works out per package which
# one it is doing.
#
# See README.md.

set -euo pipefail

BOOTSTRAP_VERSION='1.1.0'

# Resolved once, here, so nothing later has to guess where the script lives.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
ASSUME_YES=no
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
RESULT_LINES=()

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
  RESULT_LINES+=("$action")
}

die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ============================================================
# Is there a desktop on this machine?
# ============================================================
# The question is "does this machine have a desktop environment", and the two
# obvious ways to answer it are both wrong.
#
# $DISPLAY / $WAYLAND_DISPLAY describe THIS SESSION, not the machine. They are
# unset when you SSH into your own workstation, so a desktop looks headless;
# they are SET when you SSH into a headless server with X forwarding, so a
# server looks like a desktop; and WSLg sets both on a WSL install that has no
# desktop environment at all. Measured on WSL Ubuntu 24.04: DISPLAY=:0 and
# WAYLAND_DISPLAY=wayland-0, with no display manager and zero session files.
#
# `systemctl get-default` is closer but still lies: the same WSL install
# reports graphical.target.
#
# So ask what is actually installed instead. A machine that can start a desktop
# session has either a display manager or session .desktop files - usually
# both, and neither appears by accident. That answer is the same over SSH as it
# is at the keyboard, which is the property that matters for a tool that is
# meant to run unattended.
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

# ============================================================
# Package state
# ============================================================

apt_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'
}

# Present in the archive at all. A name that is simply not packaged for this
# release should be reported as such, not attempted and failed - the two look
# identical in apt's output and mean very different things.
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
  --gui / --no-gui   Override desktop detection instead of probing for it.
  --yes              Pass -y to apt. Implied when not attached to a terminal.
  --version          Print the version and exit.
  -h, --help         This text.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=yes ;;
    --skip-upgrade) SKIP_UPGRADE=yes ;;
    --yes|-y)       ASSUME_YES=yes ;;
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

[[ -t 0 ]] || ASSUME_YES=yes

# ============================================================
# Manifest
# ============================================================

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
# shellcheck source=packages.conf
source "$MANIFEST"

# Checked here, once, rather than discovered halfway through a run. A manifest
# that sources cleanly is not a manifest that is complete.
for required in PKG_GROUPS MANUAL HELD TOOLS REPOS ZSH_PLUGINS ZSH_CUSTOM_PLUGINS; do
  declare -p "$required" >/dev/null 2>&1 || die "manifest is missing \$$required: $MANIFEST"
done

if [[ "${LIST_GROUPS:-no}" == "yes" ]]; then
  echo
  for g in "${PKG_GROUPS[@]}"; do
    desc_var="GROUP_${g}_DESC"
    gui_var="GROUP_${g}_GUI"
    # Nameref rather than eval: it is what bash provides for exactly this, and
    # it keeps the array an array instead of round-tripping through a string.
    declare -n _apt="GROUP_${g}_APT"
    declare -n _flat="GROUP_${g}_FLATPAK"
    total=$(( ${#_apt[@]} + ${#_flat[@]} ))
    gui_tag='               '
    [[ "${!gui_var:-no}" == "yes" ]] && gui_tag='[needs desktop]'
    printf '  %s%-10s%s %-3s packages  %s%s%s  %s\n' \
      "$C_CYAN" "$g" "$C_RESET" "$total" "$C_DIM" "$gui_tag" "$C_RESET" "${!desc_var}"
    unset -n _apt _flat
  done
  echo
  exit 0
fi

# ============================================================
# Preflight
# ============================================================

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

# apt's index is read once. Refreshing it before every single package is pure
# cost, and not refreshing it at all is how a fresh machine fails to find a
# package that has been in the archive for a year.
if [[ "$DRY_RUN" == "no" ]]; then
  printf '  %-16s' 'apt index'
  if run_priv apt-get update -qq >/dev/null 2>&1; then
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
# Packages
# ============================================================

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
    # Upgrades are taken for the whole system in one transaction below rather
    # than per package: apt resolves dependencies across the set, and asking it
    # to upgrade one package at a time is both slower and more likely to hold
    # something back.
    result 'current' "$pkg" "$version"
    return
  fi
  if ! apt_available "$pkg"; then
    # Two different situations look identical to apt-cache, so say which this
    # is. During a dry run a package from a third-party repository has not been
    # added yet, so it is unknown for that reason rather than genuinely absent
    # from the release - reporting it as plain `missing` reads like a broken
    # manifest when nothing is wrong.
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

# ============================================================
# Third-party repositories
# ============================================================
# Each repository gets its own dearmoured key under /etc/apt/keyrings and a
# deb822 .sources file that names that key with Signed-By. Scoping matters: a
# key added the old way, with apt-key, is trusted for EVERY repository on the
# system, so one compromised vendor could sign a replacement for any package.
# Signed-By limits each key to the repository it came with.

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

  # {ID} and {CODENAME} from /etc/os-release. Docker publishes a separate tree
  # per distribution AND per release; pointing Ubuntu at the Debian tree
  # installs packages built against a different libc.
  local key_url="${!key_var}" uri="${!uri_var}" suites="${!suites_var}"
  key_url="${key_url//\{ID\}/$OS_ID}"; key_url="${key_url//\{CODENAME\}/$OS_CODENAME}"
  uri="${uri//\{ID\}/$OS_ID}";         uri="${uri//\{CODENAME\}/$OS_CODENAME}"
  suites="${suites//\{ID\}/$OS_ID}";   suites="${suites//\{CODENAME\}/$OS_CODENAME}"

  local keyring="${KEYRING_DIR}/${name}.gpg"
  local sources="/etc/apt/sources.list.d/${name}.sources"

  local want
  want="$(printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n' \
    "$uri" "$suites" "${!comp_var}" "$DPKG_ARCH" "$keyring")"

  if [[ -f "$sources" && -s "$keyring" ]] && [[ "$(cat "$sources" 2>/dev/null)" == "$want" ]]; then
    result 'current' "repo: $desc" "$sources"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    result 'would-install' "repo: $desc" "$uri $suites"
    return
  fi

  run_priv install -m 0755 -d "$KEYRING_DIR"
  # --dearmor unconditionally: some vendors serve ASCII armour and some serve
  # binary, and gpg is happy to re-emit binary input unchanged, so this handles
  # both without sniffing the content.
  if ! curl -fsSL "$key_url" | run_priv gpg --dearmor --yes -o "$keyring" 2>/dev/null; then
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

phase 'Repositories - third-party apt sources'

DPKG_ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
OS_ID="$(. /etc/os-release 2>/dev/null && echo "${ID:-debian}")"
OS_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-stable}")"

for repo in "${REPOS[@]:-}"; do
  [[ -z "$repo" ]] && continue
  setup_repo "$repo"
done

# One refresh for all of them, and only when something actually changed.
if [[ "$REPOS_CHANGED" == "yes" && "$DRY_RUN" == "no" ]]; then
  if run_priv apt-get update -qq >/dev/null 2>&1; then
    result 'current' 'apt index' 'refreshed for new repositories'
  else
    result 'failed' 'apt index' 'apt-get update failed after adding repositories'
  fi
fi

phase 'Repository packages'

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

for group in "${selected[@]}"; do
  desc_var="GROUP_${group}_DESC"
  gui_var="GROUP_${group}_GUI"
  needs_gui="${!gui_var:-no}"

  phase "$group - ${!desc_var}"

  if [[ "$needs_gui" == "yes" && "$HAS_GUI" != "yes" ]]; then
    # The requirement this whole script exists for: no desktop means the
    # desktop software is not installed, reported plainly rather than
    # attempted. Blender on a headless box pulls a large dependency tree for
    # something nobody can open.
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

# ============================================================
# Upgrades
# ============================================================
# One transaction for everything, after the installs, so apt resolves the whole
# set at once.

if [[ "$SKIP_UPGRADE" == "yes" ]]; then
  phase 'Upgrades - skipped (--skip-upgrade)'
elif [[ "$DRY_RUN" == "yes" ]]; then
  phase 'Upgrades'
  pending="$(apt-get --just-print upgrade 2>/dev/null | grep -c '^Inst ' || true)"
  result 'would-upgrade' 'apt packages' "$pending pending"
else
  phase 'Upgrades'
  if run_priv apt-get upgrade "${APT_OPTS[@]}" -qq >/dev/null 2>&1; then
    result 'upgraded' 'apt packages' 'system-wide'
  else
    result 'failed' 'apt packages' 'apt-get upgrade failed'
  fi
  if command -v flatpak >/dev/null 2>&1; then
    if flatpak update -y --noninteractive >/dev/null 2>&1; then
      result 'upgraded' 'flatpak apps' 'flathub'
    else
      result 'failed' 'flatpak apps' 'flatpak update failed'
    fi
  fi
fi

# ============================================================
# Tools that install themselves into $HOME
# ============================================================
# git clones, not apt packages, and deliberately not run through sudo: each of
# these lives entirely under the user's home directory. That is the point -
# nothing system-wide to conflict with the distribution's own Python or
# Terraform, and no third-party apt key to trust.

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

phase 'Tools - version managers in $HOME'

for tool in "${TOOLS[@]:-}"; do
  [[ -z "$tool" ]] && continue
  dir_var="TOOL_${tool}_DIR"
  repo_var="TOOL_${tool}_REPO"
  desc_var="TOOL_${tool}_DESC"
  git_clone_or_update "${!desc_var:-$tool}" "${!dir_var}" "${!repo_var}"
done

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
# oh-my-zsh, powerlevel10k and the plugins, matching the fleet's zsh role so a
# shell is the same wherever you land.

if [[ "${ZSH_ENABLED:-no}" != "yes" ]]; then
  phase 'zsh - disabled in the manifest'
else
  phase 'zsh - oh-my-zsh, theme and plugins'

  OMZ_DIR="${ZSH:-$HOME/.oh-my-zsh}"
  OMZ_CUSTOM="${OMZ_DIR}/custom"

  if ! command -v zsh >/dev/null 2>&1; then
    result 'missing' 'zsh' 'install the shell group first'
  else
    if [[ -d "$OMZ_DIR" ]]; then
      result 'current' 'oh-my-zsh' "$OMZ_DIR"
    elif [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' 'oh-my-zsh' "$OMZ_DIR"
    else
      # --unattended so the installer neither starts a shell nor rewrites the
      # login shell behind our back; chsh is the user's call, not this
      # script's, and doing it here is how a broken .zshrc locks somebody out.
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
    # rest alone, the same rule the Windows profile follows.
    ZSHRC="${HOME}/.zshrc"
    FRAGMENT="${HOME}/.zshrc.bootstrap"
    if [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' 'zsh config' "$FRAGMENT"
    else
      {
        echo "# managed by linux/bootstrap.sh - edit the manifest, not this file"
        echo "export ZSH=\"$OMZ_DIR\""
        echo "ZSH_THEME=\"$ZSH_THEME\""
        printf 'plugins=(%s)\n' "${ZSH_PLUGINS[*]}"
        echo 'source "$ZSH/oh-my-zsh.sh"'
        echo
        echo '# Aliases guard on command -v: these binaries are renamed on Debian'
        echo '# (fd-find -> fdfind, bat -> batcat) and absent on some releases, and a'
        echo '# blind alias to a missing binary breaks the normal command entirely.'
        echo 'command -v batcat >/dev/null && alias cat="batcat"'
        echo 'command -v bat    >/dev/null && alias cat="bat"'
        echo 'command -v eza    >/dev/null && alias ls="eza --icons --group-directories-first"'
        echo 'command -v fdfind >/dev/null && alias fd="fdfind"'
        echo 'command -v rg     >/dev/null && alias grep="rg"'
        echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
        echo
        echo '# Version managers, on PATH before anything the distribution ships.'
        echo '[ -d "$HOME/.pyenv/bin" ] && export PATH="$HOME/.pyenv/bin:$PATH"'
        echo 'command -v pyenv >/dev/null && eval "$(pyenv init -)"'
        echo '[ -d "$HOME/.tfenv/bin" ] && export PATH="$HOME/.tfenv/bin:$PATH"'
        echo '[ -d "$HOME/.dotnet" ] && export PATH="$HOME/.dotnet:$PATH" && export DOTNET_ROOT="$HOME/.dotnet"'
      } > "$FRAGMENT"
      result 'installed' 'zsh config' "$FRAGMENT"

      # Sourced from .zshrc rather than written into it, so re-running this
      # never has to parse or rewrite a file the user owns.
      SOURCE_LINE='[ -f "$HOME/.zshrc.bootstrap" ] && source "$HOME/.zshrc.bootstrap"'
      if [[ -f "$ZSHRC" ]] && grep -qF '.zshrc.bootstrap' "$ZSHRC"; then
        result 'current' 'zshrc hook' "$ZSHRC"
      else
        printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
        result 'installed' 'zshrc hook' "appended to $ZSHRC"
      fi
    fi
  fi
fi

# ============================================================
# Manual
# ============================================================
# Reported, never touched. Each of these needs a third-party repository and a
# signing key, which is a decision to make by hand.

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
  printf '  %sNo desktop detected, so desktop software was skipped.%s\n' "$C_DIM" "$C_RESET"
  printf '  %sRun with --gui to install it anyway.%s\n' "$C_DIM" "$C_RESET"
fi
printf '  %sOpen a new shell to pick up PATH and shell changes.%s\n\n' "$C_DIM" "$C_RESET"
