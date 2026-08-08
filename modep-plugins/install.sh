#!/usr/bin/env bash
# Installs LV2 plugins from apt and links them where MODEP can see them:
#   curl -fsSL https://raw.githubusercontent.com/arnegiacomo/pisound-tools/main/modep-plugins/install.sh | bash
# MODEP only scans /var/modep/lv2, so everything Debian ships to /usr/lib/lv2 is
# invisible to it until it is linked across. Idempotent. `--remove` undoes it.
set -euo pipefail

MODEP_LV2=/var/modep/lv2
ASSUME_YES=0
LINKED=0
SKIPPED=0

# Anything apt does not have is skipped rather than aborting the run - the set
# available varies between Raspberry Pi OS releases.
PACKAGES=(
  calf-plugins
  guitarix-lv2
  zam-plugins
  x42-plugins
  invada-studio-plugins-lv2
  rkrlv2
  mda-lv2
  swh-lv2
  lsp-plugins-lv2
  dpf-plugins
)

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  if ! (exec </dev/tty) 2>/dev/null; then
    echo "   no terminal to ask '$1' - assuming no (re-run with -y to auto-accept)"
    return 1
  fi
  local ans=""
  read -rp "$1 [y/N] " ans </dev/tty || return 1
  [[ "$ans" == [yY] || "$ans" == [yY][eE][sS] ]]
}

require_pi() {
  [[ "$(uname -s)" == "Linux" ]] || { echo "this installs onto the Pi (Linux)." >&2; exit 1; }
  [[ $EUID -ne 0 ]] || { echo "run as your normal user, not root - it sudos where it needs to." >&2; exit 1; }
  [[ -d "$MODEP_LV2" ]] || { echo "$MODEP_LV2 does not exist - is MODEP installed?" >&2; exit 1; }
  sudo -v
}

install_packages() {
  sudo apt-get update
  local pkg
  for pkg in "${PACKAGES[@]}"; do
    if sudo apt-get install -y "$pkg" >/dev/null 2>&1; then
      echo "   $pkg"
    else
      echo "   $pkg - not available, skipped"
    fi
  done
}

lv2_dirs() {
  local d
  for d in /usr/lib/lv2 /usr/local/lib/lv2 /usr/lib/*/lv2; do
    [[ -d "$d" ]] && echo "$d"
  done
}

# Only ever replaces symlinks we own. A real directory in $MODEP_LV2 is a plugin
# MODEP installed itself and is left alone.
link_plugins() {
  local dir bundle name target
  while read -r dir; do
    for bundle in "$dir"/*.lv2; do
      [[ -d "$bundle" ]] || continue
      name=$(basename "$bundle")
      target="$MODEP_LV2/$name"
      if [[ -e "$target" && ! -L "$target" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      sudo ln -sfn "$bundle" "$target"
      LINKED=$((LINKED + 1))
    done
  done < <(lv2_dirs)
  sudo chown -h -R modep:modep "$MODEP_LV2" 2>/dev/null || true
}

remove_links() {
  local target removed=0
  for target in "$MODEP_LV2"/*.lv2; do
    [[ -L "$target" ]] || continue
    sudo rm -f "$target"
    removed=$((removed + 1))
  done
  echo "==> removed $removed symlinks (packages left installed, apt removes those)"
}

restart_modep() {
  sudo systemctl restart modep-mod-host modep-mod-ui
}

main() {
  local arg do_remove=0
  for arg in "$@"; do
    case "$arg" in
      -y|--yes)  ASSUME_YES=1 ;;
      --remove)  do_remove=1 ;;
      *) echo "unknown argument: $arg (accepts -y/--yes, --remove)" >&2; exit 1 ;;
    esac
  done

  require_pi

  if [[ $do_remove == 1 ]]; then
    remove_links
    restart_modep
    return 0
  fi

  echo "==> apt packages"
  install_packages

  echo "==> linking into $MODEP_LV2"
  link_plugins
  echo "   $LINKED linked, $SKIPPED left alone (already real directories)"

  echo "==> restarting MODEP"
  restart_modep
  echo "==> done. Reload the MOD-UI page; the new plugins are in the sidebar."
}

# Called last so a truncated download cannot execute half a script.
main "$@"
