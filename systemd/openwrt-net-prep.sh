#!/bin/bash
# Host-Netz für openwrt-in-docker vorbereiten.
# Ablage auf dem Host: /srv/openwrt/sbin/openwrt-net-prep.sh (s. install.sh).
# Idempotent: legt nur an, was fehlt.
set -euo pipefail

BR_K3S="br-k3s-outbound"
BR_MGMT="br-management"
VETH_K3S_H="veth-k3s-h"
VETH_K3S_C="veth-k3s"
VETH_MGMT_H="veth-mgmt-h"
VETH_MGMT_C="veth-mgmt"

ensure_bridge() {
  local br="$1"
  if ! ip link show "$br" >/dev/null 2>&1; then
    ip link add name "$br" type bridge
    echo "bridge $br angelegt"
  fi
  ip link set "$br" up
}

ensure_veth_on_bridge() {
  local host_end="$1" cont_end="$2" bridge="$3"
  if ! ip link show "$host_end" >/dev/null 2>&1; then
    ip link add name "$host_end" type veth peer name "$cont_end"
    echo "veth $host_end <-> $cont_end angelegt"
  fi
  ip link set "$host_end" master "$bridge" 2>/dev/null || true
  ip link set "$host_end" up
}

ensure_bridge "$BR_K3S"
ensure_bridge "$BR_MGMT"
ensure_veth_on_bridge "$VETH_K3S_H" "$VETH_K3S_C" "$BR_K3S"
ensure_veth_on_bridge "$VETH_MGMT_H" "$VETH_MGMT_C" "$BR_MGMT"

# IPv4-Forwarding auf dem Host (für geroutete Setups; für reine L2-Bridges harmlos).
sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "host-netz bereit: $BR_K3S ($VETH_K3S_H), $BR_MGMT ($VETH_MGMT_H)"
