#!/bin/bash
# OpenWrt-Container-Setup auf dem Ziel-Host direkt aus dem Repo installieren.
# Aufruf im Repo-Root (oder mit Pfad dorthin):
#   sudo ./install.sh [/pfad/zum/repo] [/srv/openwrt]
# Installiert Compose-Datei + Skripte nach /srv/openwrt, Units nach
# /etc/systemd/system, networkd-Profile nach /etc/systemd/network und
# sysctl-Config nach /etc/sysctl.d (mit passenden Rechten/Owner/Group),
# lädt systemd neu und aktiviert die Units.
# Startet nichts automatisch (erst veth prüfen, dann openwrt starten).
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
  echo "FEHLER: als root ausführen (sudo)" >&2
  exit 1
fi

DIRNAME=`dirname $0`
REPO="${1:-$DIRNAME}"
PREFIX="${2:-/srv/openwrt}"

if [ ! -f "$REPO/docker/docker-compose.yml" ]; then
  echo "FEHLER: $REPO sieht nicht wie das openwrt-in-docker-Repo aus" >&2
  exit 1
fi

# Verzeichnisse: root:root, 0755 (systemd liest Units, Container-Unit liest Compose).
install -d -m 0755 -o root -g root "$PREFIX/docker" "$PREFIX/sbin"

# Compose-Datei + seccomp-Profil (von security_opt referenziert):
# root:root, 0644 (wird nur gelesen).
install -v -m 0644 -o root -g root "$REPO/docker/docker-compose.yml" "$PREFIX/docker/"
for profile in "$REPO"/docker/*.json; do
  install -v -m 0644 -o root -g root "$profile" "$PREFIX/docker/"
done

# Skripte (netattach, uci-setup): root:root, 0755 (werden ausgeführt).
for script in "$REPO"/systemd/*.sh; do
  install -v -m 0755 -o root -g root "$script" "$PREFIX/sbin/"
done

# Units und Slice: root:root, 0644 (systemd verlangt root-Ownership,
# nicht beschreibbar für andere). Die Slice hat keine [Install]-Sektion und
# wird daher nicht enabled, sondern bei Bedarf automatisch aktiviert.
for unit in "$REPO"/systemd/*.service "$REPO"/systemd/*.slice; do
  install -v -m 0644 -o root -g root "$unit" /etc/systemd/system/
done

# networkd-Profile für die veth-Paare (netdev = anlegen, network = DHCP
# direkt auf den Host-Enden): root:root, 0644.
for net in "$REPO"/systemd/*.netdev "$REPO"/systemd/*.network; do
  install -v -m 0644 -o root -g root "$net" /etc/systemd/network/
done

# sysctl-Config (ip_forward): root:root, 0644, sofort anwenden.
for conf in "$REPO"/systemd/*.conf; do
  install -v -m 0644 -o root -g root "$conf" /etc/sysctl.d/
done
sysctl --system >/dev/null

systemctl daemon-reload
systemctl enable openwrt-modules.service openwrt.service openwrt-netattach.service
# networkd die neuen Profile bekannt machen (lädt nur, wenn networkd läuft).
networkctl reload 2>/dev/null || true

echo "ok: installiert unter $PREFIX, Units aktiviert."
echo "Weiter: networkctl status veth-k3sExtrn-h veth-mgmt-h # veth-Paare prüfen"
echo "Dann:   systemctl start openwrt.service                 # Container + Interface-Anbindung"
echo "Danach: sh $PREFIX/sbin/openwrt-uci-setup.sh per docker cp/exec im Container (s. Skriptkopf)"
