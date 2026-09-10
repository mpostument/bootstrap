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

BOOTSTRAP_VERSION='1.11.0'

# Resolved once, here, so nothing later has to guess where the script lives.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
SKIP_SCHEDULE=no
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
  --skip-schedule    Leave the systemd timer alone.
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
    --skip-schedule) SKIP_SCHEDULE=yes ;;
    --yes|-y)        ASSUME_YES=yes ;;
    --gui)           GUI_OVERRIDE=yes ;;
    --no-gui)        GUI_OVERRIDE=no ;;
    --groups)        shift; ONLY_GROUPS="${1:-}" ;;
    --groups=*)      ONLY_GROUPS="${1#*=}" ;;
    --list-groups)   LIST_GROUPS=yes ;;
    --version)       echo "$BOOTSTRAP_VERSION"; exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown option: $1 (try --help)" ;;
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
#
# The *_ENABLED switches are in this list for a reason worth stating. Every one
# of them is read as "${X_ENABLED:-no}", which means a manifest that never
# mentions X and a manifest that deliberately sets X to no produce the same
# output - "disabled in the manifest" - and one of those two is a bug. That is
# not hypothetical: the Claude Code keys were dropped from this file by a bad
# edit and the run went on reporting the phase as disabled, which is exactly
# what it would have said if the absence had been on purpose.
for required in PKG_GROUPS MANUAL HELD TOOLS REPOS RELEASES ZSH_PLUGINS ZSH_CUSTOM_PLUGINS \
                DOTNET_ENABLED ZSH_ENABLED NERD_FONT_ENABLED CLAUDE_CODE_ENABLED \
                AWSCLI_ENABLED GHOSTTY_ENABLED SCHEDULE_ENABLED HISTORY_SIZE HISTORY_FILE_SIZE; do
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

  # A FLAT repository has no components, and says so by leaving COMPONENTS
  # empty in the manifest. Kubernetes publishes one - the whole archive lives
  # at a single path with `Suites: /` - and emitting `Components:` with nothing
  # after it is not the same as omitting the field: apt rejects the empty value
  # rather than reading it as "none". So the line is left out entirely.
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
# The SAME machine under two naming conventions, and upstream projects are
# split roughly evenly between them: dpkg says amd64 and arm64, uname says
# x86_64 and aarch64. Both are substituted into release URLs, because a
# manifest entry cannot rename what its upstream chose to call the asset, and
# guessing the wrong word produces a confident 404 against a release that
# exists. Not called GOARCH: Go's own GOARCH values are amd64 and arm64, the
# dpkg spelling, so the name would point at the wrong one of these two.
UNAME_ARCH="$(uname -m 2>/dev/null || echo x86_64)"
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

# How many packages apt would actually move, from the local lists - no network,
# and the same solver `apt-get upgrade` is about to run, so the number the dry
# run prints is the number the real run acts on.
apt_pending_count() {
  apt-get --just-print upgrade 2>/dev/null | grep -c '^Inst ' || true
}

# Flatpak has no --just-print, so ask it what it has instead: `active` is the
# commit each installed ref is currently running. Comparing the list before and
# after an update is the same before/after idiom git_clone_or_update uses, it
# costs nothing (the list is local), and it does not depend on matching an
# English string in flatpak's output.
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
# Release binaries
# ============================================================
# Static binaries from a GitHub release into ~/.local/bin, for software that is
# in neither the Debian archive nor a git repository. See packages.conf.
#
# Version-checked properly rather than re-downloaded blindly: the binary is
# asked what it is, the newest release tag is fetched, and a run where they
# already agree transfers nothing and says `current`.

# The tag of the newest release, from the API. One unauthenticated call per
# tool, and only when the tool is actually being considered - the anonymous
# rate limit is 60 an hour and this must not be the thing that spends it.
github_latest_tag() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true
}

