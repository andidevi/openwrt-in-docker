#!/bin/sh
# OpenWrt-Netzkonfiguration für den Router-Container einspielen.
# AUSFÜHREN auf dem Ziel-Host im laufenden, angebundenen Container
# (nach install.sh liegt das Skript unter /srv/openwrt/sbin/):
#   docker cp /srv/openwrt/sbin/openwrt-uci-setup.sh openwrt:/tmp/openwrt-uci-setup.sh
#   docker exec openwrt sh /tmp/openwrt-uci-setup.sh
# Voraussetzung: Interfaces lan/wan/k3s/mgmt + WLAN-Phy sind in der
# Container-Netns (openwrt-netattach.service gelaufen).
# Die Konfiguration landet in /etc/config und bleibt im Volume erhalten
# (config/ wird vom Entrypoint-Update ausgenommen).
set -eu

# ---- Anpassen ----
LAN_IP="192.168.1.1/24"
K3S_IP="192.168.30.1/24"
MGMT_IP="192.168.99.1/24"
SSID="OpenWrt"
WPA_KEY="bitte-aendern-mindestens-8-zeichen"
# ---- Ende ----

have_iface() { ip link show "$1" >/dev/null 2>&1; }

for i in lan wan k3s mgmt; do
  have_iface "$i" || { echo "FEHLER: Interface $i fehlt in Container-Netns (netattach gelaufen?)" >&2; exit 1; }
done

# ---------- network ----------
uci set network.wan=interface
uci set network.wan.device='wan'
uci set network.wan.proto='dhcp'

uci set network.lan=interface
uci set network.lan.device='lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr="${LAN_IP%/*}"
uci set network.lan.netmask='255.255.255.0'

uci set network.k3s=interface
uci set network.k3s.device='k3s'
uci set network.k3s.proto='static'
uci set network.k3s.ipaddr="${K3S_IP%/*}"
uci set network.k3s.netmask='255.255.255.0'

uci set network.mgmt=interface
uci set network.mgmt.device='mgmt'
uci set network.mgmt.proto='static'
uci set network.mgmt.ipaddr="${MGMT_IP%/*}"
uci set network.mgmt.netmask='255.255.255.0'
uci commit network

# ---------- dhcp ----------
uci set dhcp.lan=dhcp
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'

uci set dhcp.k3s=dhcp
uci set dhcp.k3s.interface='k3s'
uci set dhcp.k3s.start='100'
uci set dhcp.k3s.limit='150'
uci set dhcp.k3s.leasetime='12h'

uci set dhcp.mgmt=dhcp
uci set dhcp.mgmt.interface='mgmt'
uci set dhcp.mgmt.start='100'
uci set dhcp.mgmt.limit='50'
uci set dhcp.mgmt.leasetime='12h'
uci commit dhcp

# ---------- wireless (AP auf dem hereingereichten Phy) ----------
if ! uci show wireless 2>/dev/null | grep -q '=wifi-device'; then
  wifi config
fi
RADIO="$(uci show wireless 2>/dev/null | sed -n 's/^wireless\.\([^.]*\)=wifi-device$/\1/p' | head -n 1)"
if [ -z "$RADIO" ]; then
  echo "WARNUNG: kein WLAN-Phy im Container gefunden, wireless übersprungen" >&2
else
  uci set "wireless.$RADIO.disabled='0'"
  uci set "wireless.default_$RADIO=wifi-iface"
  uci set "wireless.default_$RADIO.device=$RADIO"
  uci set "wireless.default_$RADIO.network='lan'"
  uci set "wireless.default_$RADIO.mode='ap'"
  uci set "wireless.default_$RADIO.ssid=$SSID"
  uci set "wireless.default_$RADIO.encryption='psk2'"
  uci set "wireless.default_$RADIO.key=$WPA_KEY"
  uci commit wireless
  echo "AP auf Funkgerät $RADIO eingerichtet (SSID $SSID, Netz lan)"
fi

# ---------- firewall ----------
# Zonen k3s/mgmt anlegen, falls fehlend. Stock-Zonen lan/wan existieren bereits
# und passen (Netze lan/wan) -> nur sicherstellen.
ensure_zone() {
  local name="$1" nets="$2" input="$3" output="$4" forward="$5" masq="$6" mtu="$7"
  local s
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=zone$/\1/p'); do
    if [ "$(uci -q get "firewall.$s.name")" = "$name" ]; then
      uci set "firewall.$s.network=$nets"
      uci set "firewall.$s.input=$input"
      uci set "firewall.$s.output=$output"
      uci set "firewall.$s.forward=$forward"
      [ -n "$masq" ] && uci set "firewall.$s.masq=$masq"
      [ -n "$mtu" ] && uci set "firewall.$s.mtu_fix=$mtu"
      return
    fi
  done
  s="$(uci add firewall zone)"
  uci set "firewall.$s.name=$name"
  uci set "firewall.$s.network=$nets"
  uci set "firewall.$s.input=$input"
  uci set "firewall.$s.output=$output"
  uci set "firewall.$s.forward=$forward"
  [ -n "$masq" ] && uci set "firewall.$s.masq=$masq"
  [ -n "$mtu" ] && uci set "firewall.$s.mtu_fix=$mtu"
}

ensure_zone lan 'lan' ACCEPT ACCEPT ACCEPT '' ''
ensure_zone wan 'wan' REJECT ACCEPT REJECT '1' '1'
ensure_zone k3s 'k3s' ACCEPT ACCEPT REJECT '' ''
ensure_zone mgmt 'mgmt' ACCEPT ACCEPT REJECT '' ''

# Forwardings deterministisch neu aufbauen: lan/k3s/mgmt -> wan.
# (Keine Inter-Zonen-Forwardings: lan, k3s und mgmt sind untereinander isoliert.)
for s in $(uci show firewall 2>/dev/null | sed -n 's/^firewall\.\([^=]*\)=forwarding$/\1/p'); do
  uci delete "firewall.$s"
done
for src in lan k3s mgmt; do
  s="$(uci add firewall forwarding)"
  uci set "firewall.$s.src=$src"
  uci set "firewall.$s.dest='wan'"
done
uci commit firewall

/etc/init.d/network reload
/etc/init.d/firewall reload
/etc/init.d/dnsmasq reload
[ -n "${RADIO:-}" ] && wifi reload 2>/dev/null || true

echo "fertig. Prüfung: ubus call network.interface dump ; logread | tail"
