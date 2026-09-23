#!/usr/bin/env -S buildah unshare bash
set -euo pipefail
# Variablen übergeben oder Defaults nutzen
DIRNAME=`dirname $0`
IMAGE_REGISTRY="${1:-registry.local}"
IMAGE_NAME="${2:-openwrt-in-docker}"
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
echo buildah container "$container @ ${mountpoint}"
# 1. Rootfs holen (z. B. via curl im Skript oder vorher per Workflow-Schritt heruntergeladen)
curl -o "openwrt-rootfs-${LATEST}.tgz" "https://downloads.openwrt.org/releases/${LATEST}/targets/x86/64/openwrt-${LATEST}-x86-64-rootfs.tar.gz" 
tar -xzf "openwrt-rootfs-${LATEST}.tgz" -C "${mountpoint}"
# 1b. Patches aus build/patches einspielen (z. B. dhcpv6.script: echo >
# /proc/sys ersetzen durch ip/sysctl, da /proc/sys im Container ro ist).
if [ -d "${DIRNAME}/patches" ]; then
    for p in "${DIRNAME}"/patches/*.patch; do
        [ -e "$p" ] || continue
        echo "wende Patch an: $p"
        patch -s -d "${mountpoint}" -p1 < "$p"
    done
fi
# 1c. Shell-Alias vi -> vim (vim-Paket ist in additional-packages).
# /etc/profile: für Login-Shells. /etc/shinit + ENV: für nicht-Login-Shells
# wie `docker exec … ash` (busybox-ash liest $ENV bei interaktiven Shells).
# Beide landen über .etc.pristine per Entrypoint-Sync im /etc-Volume
# (weder profile noch shinit sind von Updates ausgenommen).
if ! grep -q "alias vi=vim" "${mountpoint}/etc/profile" 2>/dev/null; then
    echo "alias vi=vim" >> "${mountpoint}/etc/profile"
fi
if ! grep -q "alias vi=vim" "${mountpoint}/etc/shinit" 2>/dev/null; then
    echo "alias vi=vim" >> "${mountpoint}/etc/shinit"
fi
rm "${mountpoint}/etc/resolv.conf"
pwd
ls -l
ls -ld "${mountpoint}" "${mountpoint}/etc" "${mountpoint}/etc/resolv.conf" || true
# 2. DNS für den Build-Prozess (nutzt k3s CoreDNS)
cp /etc/resolv.conf "${mountpoint}/etc/resolv.conf"
# 3. Pakete installieren
buildah run "$container" apk update
buildah run "$container" apk add $PACKAGES
# 4. Eigene Configs ins Image injizieren
if [ -d "${DIRNAME}/configs" ]; then
    cp -r "${DIRNAME}"/configs/* "${mountpoint}/etc/config/"
fi
# 5. Finale Konfiguration & Push Vorbereitung
rm "${mountpoint}/etc/resolv.conf"
tar -xvzf "openwrt-rootfs-${LATEST}.tgz" -C "${mountpoint}" ./etc/resolv.conf
ls -ld "${mountpoint}" "${mountpoint}/etc" "${mountpoint}/etc/resolv.conf" || true
mv "${mountpoint}/etc" "${mountpoint}/.etc.pristine"
mkdir "${mountpoint}/etc"
mkdir -p "${mountpoint}/usr/local/bin"
cp -v "${DIRNAME}/entrypoint.sh" "${mountpoint}/usr/local/bin/entrypoint.sh"
chmod +x "${mountpoint}/usr/local/bin/entrypoint.sh"
echo finished.
ls -l "${mountpoint}"
#buildah config --entrypoint '["/sbin/init"]' "$container"
buildah config --entrypoint '["/bin/ash", "/usr/local/bin/entrypoint.sh"]' "$container"
# ENV zeigt auf die Shell-Init für nicht-Login-Shells (s. 1c).
buildah config --env ENV=/etc/shinit "$container"
buildah unmount "$container"
## In die lokale Cluster-Registry committen/pushen
#buildah commit "$container" "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
#buildah push "${IMAGE_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
# stattdessen lokal exportieren
buildah commit "$container" "${IMAGE_NAME}:${IMAGE_TAG}"
rm -f "${IMAGE_NAME}-${IMAGE_TAG}".tar || true
buildah push "${IMAGE_NAME}:${IMAGE_TAG}" docker-archive:"${IMAGE_NAME}-${IMAGE_TAG}".tar:"${IMAGE_NAME}:${IMAGE_TAG}"