# Whatever looks like a version in the binary's own --version output. Every
# tool prints a different sentence around it - "TFLint version 0.53.0",
# "terraform-docs version v0.19.0 ..." - so the number is what gets matched,
# not the wording.
binary_version() {
  local bin="$1" out v a
  # Three spellings, because these tools do not agree on one. helm has no
  # --version at all and wants `version --short`; tflint and terraform-docs
  # only understand --version.
  local -a attempts=('--version' 'version --short' 'version')

  for a in "${attempts[@]}"; do
    # shellcheck disable=SC2086
    out="$("$bin" $a 2>/dev/null || true)"

    # head -1, and NOT `grep -m1`. -m1 stops grep after the first matching
    # LINE, which is not the same as the first match - with -o, every match on
    # that one line still prints. `aws --version` puts the CLI, Python and
    # kernel versions on a single line, so that combination returned three
    # versions and the extra two appeared raw under the result row.
    v="$(printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

    # The test is "did this produce a version", not "did this exit 0". A tool
    # that exits cleanly and prints nothing would otherwise end the search on
    # the first attempt and report no version at all - which install_release
    # reads as "not installed" and acts on by downloading it again, every run.
    if [[ -n "$v" ]]; then
      printf '%s' "$v"
      return 0
    fi
  done
}

# Unpack whatever the release published, chosen by extension. A shape nobody
# listed is an error rather than a guess: silently treating an unknown archive
# as a bare binary is how you end up with a gzip stream marked executable.
unpack_asset() {
  local url="$1" file="$2" binname="$3"
  case "$url" in
    *.zip)    unzip -q "$file" ;;
    *.tar.gz|*.tgz) tar -xzf "$file" ;;
    *.tar.xz) tar -xJf "$file" ;;
    # No extension at all is the common shape for a plain static binary.
    *[!./]) cp "$file" "$binname" ;;
    *)        return 1 ;;
  esac
}

