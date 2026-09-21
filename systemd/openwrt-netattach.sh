#!/bin/bash
# Interfaces in die Netz-Namespace des OpenWrt-Containers schieben.
# Ablage auf dem Host: /srv/openwrt/sbin/openwrt-netattach.sh (s. install.sh).
# Host-Namen -> Container-Namen (s. doc/interfaces):
#   enp2s0      -> lan    (physisch, LAN)
#   enp4s0f3u1u4-> wan    (physisch/USB, WAN)
#   veth-k3sExtrn -> k3s  (Host-Ende veth-k3sExtrn-h, DHCP direkt darauf)
#   veth-mgmt   -> mgmt   (Host-Ende veth-mgmt-h, DHCP direkt darauf)
#   WLAN-Phy von wlp3s0 -> Container-Netns (per iw, siehe unten)
set -euo pipefail

CONTAINER="openwrt"

log() { echo "netattach: $*" >&2; }

# Auf laufenden Container warten (max. 60 s).
PID=""
for _ in $(seq 1 60); do
  PID="$(docker inspect --format '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || true)"
  if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    break
  fi
  sleep 1
done
if [ -z "$PID" ] || [ "$PID" = "0" ]; then
  log "FEHLER: Container $CONTAINER nicht laufend"
  exit 1
fi
log "Container-PID: $PID"

move_ip_iface() {
  local host_name="$1" cont_name="$2"
  # Bereits im Container? (z. B. nach Re-Run)
  if nsenter -t "$PID" -n ip link show "$cont_name" >/dev/null 2>&1; then
    log "$cont_name bereits in Container-Netns"
  else
    # Auf dem Host warten (max. 30 s): veth-Paare legt networkd asynchron an.
    local i
    for i in $(seq 1 30); do
      ip link show "$host_name" >/dev/null 2>&1 && break
      sleep 1
    done
    if ! ip link show "$host_name" >/dev/null 2>&1; then
      log "FEHLER: Host-Interface $host_name nicht gefunden"
      return 1
    fi
    # Altes Überbleibsel mit Zielnamen im Container entfernen.
    nsenter -t "$PID" -n ip link del "$cont_name" >/dev/null 2>&1 || true
    ip link set "$host_name" netns "$PID" name "$cont_name"
    log "$host_name -> $cont_name gemovt"
  fi
  nsenter -t "$PID" -n ip link set "$cont_name" up
}

# Stabile MACs auf den Container-Interfaces (für DHCP-Wiedererkennung).
set_mac() {
  local cont_name="$1" mac="$2"
  nsenter -t "$PID" -n ip link set "$cont_name" down
  nsenter -t "$PID" -n ip link set "$cont_name" address "$mac"
  nsenter -t "$PID" -n ip link set "$cont_name" up
}

move_ip_iface "enp2s0" "lan"
move_ip_iface "enp4s0f3u1u4" "wan"
move_ip_iface "veth-k3sExtrn" "k3s"
move_ip_iface "veth-mgmt" "mgmt"

# Lokal vergebene, stabile MACs (02:xx:xx... = locally administered) für
# DHCP-Wiedererkennung. Bei Bedarf anpassen; falls der WAN-Provider an die
# Hardware-MAC bindet, die wan-Zeile entfernen/auskommentieren.
set_mac "lan" "02:00:0a:01:01:01"
set_mac "wan" "02:00:0a:02:02:02"
set_mac "k3s" "02:00:0a:03:03:03"
set_mac "mgmt" "02:00:0a:04:04:04"

# IPv6-Forwarding in der Container-Netns einschalten. Läuft bewusst vom Host
# aus per nsenter: /proc/sys ist im Container read-only (Docker-Verbot, kein
# Volume/Mount kann das aufheben), aber /proc/sys/net gilt pro Netns und der
# Host darf die fremde Netns betreten. Erst nach dem Move, damit die Keys greifen.
nsenter -t "$PID" -n sysctl -w net.ipv6.conf.default.forwarding=1
nsenter -t "$PID" -n sysctl -w net.ipv6.conf.all.forwarding=1
# IPv4-Forwarding ebenfalls hier (Container routet/NATet) statt auf dem Host
# (der ist nur DHCP-Client auf den veth-Enden und routet nichts selbst).
nsenter -t "$PID" -n sysctl -w net.ipv4.ip_forward=1
log "Forwarding in Container-Netns aktiviert (ipv6 default/all, ipv4)"

