#!/usr/bin/env -S buildah unshare bash
set -euo pipefail
# Variablen übergeben oder Defaults nutzen
DIRNAME=`dirname $0`
IMAGE_REGISTRY="${1:-registry.local}"
IMAGE_NAME="${2:-openwrt-k3s}"
IMAGE_TAG="${3:-latest}"
PACKAGES=`cat "${DIRNAME}/additional-packages"`
LATEST=$(curl -s "https://api.github.com/repos/openwrt/openwrt/releases" | \
    jq -r '[.[] | select(.prerelease == false) | .tag_name | ltrimstr("v")] | sort_by(split(".") | map(tonumber)) | last')
echo Shell level $SHLVL
id
echo openwrt latest $LATEST
echo will ad following packages: $PACKAGES


container=$(buildah from scratch)
mountpoint=$(buildah mount "$container")
echo buildah container "$container @ $mountpoint"
# 1. Rootfs holen (z. B. via curl im Skript oder vorher per Workflow-Schritt heruntergeladen)
curl -o "openwrt-rootfs-${LATEST}.tgz" "https://downloads.openwrt.org/releases/${LATEST}/targets/x86/64/openwrt-${LATEST}-x86-64-rootfs.tar.gz" 
tar -xzf "openwrt-rootfs-${LATEST}.tgz" -C "$mountpoint"
rm "$mountpoint/etc/resolv.conf"
pwd
ls -l
ls -ld "$mountpoint" "$mountpoint/etc" "$mountpoint/etc/resolv.conf" || true
# 2. DNS für den Build-Prozess (nutzt k3s CoreDNS)
cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
# 3. Pakete installieren
buildah run "$container" apk update
buildah run "$container" apk add $PACKAGES
# 4. Eigene Configs ins Image injizieren
if [ -d "${DIRNAME}/configs" ]; then
    cp -r "${DIRNAME}"/configs/* "$mountpoint/etc/config/"
fi
# 5. Finale Konfiguration & Push Vorbereitung
rm "$mountpoint/etc/resolv.conf"
tar -xvzf "openwrt-rootfs-${LATEST}.tgz" -C "$mountpoint" ./etc/resolv.conf
ls -ld "$mountpoint" "$mountpoint/etc" "$mountpoint/etc/resolv.conf" || true
buildah config --entrypoint '["/sbin/init"]' "$container"
buildah unmount "$container"
## In die lokale Cluster-Registry committen/pushen
#buildah commit "$container" "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
#buildah push "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
# stattdessen lokal exportieren
buildah commit "$container" "${IMAGE_NAME}:${IMAGE_TAG}"
rm -f "${IMAGE_NAME}-${IMAGE_TAG}".tar || true
buildah push "${IMAGE_NAME}:${IMAGE_TAG}" docker-archive:"${IMAGE_NAME}-${IMAGE_TAG}".tar:"${IMAGE_NAME}:${IMAGE_TAG}"
