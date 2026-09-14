#!/usr/bin/env bash

set -euo pipefail

BOOTSTRAP_VERSION='1.27.1'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/packages.conf"

DRY_RUN=no
SKIP_UPGRADE=no
SKIP_SCHEDULE=no
SKIP_REPOS=no
ASSUME_YES=no
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
  --skip-upgrade     Install what is missing, leave installed versions alone.
  --skip-schedule    Leave the systemd timer alone.
  --skip-repos       Add no third-party apt sources and install none of
                     their packages. For a host where something else
                     already owns those repositories.
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
    --skip-repos)    SKIP_REPOS=yes ;;
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

# Manifest

[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
# shellcheck source=packages.conf
source "$MANIFEST"

for required in PKG_GROUPS MANUAL HELD TOOLS REPOS RELEASES ZSH_PLUGINS ZSH_CUSTOM_PLUGINS \
                DOTNET_ENABLED ZSH_ENABLED NERD_FONT_ENABLED CLAUDE_CODE_ENABLED \
                MISE_ENABLED \
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
  echo
  exit 0
fi

# Preflight

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
  keytmp="$(mktemp)"
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

# Release binaries

github_latest_tag() {   # github_latest_tag <owner/repo> [tag prefix]
  if [[ -z "${2:-}" ]]; then
    curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
      | grep -m1 '"tag_name"' \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true
    return
  fi
  # A repository that releases several products has one "latest" for all of
  # them - bitwarden/clients: web, desktop, browser, cli. Take the newest tag
  # that is the prefix and a bare version, which also skips -rc tags.
  curl -fsSL "https://api.github.com/repos/$1/releases?per_page=50" 2>/dev/null \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | grep -m1 -E "^${2}[0-9]+(\.[0-9]+)*\$" || true
}

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
  local desc_var="RELEASE_${name}_DESC" repo_var="RELEASE_${name}_REPO"
  local bin_var="RELEASE_${name}_BIN" asset_var="RELEASE_${name}_ASSET"
  local desc="${!desc_var:-$name}" repo="${!repo_var}"
  local binname="${!bin_var}" asset="${!asset_var}"
  local bins_var="RELEASE_${name}_BINS"
  local bins="${!bins_var:-$binname}"
  local verargs_var="RELEASE_${name}_VERSION_ARGS"
  local verargs="${!verargs_var:-}"
  local target="${RELEASE_BIN_DIR}/${binname}"

  local have=""
  [[ -x "$target" ]] && have="$(binary_version "$target" "$verargs")"

  if [[ -n "$have" && "$SKIP_UPGRADE" == "yes" ]]; then
    result 'skipped' "$desc" "$have"
    return
  fi

  local tag want
  local prefix_var="RELEASE_${name}_TAG_PREFIX"
  tag="$(github_latest_tag "$repo" "${!prefix_var:-}")"
  if [[ -z "$tag" ]]; then
    if [[ -n "$have" ]]; then
      result 'current' "$desc" "$have (could not reach the GitHub API)"
    else
      result 'failed' "$desc" "could not reach the GitHub API for $repo"
    fi
    return
  fi
  # Most tags are v1.2.3 or 1.2.3; a few carry the project name (jq-1.8.2,
  # gping-v1.21.0), and the binary reports only the number.
  want="${tag#v}"
  [[ "$want" =~ ^[0-9] ]] || want="$(printf '%s' "$tag" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)"

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
  tmp="$(mktemp -d)"
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
      result 'installed' "$desc" "${now:-$want}"
    elif [[ "$now" == "$have" ]]; then
      result 'current' "$desc" "$have (release $tag carries the same build)"
    else
      result 'upgraded' "$desc" "$have -> ${now:-$want}"
    fi
  else
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
    ghostty_url="$(curl -fsSL "https://api.github.com/repos/${GHOSTTY_DEB_REPO}/releases/latest" 2>/dev/null \
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
      ghostty_tmp="$(mktemp -d)"
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
    aws_tmp="$(mktemp -d)"
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
    font_tmp="$(mktemp -d)"
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
    mise_script="$(mktemp)"
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

# zsh

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
      if RUNZSH=no CHSH=no sh -c \
          "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
          "" --unattended >/dev/null 2>&1; then
        result 'installed' 'oh-my-zsh' "$OMZ_DIR"
      else
        result 'failed' 'oh-my-zsh' 'installer failed'
      fi
    fi

    if [[ -d "$OMZ_DIR" || "$DRY_RUN" == "yes" ]]; then
      for entry in "${ZSH_CUSTOM_PLUGINS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        git_clone_or_update "plugin: ${entry%%|*}" "${OMZ_CUSTOM}/plugins/${entry%%|*}" "${entry#*|}"
      done
    fi

    COMPFIX_DIRS=("$OMZ_DIR" "$OMZ_CUSTOM" "${OMZ_CUSTOM}/plugins" "${OMZ_CUSTOM}/themes")
    for entry in "${ZSH_CUSTOM_PLUGINS[@]:-}"; do
      [[ -z "$entry" ]] && continue
      COMPFIX_DIRS+=("${OMZ_CUSTOM}/plugins/${entry%%|*}")
      [[ -d "${OMZ_CUSTOM}/plugins/${entry%%|*}/src" ]] && \
        COMPFIX_DIRS+=("${OMZ_CUSTOM}/plugins/${entry%%|*}/src")
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
    else
      NEW_FRAGMENT="$(mktemp "${FRAGMENT}.XXXXXX")"
      chmod 0644 "$NEW_FRAGMENT"
      {
        echo
        echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
        echo
        echo "export ZSH=\"$OMZ_DIR\""
        echo "ZSH_THEME=\"$ZSH_THEME\""
        echo
        printf 'plugins=(%s)\n' "${ZSH_PLUGINS[*]}"
        echo 'source "$ZSH/oh-my-zsh.sh"'
        echo
        echo 'eval "$(starship init zsh)"'
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
        echo 'if (( $+widgets[history-substring-search-up] )); then'
        echo "  bindkey '^[[A' history-substring-search-up"
        echo "  bindkey '^[[B' history-substring-search-down"
        echo "  bindkey -M vicmd 'k' history-substring-search-up"
        echo "  bindkey -M vicmd 'j' history-substring-search-down"
        echo 'fi'
        echo
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
        echo 'command -v batcat >/dev/null && alias cat="batcat --paging=never"'
        echo 'command -v bat    >/dev/null && alias cat="bat --paging=never"'
        echo 'command -v eza    >/dev/null && alias ls="eza --icons=auto --group-directories-first"'
        echo 'command -v fdfind >/dev/null && alias find="fdfind"'
        echo 'command -v fd     >/dev/null && alias find="fd"'
        # Only where no real fd exists: an apt fd-find left from before the
        # release binary would otherwise shadow it.
        echo 'command -v fd >/dev/null || { command -v fdfind >/dev/null && alias fd="fdfind"; }'
        echo 'command -v rg     >/dev/null && alias grep="rg"'
        echo 'command -v dust   >/dev/null && alias du="dust"'
        echo 'command -v duf    >/dev/null && alias df="duf"'
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
        echo 'tools() {'
        echo '  echo'
        declare -n _apt="GROUP_cli_APT"
        declare -n _flat="GROUP_cli_FLATPAK"
        for pkg in "${_apt[@]:-}" "${_flat[@]:-}" "${_cli_rel[@]:-}"; do
          [[ -z "$pkg" ]] && continue
          if [[ -n "${_cli_cmd[$pkg]:-}" ]]; then
            printf "  echo '  %-12s  %-10s  %s'\n" "$pkg" "${_cli_cmd[$pkg]}" "${_cli_desc[$pkg]}"
          else
            printf "  echo '  %s'\n" "$pkg"
          fi
        done
        unset -n _apt _flat
        echo '  echo'
        echo '}'
        echo
        echo '[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"'
        echo 'command -v mise >/dev/null && eval "$(mise activate zsh)"'
        # mise has no carapace completer; its own script is small and asks mise itself.
        echo 'command -v mise >/dev/null && eval "$(mise completion zsh)"'
        echo
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

# Git config
# Set only when unset: an existing value is somebody's choice, not drift.
phase 'Git config'
if ! command -v git >/dev/null 2>&1; then
  result 'missing' 'git config' 'git is not installed'
else
  GIT_WANT=()
  # delta is the pager for diff, show, log and add -p; `git sdiff` is the same
  # view side by side.
  if command -v delta >/dev/null 2>&1; then
    GIT_WANT+=(
      'core.pager=delta'
      'interactive.diffFilter=delta --color-only'
      "alias.sdiff=-c core.pager='delta --side-by-side' diff"
    )
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

  NEW_SERVICE="$(mktemp)"
  {
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
  printf '  %sNo desktop detected, so desktop software was skipped.%s\n' "$C_DIM" "$C_RESET"
  printf '  %sRun with --gui to install it anyway.%s\n' "$C_DIM" "$C_RESET"
fi
printf '  %sOpen a new shell to pick up PATH and shell changes.%s\n\n' "$C_DIM" "$C_RESET"
