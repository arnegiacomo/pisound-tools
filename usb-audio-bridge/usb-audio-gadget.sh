#!/usr/bin/env bash
# Builds a composite USB gadget: a UAC2 audio device, plus an ECM network
# interface so the same cable carries SSH and the web UI. configfs is
# in-memory, so this has to run on every boot.
#   usb-audio-gadget [start|stop|status]
set -euo pipefail

GADGET=/sys/kernel/config/usb_gadget/pisound
UAC2=uac2.usb0
ECM=ecm.usb0
CONF=configs/c.1
PRODUCT="${UAC2_PRODUCT:-Pisound USB Audio}"
SRATE="${UAC2_SRATE:-48000}"
WITH_ECM="${USB_GADGET_ECM:-1}"
# Link-local, so the Mac's own self-assigned 169.254/16 address can reach it
# without a DHCP server at either end. mDNS does the naming.
GADGET_IP="${USB_GADGET_IP:-169.254.1.1/16}"

die() { echo "$*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "must run as root - configfs is not writable otherwise"
}

ensure_configfs() {
  modprobe libcomposite 2>/dev/null || true
  [[ -d /sys/kernel/config ]] || die "no /sys/kernel/config - this kernel has no configfs"
  mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
  [[ -d /sys/kernel/config/usb_gadget ]] ||
    die "configfs is mounted but usb_gadget is missing - libcomposite failed to load"
}

find_udc() {
  local udc
  udc=$(ls /sys/class/udc 2>/dev/null | head -n1)
  [[ -n "$udc" ]] || die "no USB device controller in /sys/class/udc - the Pi is not in
peripheral mode. Check that the boot config has:

    dtoverlay=dwc2,dr_mode=peripheral      (config.txt, and no otg_mode=1)
    modules-load=dwc2                      (cmdline.txt, same single line)

then reboot. On a Pi 4 only the USB-C power port can do this."
  echo "$udc"
}

bound_to() { cat "$GADGET/UDC" 2>/dev/null || true; }

serial() {
  local s
  s=$(awk '/^Serial/ {print $3}' /proc/cpuinfo 2>/dev/null | tail -n1)
  echo "${s:-0000000000000000}"
}

# Derived from the board serial so both ends see the same device across reboots
# rather than a new one each time. 02: is locally administered and unicast.
mac_for() {
  local h
  h=$(printf '%s%s' "$(serial)" "$1" | sha256sum | head -c 10)
  echo "02:${h:0:2}:${h:2:2}:${h:4:2}:${h:6:2}:${h:8:2}"
}

# udev may rename the gadget netdev away from the ifname configfs reports, so
# fall back to matching on the MAC we assigned.
ecm_iface() {
  local want mac path
  want=$(cat "$GADGET/functions/$ECM/ifname" 2>/dev/null || true)
  if [[ -n "$want" && -d "/sys/class/net/$want" ]]; then
    echo "$want"
    return 0
  fi
  mac=$(mac_for dev)
  for path in /sys/class/net/*; do
    [[ "$(cat "$path/address" 2>/dev/null || true)" == "$mac" ]] || continue
    basename "$path"
    return 0
  done
  return 1
}

configure_net() {
  local iface i
  for i in $(seq 1 25); do
    iface=$(ecm_iface) && break
    sleep 0.2
  done
  [[ -n "${iface:-}" ]] || { echo "warning: ECM interface never appeared" >&2; return 0; }

  ip link set "$iface" up
  ip addr replace "$GADGET_IP" dev "$iface"
  echo "network on $iface at ${GADGET_IP%%/*}"
}

start() {
  require_root
  ensure_configfs

  local udc
  udc=$(find_udc)

  if [[ -n "$(bound_to)" ]]; then
    echo "already bound to $(bound_to)"
    return 0
  fi
  stop

  mkdir -p "$GADGET/strings/0x409" "$GADGET/$CONF/strings/0x409" "$GADGET/functions/$UAC2"

  echo 0x1d6b > "$GADGET/idVendor"   # Linux Foundation
  echo 0x0104 > "$GADGET/idProduct"  # Multifunction Composite Gadget
  echo 0x0200 > "$GADGET/bcdUSB"
  echo 0x0100 > "$GADGET/bcdDevice"

  echo "$(serial)"     > "$GADGET/strings/0x409/serialnumber"
  echo "pisound-tools" > "$GADGET/strings/0x409/manufacturer"
  echo "$PRODUCT"      > "$GADGET/strings/0x409/product"

  echo "UAC2" > "$GADGET/$CONF/strings/0x409/configuration"
  echo 500    > "$GADGET/$CONF/MaxPower"

  # c_* is the host-playback stream, which surfaces on the Pi as ALSA *capture*.
  # p_chmask=0 drops the return path - the Pi sends nothing back to the host.
  echo 3        > "$GADGET/functions/$UAC2/c_chmask"
  echo "$SRATE" > "$GADGET/functions/$UAC2/c_srate"
  echo 2        > "$GADGET/functions/$UAC2/c_ssize"
  echo 0        > "$GADGET/functions/$UAC2/p_chmask"
  ln -s "$GADGET/functions/$UAC2" "$GADGET/$CONF/"

  # Audio stays first in the config so its interface numbering does not move.
  if [[ "$WITH_ECM" == 1 ]]; then
    mkdir -p "$GADGET/functions/$ECM"
    echo "$(mac_for host)" > "$GADGET/functions/$ECM/host_addr"
    echo "$(mac_for dev)"  > "$GADGET/functions/$ECM/dev_addr"
    ln -s "$GADGET/functions/$ECM" "$GADGET/$CONF/"
  fi

  echo "$udc" > "$GADGET/UDC"
  echo "bound '$PRODUCT' to $udc"

  [[ "$WITH_ECM" == 1 ]] && configure_net
  return 0
}

# Teardown is strictly reverse order; configfs refuses rmdir on anything still
# referenced, so a failure here means something above it did not come apart.
stop() {
  require_root
  [[ -d "$GADGET" ]] || return 0

  if [[ -n "$(bound_to)" ]]; then
    echo "" > "$GADGET/UDC"
  fi

  rm -f "$GADGET/$CONF/$UAC2" "$GADGET/$CONF/$ECM"
  rmdir "$GADGET/$CONF/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET/$CONF" 2>/dev/null || true
  rmdir "$GADGET/functions/$UAC2" 2>/dev/null || true
  rmdir "$GADGET/functions/$ECM" 2>/dev/null || true
  rmdir "$GADGET/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET" 2>/dev/null || true
}

status() {
  if [[ ! -d "$GADGET" ]]; then
    echo "gadget not created"
    return 1
  fi
  local udc iface
  udc=$(bound_to)
  [[ -n "$udc" ]] || { echo "gadget created but unbound"; return 1; }
  echo "bound to $udc"

  grep -q UAC2Gadget /proc/asound/cards 2>/dev/null &&
    echo "audio: UAC2Gadget" || echo "audio: no UAC2Gadget ALSA card"

  if [[ -d "$GADGET/functions/$ECM" ]]; then
    if iface=$(ecm_iface); then
      echo "network: $iface $(ip -4 -br addr show "$iface" 2>/dev/null | awk '{print $3}')"
    else
      echo "network: ECM configured but no interface"
    fi
  fi
}

case "${1:-start}" in
  start)  start ;;
  stop)   stop ;;
  status) status ;;
  *)      die "usage: $(basename "$0") [start|stop|status]" ;;
esac