install_release() {
  local name="$1"
  local desc_var="RELEASE_${name}_DESC" repo_var="RELEASE_${name}_REPO"
  local bin_var="RELEASE_${name}_BIN" asset_var="RELEASE_${name}_ASSET"
  local desc="${!desc_var:-$name}" repo="${!repo_var}"
  local binname="${!bin_var}" asset="${!asset_var}"
  local target="${RELEASE_BIN_DIR}/${binname}"

  local have=""
  [[ -x "$target" ]] && have="$(binary_version "$target")"

  if [[ -n "$have" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' "$desc" "$have"
    return
  fi

  local tag want
  tag="$(github_latest_tag "$repo")"
  if [[ -z "$tag" ]]; then
    # No tag means the API did not answer - rate limit, or no network. An
    # installed copy is still fine and is reported as such rather than as a
    # failure; only a missing one is a problem worth a red line.
    if [[ -n "$have" ]]; then
      result 'current' "$desc" "$have (could not reach the GitHub API)"
    else
      result 'failed' "$desc" "could not reach the GitHub API for $repo"
    fi
    return
  fi
  want="${tag#v}"

  if [[ "$have" == "$want" ]]; then
    result 'current' "$desc" "$have"
    return
  fi

  if [[ "$DRY_RUN" == "yes" ]]; then
    if [[ -n "$have" ]]; then
      result 'would-upgrade' "$desc" "$have -> $want"
    else
      result 'would-install' "$desc" "$want into $RELEASE_BIN_DIR"
    fi
    return
  fi

  # {TAG} is the tag as published - v1.31.0 - and {VERSION} is the same thing
  # without the leading v. Both are needed because projects disagree: helm
  # names its asset helm-v3.16.2-linux-amd64.tar.gz and stern names its
  # stern_1.31.0_linux_amd64.tar.gz, from tags that look identical.
  # A GitHub release TAG does not imply GitHub-hosted BINARIES. helm is the
  # case that proved it: its releases carry no attachments at all and the
  # tarballs live on get.helm.sh, so building the usual download URL produced a
  # confident 404 against a tag that existed. An entry may therefore give a
  # whole URL of its own; the tag still comes from the API, because that is the
  # part GitHub is being asked for.
  local url_var="RELEASE_${name}_URL"
  local url="${!url_var:-}"
  [[ -z "$url" ]] && url="https://github.com/${repo}/releases/download/${tag}/${asset}"
  url="${url//\{ARCH\}/$DPKG_ARCH}"
  url="${url//\{UNAME_ARCH\}/$UNAME_ARCH}"
  url="${url//\{TAG\}/$tag}"
  url="${url//\{VERSION\}/$want}"

  local tmp
  tmp="$(mktemp -d)"
  # A subshell with its own trap, so the temp directory goes whether the
  # download works, the archive is corrupt, or the binary is not where the
  # asset was supposed to put it.
  if (
    # Chained with && rather than `set -e`, and that is not a style choice.
    # A subshell inside an `if` condition inherits the suppression that makes
    # `set -e` inert there, so the abort never happens - every step runs
    # regardless and the exit status is whatever the LAST one returned. Written
    # the obvious way, a failed download went on to unpack nothing, find
    # nothing, and then report whatever `install` thought of being handed an
    # empty path. Chaining makes the status mean what it looks like it means.
    cd "$tmp" &&
    # -S keeps curl's reason (404, DNS, TLS) rather than swallowing it, but it
    # goes to a file, not the terminal. One line per decision is the whole
    # point of this output, and a raw `curl: (22) ...` printed above the result
    # row breaks that - so the reason is folded into the result line instead.
    curl -fsSL -o asset "$url" 2>curl.err &&
    unpack_asset "$url" asset "$binname" &&
    # -type f rather than a fixed path: some projects put the binary at the
    # root of the archive and some nest it a directory down.
    found="$(find . -type f -name "$binname" -print -quit)" &&
    [[ -n "$found" ]] &&
    mkdir -p "$RELEASE_BIN_DIR" &&
    install -m 0755 "$found" "$RELEASE_BIN_DIR/$binname"
  ); then
    local now
    now="$(binary_version "$target")"
    if [[ -z "$have" ]]; then
      result 'installed' "$desc" "${now:-$want}"
    elif [[ "$now" == "$have" ]]; then
      # The download worked and the binary is the version it already was. That
      # means the release tag moved without this asset changing, and reporting
      # `upgraded 0.60.0 -> 0.60.0` would be the arrow saying nothing happened
      # while the colour says something did.
      result 'current' "$desc" "$have (release $tag carries the same build)"
    else
      result 'upgraded' "$desc" "$have -> ${now:-$want}"
    fi
  else
    # curl's own words when it has any - "The requested URL returned error:
    # 404" says considerably more than "could not fetch", and it is the
    # difference between a wrong URL and a network that is down.
    local why=""
    [[ -s "$tmp/curl.err" ]] && why="$(tail -1 "$tmp/curl.err" | sed 's/^curl: //')"
    result 'failed' "$desc" "${why:-could not fetch or unpack}: $url"
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

# ============================================================
# AWS CLI v2
# ============================================================
# A zip from AWS containing an installer, because that is the only way v2 is
# published - see packages.conf. Everything lands under $HOME.

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
    # uname -m, not dpkg --print-architecture: AWS names its zips x86_64 and
    # aarch64, where dpkg says amd64 and arm64. Same machine, different words.
    # The same {UNAME_ARCH} that release URLs understand, off one definition
    # near DPKG_ARCH, so the two phases cannot drift on what the word means.
    aws_url="${AWSCLI_URL//\{UNAME_ARCH\}/$UNAME_ARCH}"
    aws_tmp="$(mktemp -d)"
    # --update is required rather than optional: the installer refuses to write
    # over an existing install without it, and omitting it turns every run
    # after the first into a failure.
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

# ============================================================
# Nerd Font
# ============================================================
# powerlevel10k draws its prompt from a Nerd Font's private-use area; without
# one the prompt is boxes. Desktop machines only - the glyphs are rendered by
# the terminal you are typing at, so a font on a headless server changes
# nothing anywhere. See packages.conf.

if [[ "${NERD_FONT_ENABLED:-no}" != "yes" ]]; then
  phase 'Nerd Font - disabled in the manifest'
elif [[ "$HAS_GUI" != "yes" ]]; then
  phase 'Nerd Font'
  result 'no-gui' "font: $NERD_FONT_NAME" 'rendered by the terminal you type at, not this machine'
else
  phase 'Nerd Font'

  # fontconfig first, because it sees system-wide installs and packaged fonts
  # as well as this directory - reinstalling over a font the distribution
  # already provides would be the same bug the Windows side had, where checking
  # only one of two font directories reinstalled Meslo on every single run.
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
    # /releases/latest/download/ redirects to the newest asset, so this costs
    # no API call on a machine that already has the font - which is every run
    # after the first. A font does not need a version check the way a linter
    # does; it is either there or it is not.
    font_url="https://github.com/${NERD_FONT_REPO}/releases/latest/download/${NERD_FONT_NAME}.tar.xz"
    font_tmp="$(mktemp -d)"
    # && rather than `set -e`, for the reason spelled out in install_release:
    # inside an `if` condition, even a subshell's own `set -e` is inert.
    if (
      cd "$font_tmp" &&
      curl -fsSL -o font.tar.xz "$font_url" &&
      tar -xJf font.tar.xz &&
      mkdir -p "$NERD_FONT_DIR" &&
      # The archive carries three widths - LGS, LGL and LGM - in every weight
      # and in base, Mono and Propo variants. Only LGM is installed, and all of
      # its variants: the terminal wants the Mono face (that is what the Windows
      # manifest names as TerminalFontFace) and anything else wants the base
      # one, so taking just the one whose name has no suffix leaves the terminal
      # without the font it was the whole point of installing.
      find . -type f -name "${NERD_FONT_MATCH}*.ttf" -exec cp {} "$NERD_FONT_DIR/" \; &&
      # find succeeds having copied nothing, so the archive being the wrong
      # shape has to be caught here rather than inferred from find's status.
      compgen -G "${NERD_FONT_DIR}/${NERD_FONT_MATCH}*" >/dev/null
    ); then
      # Without this the font is on disk and invisible until the next login:
      # fontconfig caches per-directory and does not rescan on its own.
      command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$NERD_FONT_DIR" >/dev/null 2>&1
      result 'installed' "font: $NERD_FONT_NAME" "$NERD_FONT_DIR"
    else
      result 'failed' "font: $NERD_FONT_NAME" "could not fetch or unpack $font_url"
    fi
    rm -rf "$font_tmp"
  fi
fi

# ============================================================
# Claude Code
# ============================================================
# Anthropic's installer, once, into ~/.local/bin - and then left alone, because
# Claude Code updates itself. Reinstalling it on every run would be the second
# installer in a fight it cannot win, which is the same call this script makes
# about anything owned by another updater.

if [[ "${CLAUDE_CODE_ENABLED:-no}" != "yes" ]]; then
  phase 'Claude Code - disabled in the manifest'
else
  phase 'Claude Code'
  # Both the binary the installer writes and anything already on PATH: a copy
  # installed some other way is still a copy that updates itself, and
  # installing over it is exactly what this section exists not to do.
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
    claude_script="$(mktemp)"
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

    # Completion directory permissions. zsh treats a group- or world-writable
    # directory on fpath as untrusted, and oh-my-zsh turns that into a refusal:
    # it prints "Insecure completion-dependent directories detected" and then
    # loads NO completions at all - not merely the ones from the offending
    # directory. So a machine can end up with fewer completions after
    # installing zsh-completions than it had before.
    #
    # The trigger here is not the same as on macOS, where it is Homebrew
    # creating <prefix>/share group-writable. These are clones in $HOME, so the
    # cause is the umask that made them: on a system with USERGROUPS_ENAB and a
    # 002 umask - the Debian default for a user whose group is their own name -
    # every directory git creates is group-writable, and oh-my-zsh audits the
    # lot. Nothing is wrong with that umask; zsh is simply stricter than it.
    #
    # Fixed rather than reported, because these are directories this script
    # cloned. Only what is on fpath is touched, not $HOME at large.
    COMPFIX_DIRS=("$OMZ_DIR" "$OMZ_CUSTOM" "${OMZ_CUSTOM}/plugins" "${OMZ_CUSTOM}/themes")
    for entry in "${ZSH_CUSTOM_PLUGINS[@]:-}"; do
      [[ -z "$entry" ]] && continue
      COMPFIX_DIRS+=("${OMZ_CUSTOM}/plugins/${entry%%|*}")
      # zsh-completions puts its functions in a src/ subdirectory and adds THAT
      # to fpath, so the parent being clean is not enough.
      [[ -d "${OMZ_CUSTOM}/plugins/${entry%%|*}/src" ]] && \
        COMPFIX_DIRS+=("${OMZ_CUSTOM}/plugins/${entry%%|*}/src")
    done

    INSECURE_DIRS=()
    for d in "${COMPFIX_DIRS[@]}"; do
      [[ -d "$d" ]] || continue
      # stat -c is the GNU spelling; %A gives the symbolic mode, so the group
      # write bit is character 6 and the other write bit is character 9. The
      # macOS script uses `stat -f '%Sp'` for the same thing.
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

    # The managed fragment, not the whole .zshrc. Anything else in that file is
    # somebody's own work; this writes one clearly-marked block and leaves the
    # rest alone, the same rule the Windows profile follows.
    ZSHRC="${HOME}/.zshrc"
    FRAGMENT="${HOME}/.zshrc.bootstrap"
    if [[ "$DRY_RUN" == "yes" ]]; then
      result 'would-install' 'zsh config' "$FRAGMENT"
    else
      # Rendered to a temp file first so the fragment can be compared with what
      # is already on disk. Writing it unconditionally worked, but it reported
      # `installed` on every run of an otherwise idempotent script, which makes
      # the summary useless for spotting the run where something really changed.
      # Beside the target, not in /tmp: same filesystem, so the replace below is
      # an atomic rename rather than a copy that can be seen half-written, and
      # the mode is set here rather than inherited from mktemp's 0600.
      NEW_FRAGMENT="$(mktemp "${FRAGMENT}.XXXXXX")"
      chmod 0644 "$NEW_FRAGMENT"
      {
        echo "# managed by linux/bootstrap.sh - edit the manifest, not this file"
        echo
        echo '# The powerlevel10k instant prompt, and it is FIRST for a reason: it'
        echo '# replays a cached prompt before the rest of this file runs, so the'
        echo '# terminal is usable immediately instead of after every eval below.'
        echo '# Anything that writes to the console above it corrupts the replay.'
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
        echo '# The prompt configuration itself, which is NOT part of the clone.'
        echo '# powerlevel10k without it runs its configuration wizard on every new'
        echo '# shell until you answer it, and answering writes ~/.p10k.zsh - which'
        echo '# then has to be sourced or the answers do nothing. This file is'
        echo '# yours, not managed here; ZSH_THEME above is what loads the theme.'
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
        echo '# history-substring-search comes from the plugin oh-my-zsh bundles,'
        echo '# which does bind keys - but only the terminfo sequences, and only'
        echo '# when terminfo has them. A terminal outside application cursor mode'
        echo '# sends the raw escape instead and reaches nothing. Binding both'
        echo '# spellings costs nothing and removes the "it works on my machine,'
        echo '# over SSH" class of report. Guarded on the widget, so this is inert'
        echo '# if the plugin ever leaves the list.'
        echo 'if (( $+widgets[history-substring-search-up] )); then'
        echo "  bindkey '^[[A' history-substring-search-up"
        echo "  bindkey '^[[B' history-substring-search-down"
        echo "  bindkey -M vicmd 'k' history-substring-search-up"
        echo "  bindkey -M vicmd 'j' history-substring-search-down"
        echo 'fi'
        echo
        echo '# Completion styling, and the fzf-tab settings without which fzf-tab'
        echo '# is inert. `menu no` is the load-bearing one: zsh menu selection and'
        echo '# fzf-tab both want to own the completion UI, and if zsh has it,'
        echo '# fzf-tab is cloned, sourced, working, and never invoked. It is named'
        echo '# first in plugins= above and that is still not enough.'
        echo 'zstyle '"'"':completion:*'"'"' list-colors "${(s.:.)LS_COLORS}"'
        echo "bindkey -M menuselect '^[[Z' reverse-menu-complete"
        echo 'if command -v fzf >/dev/null; then'
        echo "  zstyle ':completion:*' menu no"
        echo "  zstyle ':completion:*:*:*:*:*' menu no"
        echo "  zstyle ':fzf-tab:*' fzf-flags --height=60% --layout=reverse --border --cycle"
        echo "  zstyle ':fzf-tab:*' switch-group ',' '.'"
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
        echo '# Aliases guard on command -v: these binaries are renamed on Debian'
        echo '# (fd-find -> fdfind, bat -> batcat) and absent on some releases, and a'
        echo '# blind alias to a missing binary breaks the normal command entirely.'
        echo '#'
        echo '# Two of the flags are about behaving like the command being'
        echo '# replaced rather than like the replacement. bat pages by default'
        echo '# and cat does not, so --paging=never; `eza --icons` emits icons'
        echo '# even into a pipe, where they become mojibake in whatever reads'
        echo '# them, so --icons=auto ties them to stdout being a terminal.'
        echo '#'
        echo '# Each pair is ordered Debian-name first, real-name second, so on a'
        echo '# release that has both the unrenamed one wins.'
        echo 'command -v batcat >/dev/null && alias cat="batcat --paging=never"'
        echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
        echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
        echo '#'
        echo '# find comes BEFORE the fd alias on purpose. `alias fd="fdfind"`'
        echo '# makes `command -v fd` succeed on a box that has no fd binary at'
        echo '# all, so testing for it afterwards tests the alias and not the'
        echo '# tool. It would still work - zsh expands an alias to an alias -'
        echo '# but it would work by accident.'
        echo 'command -v fdfind >/dev/null && alias find="fdfind"'
        echo 'command -v fd     >/dev/null && alias find="fd"'
        echo 'command -v fdfind >/dev/null && alias fd="fdfind"'
        echo 'command -v rg     >/dev/null && alias grep="rg"'
        echo 'command -v zoxide >/dev/null && eval "$(zoxide init zsh)"'
        echo 'command -v direnv >/dev/null && eval "$(direnv hook zsh)"'
        echo
        echo '# Where the release binaries land. The stock ~/.profile on Debian'
        echo '# adds this when it exists, but zsh never reads .profile - so without'
        echo '# this line tflint and terraform-docs install and are not on PATH.'
        echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
        echo
        echo '# Version managers, ahead of anything the platform ships, so a'
        echo '# project pin wins over the machine default whenever there is one.'
        echo '[ -d "$HOME/.pyenv/bin" ] && export PATH="$HOME/.pyenv/bin:$PATH"'
        echo 'command -v pyenv >/dev/null && eval "$(pyenv init -)"'
        echo '[ -d "$HOME/.tofuenv/bin" ] && export PATH="$HOME/.tofuenv/bin:$PATH"'
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

      # Sourced from .zshrc rather than written into it, so re-running this
      # never has to parse or rewrite a file the user owns.
      SOURCE_LINE='[ -f "$HOME/.zshrc.bootstrap" ] && source "$HOME/.zshrc.bootstrap"'
      if [[ -f "$ZSHRC" ]] && grep -qF '.zshrc.bootstrap' "$ZSHRC"; then
        result 'current' 'zshrc hook' "$ZSHRC"
      else
        printf '\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
        result 'installed' 'zshrc hook' "appended to $ZSHRC"
      fi

      # Appending is safe but not always right, and the difference is visible
      # rather than silent, so it is reported instead of guessed at. The
      # fragment now opens with the powerlevel10k instant prompt, which only
      # does anything if it runs before the rest of the file - so a hook sitting
      # under 80 lines of somebody's own config is a working shell with a
      # feature quietly switched off. Rewriting a file the user owns to fix that
      # is not this script's call to make; saying so is.
      #
      # Matched on a line that actually SOURCES the fragment, not on any mention
      # of it. A comment naming the file is not the hook, and counting from it
      # measures nothing.
      if [[ -f "$ZSHRC" ]]; then
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
      echo "# table (spaces), not the ttf filename. Blank leaves ghostty's default."
      [[ -n "${GHOSTTY_FONT_FAMILY:-}" ]] && echo "font-family = ${GHOSTTY_FONT_FAMILY}"
      echo "font-size = ${GHOSTTY_FONT_SIZE}"
      echo
      echo "# Select-to-copy. Ctrl-Shift-C still works and is unaffected; this is"
      echo "# the extra convenience, at the cost of a stray selection replacing"
      echo "# whatever was on the clipboard."
      echo "copy-on-select = ${GHOSTTY_COPY_ON_SELECT}"
      echo
      echo "# Ghostty auto-installs the shell hooks; this opts INTO the extras."
      echo "# \`cursor\` follows zsh vi-mode, \`sudo\` preserves prompt state through"
      echo "# sudo, \`title\` tracks cwd in the terminal title."
      echo "shell-integration-features = ${GHOSTTY_SHELL_INTEGRATION_FEATURES}"
      echo
      echo "# Quake-style drop-down terminal on Ctrl-\`, global so it fires from any"
      echo "# app. Wayland compositors need the GlobalShortcuts portal for this to"
      echo "# reach ghostty. Blank in the manifest disables it."
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
# Schedule
# ============================================================
# Same job as the Windows manifest's Schedule phase: a daily unattended run,
# so this machine takes updates without anyone remembering to ask for them.
# Every phase above reports `current` when it changes nothing, so a daily run
# costs almost nothing and its log is only worth reading on the days it is
# not all `current`.
#
# A systemd unit rather than cron, for the one thing cron cannot do: catch up
# a run the machine slept through. Persistent=true below is systemd's
# equivalent of Task Scheduler's StartWhenAvailable - the trigger this machine
# missed at 04:20 asleep still fires the moment it wakes, instead of silently
# waiting for tomorrow.
#
# Logging is deliberately NOT reinvented here the way the Windows phase has
# to reinvent it. Task Scheduler captures nothing on its own, so that phase
# pipes output through Tee-Object into hand-rolled dated files and prunes them
# itself. A systemd service's stdout/stderr goes to the journal by default,
# with its own retention already configured on every one of these machines -
# `journalctl -u bootstrap-linux` is the log, and there is no file for this
# script to create or prune.

phase 'Schedule'

if [[ "$SKIP_SCHEDULE" == "yes" ]]; then
  result 'skipped' 'schedule' '--skip-schedule'
elif [[ "${SCHEDULE_ENABLED:-no}" != "yes" ]]; then
  result 'skipped' 'schedule' 'disabled in the manifest'
elif [[ ! -d /run/systemd/system ]]; then
  # The test the systemd docs recommend for "is this machine's PID 1 actually
  # systemd": a running service manager creates this directory itself, so its
  # absence means something else is init. WSL is the real case - this script
  # otherwise runs fine there, but plenty of installs never turn systemd on.
  result 'skipped' 'schedule' 'systemd is not running as init (e.g. WSL without systemd enabled)'
else
  SERVICE_UNIT="/etc/systemd/system/${SCHEDULE_UNIT_NAME}.service"
  TIMER_UNIT="/etc/systemd/system/${SCHEDULE_UNIT_NAME}.timer"

  NEW_SERVICE="$(mktemp)"
  {
    echo '# managed by linux/bootstrap.sh - edit the manifest, not this file'
    echo '[Unit]'
    echo "Description=Runs $SCRIPT_DIR/bootstrap.sh unattended, taking package and script updates"
    echo
    echo '[Service]'
    echo 'Type=oneshot'
    echo "WorkingDirectory=$SCRIPT_DIR"
    echo "ExecStart=$SCRIPT_DIR/bootstrap.sh --yes"
  } > "$NEW_SERVICE"

  NEW_TIMER="$(mktemp)"
  {
    echo '# managed by linux/bootstrap.sh - edit the manifest, not this file'
    echo '[Unit]'
    echo "Description=Daily trigger for ${SCHEDULE_UNIT_NAME}.service"
    echo
    echo '[Timer]'
    echo "OnCalendar=*-*-* ${SCHEDULE_TIME}:00"
    # Catches up a run the machine was asleep for, same reasoning as above.
    echo 'Persistent=true'
    # Nothing here to stagger across a fleet - this is one machine - but it
    # costs nothing and means a reboot at exactly 04:20 does not race apt.
    echo 'RandomizedDelaySec=5m'
    echo
    echo '[Install]'
    echo 'WantedBy=timers.target'
  } > "$NEW_TIMER"

  # Unlike the Windows Task Scheduler object - which carries registration
  # timestamps that never compare equal, forcing that phase to hand-pick which
  # fields actually matter - a unit file has no such incidental metadata. A
  # plain byte comparison against what's on disk already answers "did anything
  # that matters change".
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
