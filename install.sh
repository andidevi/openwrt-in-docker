#!/bin/bash
# OpenWrt-Container-Setup auf dem Ziel-Host direkt aus dem Repo installieren.
# Aufruf im Repo-Root (oder mit Pfad dorthin):
#   sudo ./install.sh [/pfad/zum/repo] [/srv/openwrt]
# Installiert Compose-Datei + Skripte nach /srv/openwrt/docker, Units nach
# /etc/systemd/system (mit passenden Rechten/Owner/Group für systemd),
# lädt systemd neu und aktiviert die Units.
# Startet nichts automatisch (Reihenfolge: prep testen -> openwrt starten).
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

# Compose-Datei: root:root, 0644 (wird nur gelesen).
install -v -m 0644 -o root -g root "$REPO/docker/docker-compose.yml" "$PREFIX/docker/"

# Skripte (net-prep, netattach, uci-setup): root:root, 0755 (werden ausgeführt).
for script in "$REPO"/systemd/*.sh; do
  install -v -m 0755 -o root -g root "$script" "$PREFIX/sbin/"
done

# Units: root:root, 0644 (systemd verlangt root-Ownership, nicht beschreibbar für andere).
for unit in "$REPO"/systemd/*.service; do
  install -v -m 0644 -o root -g root "$unit" /etc/systemd/system/
done

systemctl daemon-reload
systemctl enable host-net-prep.service openwrt.service openwrt-netattach.service

echo "ok: installiert unter $PREFIX, Units aktiviert."
echo "Weiter: systemctl start host-net-prep.service # Bridges/veth prüfen (ip link, bridge link)"
echo "Dann:   systemctl start openwrt.service       # Container + Interface-Anbindung"
echo "Danach: sh $PREFIX/sbin/openwrt-uci-setup.sh per docker cp/exec im Container (s. Skriptkopf)"
