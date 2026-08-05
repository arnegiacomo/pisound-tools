#!/usr/bin/env bash
# Installs the USB audio gadget and the JACK bridge on a Patchbox OS Pi:
#   curl -fsSL https://raw.githubusercontent.com/arnegiacomo/pisound-tools/main/usb-audio-bridge/install.sh | bash
# The boot-config half only takes effect on reboot; everything else is safe to
# re-run against a live system. Idempotent. Pass options with `bash -s -- -y`.
set -euo pipefail

REF="${PISOUND_TOOLS_REF:-main}"
RAW="https://raw.githubusercontent.com/arnegiacomo/pisound-tools/$REF/usb-audio-bridge"
FILES=(usb-audio-gadget.sh usb-audio-gadget.service usb-audio-bridge.service)
ASSUME_YES=0
NEEDS_REBOOT=0
USE_ZITA=0
SRC=""

have() { command -v "$1" >/dev/null 2>&1; }
need() { echo "cannot continue without $1" >&2; exit 1; }

# curl|bash leaves stdin on the script itself, so prompts must read the terminal.
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
  sudo -v
}

# Run from a checkout if there is one, otherwise pull the files down.
resolve_source() {
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)" || here=""
  if [[ -n "$here" && -f "$here/${FILES[0]}" ]]; then
    SRC="$here"
    return 0
  fi
  have curl || need curl
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT
  local f
  for f in "${FILES[@]}"; do
    curl -fsSL "$RAW/$f" -o "$SRC/$f" || need "$f (download from $RAW failed)"
  done
}

require_patchbox() {
  id jack >/dev/null 2>&1 ||
    echo "   warning: no 'jack' user - the bridge unit expects Patchbox's jack.service"
  have jack_connect || need "jack_connect (is this Patchbox OS?)"
  systemctl is-active avahi-daemon >/dev/null 2>&1 ||
    echo "   warning: avahi-daemon is not running - patchbox.local will not resolve over the cable"
}

# alsa_in ships with jackd2; zita-a2j is the fallback when it clicks.
ensure_bridge_tool() {
  if [[ $USE_ZITA == 1 ]] || ! have alsa_in; then
    have zita-a2j && { USE_ZITA=1; echo "   using zita-a2j"; return 0; }
    [[ $USE_ZITA == 1 ]] || echo "missing: alsa_in (normally part of jackd2)"
    confirm "install zita-ajbridge?" || need "alsa_in or zita-a2j"
    sudo apt-get update
    sudo apt-get install -y zita-ajbridge
    USE_ZITA=1
    return 0
  fi
  echo "   using alsa_in"
}

# Peripheral mode is the only reason this needs a reboot.
ensure_peripheral_mode() {
  local cfg=/boot/firmware/config.txt cmdline=/boot/firmware/cmdline.txt
  [[ -f "$cfg" ]] || { cfg=/boot/config.txt; cmdline=/boot/cmdline.txt; }
  [[ -f "$cfg" && -f "$cmdline" ]] || need "config.txt and cmdline.txt"

  # otg_mode=1 forces the host-capable controller, leaving /sys/class/udc empty.
  if grep -qE '^[[:space:]]*otg_mode=1' "$cfg"; then
    sudo sed -i -E 's/^([[:space:]]*otg_mode=1)/#\1/' "$cfg"
    echo "   commented out otg_mode=1 in $cfg"
    NEEDS_REBOOT=1
  fi

  if ! grep -qxF 'dtoverlay=dwc2,dr_mode=peripheral' "$cfg"; then
    echo 'dtoverlay=dwc2,dr_mode=peripheral' | sudo tee -a "$cfg" >/dev/null
    echo "   dtoverlay=dwc2,dr_mode=peripheral added to $cfg"
    NEEDS_REBOOT=1
  fi

  # cmdline.txt is a single line, and a second modules-load= would shadow the
  # first, so extend the existing one when there is one.
  if grep -qE 'modules-load=([^[:space:]]*,)?dwc2(,[^[:space:]]*)?([[:space:]]|$)' "$cmdline"; then
    :
  elif grep -q 'modules-load=' "$cmdline"; then
    sudo sed -i -E 's/(modules-load=[^[:space:]]*)/\1,dwc2/' "$cmdline"
    echo "   dwc2 added to modules-load in $cmdline"
    NEEDS_REBOOT=1
  else
    sudo sed -i '1 s|$| modules-load=dwc2|' "$cmdline"
    echo "   modules-load=dwc2 added to $cmdline"
    NEEDS_REBOOT=1
  fi
}

install_units() {
  sudo install -m 755 "$SRC/usb-audio-gadget.sh" /usr/local/bin/usb-audio-gadget
  sudo install -m 644 "$SRC/usb-audio-gadget.service" /etc/systemd/system/usb-audio-gadget.service
  sudo install -m 644 "$SRC/usb-audio-bridge.service" /etc/systemd/system/usb-audio-bridge.service

  if [[ $USE_ZITA == 1 ]]; then
    sudo sed -i -E \
      -e 's|^ExecStart=/usr/bin/alsa_in|#&|' \
      -e 's|^#(ExecStart=/usr/bin/zita-a2j)|\1|' \
      /etc/systemd/system/usb-audio-bridge.service
  fi

  sudo systemctl daemon-reload
  sudo systemctl enable usb-audio-gadget.service usb-audio-bridge.service
}

finish() {
  if [[ $NEEDS_REBOOT == 1 ]]; then
    echo "==> installed, reboot needed before the USB controller comes up in peripheral mode."
    confirm "reboot now?" && sudo reboot
    echo "    Run 'sudo reboot' when you are ready."
    return 0
  fi
  # --no-block: re-binding the gadget drops the USB link this may be running
  # over, and the bridge can legitimately sit in its start-up waits for a while.
  echo "==> restarting (the USB device will drop and come back)"
  sudo systemctl restart --no-block usb-audio-gadget.service usb-audio-bridge.service
  echo "    Select 'Pisound USB Audio' as the output on the connected computer."
  echo "    Web UI over the same cable: http://patchbox.local"
  echo "    Check: usb-audio-gadget status; journalctl -u usb-audio-bridge -f"
}

main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y|--yes) ASSUME_YES=1 ;;
      --zita)   USE_ZITA=1 ;;
      *) echo "unknown argument: $arg (accepts -y/--yes, --zita)" >&2; exit 1 ;;
    esac
  done

  require_pi
  resolve_source

  echo "==> checks"
  require_patchbox
  ensure_bridge_tool

  echo "==> boot config"
  ensure_peripheral_mode

  echo "==> units"
  install_units

  finish
}

# Called last so a truncated download cannot execute half a script.
main "$@"
