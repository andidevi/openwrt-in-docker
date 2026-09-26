#!/bin/bash
# openwrt-netroutes: hält die IPv6-Quell-Regeln für veth-k3sExtrn-h aktuell.
# Hintergrund-Dienst (openwrt-netroutes.service): pollt die globalen Adressen
# des Interfaces und gleicht die From-Regeln (Tabelle 1000, Priority 100) ab:
# fehlende anlegen, verwaiste löschen. Überlebt Provider-Ausfälle und
# PPPoE-Präfixwechsel ohne manuellen Eingriff (max. ein Intervall veraltet).
# Stirbt nie fatal: ohne Interface/Adressen einfach weiter warten.
# Ablage auf dem Host: /srv/openwrt/sbin/openwrt-netroutes.sh (s. install.sh).
set -euo pipefail

IFACE="${K3S_IFACE:-veth-k3sExtrn-h}"
TABLE="${K3S_TABLE:-1000}"
PRIO="${K3S_PRIO:-100}"
INTERVAL="${K3S_INTERVAL:-30}"

log() { echo "netroutes: $*" >&2; }

current_addrs() {
  ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | sort -u
}

# Nur eigene Regeln einsammeln: from <addr> + lookup <table> + Priority.
# Die statische oif-Regel aus der .network-Datei hat kein "from" und bleibt
# unangetastet.
current_rules() {
  ip -6 rule show 2>/dev/null \
    | awk -v table="$TABLE" -v prio="$PRIO:" \
      '$1 == prio && $2 == "from" && $(NF-1) == "lookup" && $NF == table {print $3}' \
    | sort -u
}

reconcile() {
  local addrs rules addr
  addrs="$(current_addrs)"
  rules="$(current_rules)"
  # Fehlende Regeln anlegen.
  for addr in $addrs; do
    if ! printf '%s\n' "$rules" | grep -qxF "$addr"; then
      if ip -6 rule add from "$addr/128" table "$TABLE" priority "$PRIO" 2>/dev/null; then
        log "Regel angelegt: from $addr table $TABLE priority $PRIO"
      else
        log "WARNUNG: Regel für $addr konnte nicht angelegt werden"
      fi
    fi
  done
  # Verwaiste Regeln entfernen (Adresse weg, z.B. nach Präfixwechsel).
  for addr in $rules; do
    if ! printf '%s\n' "$addrs" | grep -qxF "$addr"; then
      if ip -6 rule del from "$addr/128" table "$TABLE" priority "$PRIO" 2>/dev/null; then
        log "verwaiste Regel entfernt: from $addr table $TABLE"
      else
        log "WARNUNG: verwaiste Regel für $addr konnte nicht entfernt werden"
      fi
    fi
  done
}

log "gestartet (Interface $IFACE, Tabelle $TABLE, Priority $PRIO, Intervall ${INTERVAL}s)"
while true; do
  if ip link show "$IFACE" >/dev/null 2>&1; then
    reconcile
  fi
  sleep "$INTERVAL"
done