# WLAN: kein ip-Objekt, sondern der ganze 802.11-Phy muss umziehen.
# Namensfalle: iw dev listet Phys als "phy#0", als Parameter und in sysfs
# heißen sie "phy0" (ohne #). Beim Parsen von iw-Output das # daher auflösen.
# 1. Phy bestimmen: über bekannte Interface-Namen, sonst einzigen Phy nehmen.
PHY=""
for _iface in wlp3s0 wlp0s3 wlan0; do
  if [ -e "/sys/class/net/$_iface/phy80211" ]; then
    PHY="$(basename "$(readlink "/sys/class/net/$_iface/phy80211")")"
    log "WLAN-Phy $PHY über Interface $_iface gefunden"
    break
  fi
done
if [ -z "$PHY" ] && [ "$(ls -d /sys/class/ieee80211/* 2>/dev/null | wc -l)" = "1" ]; then
  PHY="$(basename "$(ls -d /sys/class/ieee80211/*)")"
  log "WLAN-Phy $PHY über Fallback (einziger Phy) gefunden"
fi
if [ -n "$PHY" ]; then
  if [ -e "/sys/class/ieee80211/$PHY" ]; then
    # 2. Alte, noch mit dem Phy verbundene Interfaces finden und löschen.
    OLD_IFACES="$(iw dev 2>/dev/null | awk -v phy="$PHY" '/^phy#/ {cur=$1; sub(/^phy#/, "phy", cur)} cur == phy && $1 == "Interface" {print $2}')"
    for _old in $OLD_IFACES; do
      ip link set "$_old" down 2>/dev/null || true
      iw dev "$_old" del
      log "altes Interface $_old auf $PHY gelöscht"
    done
    # 3. Phy in die Container-Netns schieben.
    iw phy "$PHY" set netns "$PID"
    log "WLAN-Phy $PHY in Container-Netns gemovt"
    # 4. Neues Interface in der Container-Netns anlegen (idempotent).
    # iw läuft vom Host (Binary), nur die Netns ist die des Containers.
    if nsenter -t "$PID" -n ip link show wlan0 >/dev/null 2>&1; then
      log "wlan0 bereits in Container-Netns vorhanden"
    else
      nsenter -t "$PID" -n iw phy "$PHY" interface add wlan0 type managed && log "Interface wlan0 auf $PHY in Container-Netns angelegt" || log "FEHLER: Interface wlan0 auf $PHY in Container-Netns anlegen gescheitert"
    fi
    # 5. Erfolg prüfen am Interface statt am Phy: `iw phy info` (Capability-
    # Dump) schlägt je nach Treiber/Zustand auch bei gemovtem Phy fehl, während
    # `iw dev` ihn längst zeigt. wlan0 ist das Kriterium, das wirklich zählt.
    if ! nsenter -t "$PID" -n ip link show wlan0 >/dev/null 2>&1; then
      log "FEHLER: wlan0 nach Anlegen in Container-Netns (PID $PID) nicht vorhanden."
      log "Container-Seite iw: $(nsenter -t "$PID" -n iw dev 2>&1 | head -10)"
      log "Container-Seite ip: $(nsenter -t "$PID" -n ip -o link show 2>&1 | head -10)"
      exit 1
    fi
    log "wlan0 in Container-Netns verifiziert"
  else
    log "WLAN-Phy $PHY bereits in Container-Netns"
  fi
elif nsenter -t "$PID" -n ip link show wlan0 >/dev/null 2>&1; then
  log "wlan0 bereits in Container-Netns vorhanden (Phy schon früher gemovt)"
else
  log "WARNUNG: kein WLAN-Phy gefunden, wifi übersprungen"
fi

log "fertig"
