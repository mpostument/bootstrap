#!/usr/bin/env bash
# verify-repos.sh - every REPOS entry resolves on every release and architecture
#
# For each repository, as setup_repo would write it for Debian bookworm and
# trixie and Ubuntu 24.04, on amd64 and arm64: the suite's index exists, and
# carries every package the manifest installs from it. packages.microsoft.com
# had no azure-cli suite for trixie, and nothing noticed until apt-get update
# failed on a machine.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
. "${ROOT}/linux/packages.conf"

TARGETS=("debian bookworm" "debian trixie" "ubuntu noble")
ARCHES=(amd64 arm64)

# Package stanzas of an index, whichever compression the vendor serves.
fetch_index() {
  local base="$1"
  curl -fsSL "$base" 2>/dev/null && return
  curl -fsSL "$base.gz" 2>/dev/null | gunzip 2>/dev/null && return
  curl -fsSL "$base.xz" 2>/dev/null | xz -d 2>/dev/null
}

# Is package $2 in index $1 for architecture $3 (or arch all)?
has_package() {
  awk -v p="$2" -v a="$3" '
    /^Package: /      { pkg = $2 }
    /^Architecture: / { if (pkg == p && ($2 == a || $2 == "all")) found = 1 }
    END               { exit !found }' <<< "$1"
}

failed=0
for name in "${REPOS[@]}"; do
  uri_var="REPO_${name}_URI"; suites_var="REPO_${name}_SUITES"; comp_var="REPO_${name}_COMPONENTS"
  declare -n _pkgs="REPO_${name}_PACKAGES"
  declare -n _cmap="REPO_${name}_CODENAME_MAP"

  for target in "${TARGETS[@]}"; do
    id="${target% *}"; os_codename="${target#* }"; codename="$os_codename"
    for entry in ${_cmap[@]+"${_cmap[@]}"}; do
      [[ "${entry%%:*}" == "$os_codename" ]] && codename="${entry#*:}"
    done
    uri="${!uri_var}"; uri="${uri%/}"
    uri="${uri//\{ID\}/$id}"; uri="${uri//\{CODENAME\}/$codename}"
    suite="${!suites_var}"; suite="${suite//\{ID\}/$id}"; suite="${suite//\{CODENAME\}/$codename}"

    flat_index=""
    [[ "$suite" == "/" ]] && flat_index="$(fetch_index "$uri/Packages")"

    for arch in "${ARCHES[@]}"; do
      if [[ "$suite" == "/" ]]; then
        url="$uri/Packages"; index="$flat_index"
      else
        url="$uri/dists/$suite/${!comp_var}/binary-$arch/Packages"
        index="$(fetch_index "$url")"
      fi
      if [[ -z "$index" ]]; then
        echo "::error file=linux/packages.conf::$name: no index for $target $arch at $url - does the vendor publish this release? See REPO_<name>_CODENAME_MAP"
        failed=1
        continue
      fi
      missing=()
      for pkg in "${_pkgs[@]}"; do
        has_package "$index" "$pkg" "$arch" || missing+=("$pkg")
      done
      if (( ${#missing[@]} )); then
        echo "::error file=linux/packages.conf::$name: $target $arch has no ${missing[*]}"
        failed=1
      else
        printf 'OK   %-10s %-15s %-5s suite %s\n' "$name" "$target" "$arch" "$suite"
      fi
    done
  done
  unset -n _pkgs _cmap
done
exit "$failed"
