#!/bin/sh
# Entrypoint OHNE mount/privileged: trennt Image (/.etc.pristine) und Konfiguration (Volume auf /etc).
# - Bei jedem Boot werden alle Dateien aus /.etc.pristine nach /etc übernommen,
#   die dort fehlen oder neuer sind als die Version im Volume.
# - Ausgenommen vom Update (bleiben immer Volume-Stand, werden aber kopiert,
#   wenn sie komplett fehlen): config/, dropbear/, board.json, shadow,
#   passwd, rc.local, resolv.conf (jeweils relativ zu /etc).
# - Danach startet /sbin/init; UCI-/SSH-/User-Änderungen landen direkt im Volume.
set -eu

PRISTINE="${PRISTINE_DIR:-/.etc.pristine}"
TARGET="${ETC_DIR:-/etc}"
INIT="${INIT:-/sbin/init}"

if [ ! -d "$PRISTINE" ]; then
  echo "[entrypoint] WARN: $PRISTINE fehlt, kein Sync möglich." >&2
  exec "$INIT"
fi

mkdir -p "$TARGET"

# Exakte Treffer auf relat. Pfade (relativ zu /etc bzw. /.etc.pristine).
is_excluded() {
  case "$1" in
    config|config/*|\
dropbear|dropbear/*|\
board.json|\
shadow|\
passwd|\
rc.local|\
resolv.conf) return 0 ;;
  esac
  return 1
}

updated=0
skipped=0
# -mindepth 1: PRISTINE selbst nicht verarbeiten; Verzeichnisse vorab anlegen.
cd "$PRISTINE"
# shellcheck disable=SC2044
for src in $(find . -mindepth 1 -print | sed 's|^\./||' | sort); do
  [ "$src" = "." ] && continue
  if is_excluded "$src"; then
    # Ausgeschlossen: vorhandene Dateien bleiben unangetastet,
    # fehlende werden kopiert (gilt auch für neue Dateien in config/, dropbear/).
    if [ ! -e "$TARGET/$src" ] && [ ! -L "$TARGET/$src" ]; then
      mkdir -p "$TARGET/$(dirname "$src")"
      cp -a "$PRISTINE/$src" "$TARGET/$src"
      updated=$((updated + 1))
    else
      echo "$src skipped ..."
      skipped=$((skipped + 1))
    fi
    continue
  fi
  if [ -d "$PRISTINE/$src" ] && [ ! -L "$PRISTINE/$src" ]; then
    mkdir -p "$TARGET/$src"
    continue
  fi
  # Reguläre Dateien, Symlinks, Sonstiges: übernehmen wenn fehlend oder Quelle neuer.
  if [ ! -e "$TARGET/$src" ] && [ ! -L "$TARGET/$src" ]; then
    mkdir -p "$TARGET/$(dirname "$src")"
    cp -a "$PRISTINE/$src" "$TARGET/$src"
    updated=$((updated + 1))
  elif [ "$PRISTINE/$src" -nt "$TARGET/$src" ]; then
    mkdir -p "$TARGET/$(dirname "$src")"
    cp -a "$PRISTINE/$src" "$TARGET/$src"
    updated=$((updated + 1))
  fi
done

echo "[entrypoint] Sync $PRISTINE -> $TARGET: $updated kopiert/aktualisiert, $skipped ausgenommen (Volume-Stand)." >&2
echo "[entrypoint] Übergabe an $INIT ..." >&2
exec "$INIT"
