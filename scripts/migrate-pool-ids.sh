#!/bin/bash

# Pool ID Migration
#
# Preview-only Entwicklungsstand.
#
# Zuordnung:
# Pool-CFG -> Pool-UUID -> vorhandene Partition -> Parent-Disk
# -> serial-id.sh -> stabile Hardware-ID.
#
# Keine Abhaengigkeit von sdX/nvmeX.
# Kein Schreiben an Pool-CFGs.
# Keine Dateisystem- oder Partitionsaenderung.

set -u

POOL_DIR="/boot/config/pools"
SERIAL_ID="/boot/config/custom/array-serial/serial-id.sh"

wert_cfg()
{
    KEY="$1"
    FILE="$2"

    awk -v key="$KEY" '
        index($0, key "=\"") == 1 {
            value = substr($0, length(key) + 3)

            if (substr(value, length(value), 1) == "\r")
                value = substr(value, 1, length(value) - 1)

            if (substr(value, length(value), 1) == "\"")
                value = substr(value, 1, length(value) - 1)

            print value
            exit
        }
    ' "$FILE"
}

[ -d "$POOL_DIR" ] || {
    echo "STOP: Pool-Verzeichnis fehlt."
    exit 1
}

[ -r "$SERIAL_ID" ] || {
    echo "STOP: serial-id.sh fehlt."
    exit 1
}

POOL_COUNT=0
CHANGE_COUNT=0
FEHLER=0

for CFG in "$POOL_DIR"/*.cfg; do
    [ -r "$CFG" ] || continue

    POOL_COUNT=$((POOL_COUNT + 1))

    NAME="$(basename "$CFG" .cfg)"
    UUID="$(wert_cfg diskUUID "$CFG")"
    ALT="$(wert_cfg diskId "$CFG")"
    FSTYPE="$(wert_cfg diskFsType "$CFG")"

    echo
    echo "===== POOL: $NAME ====="
    echo "Dateisystem: ${FSTYPE:-unbekannt}"
    echo "Pool-UUID:   ${UUID:-FEHLT}"
    echo "Alte ID:     ${ALT:-FEHLT}"

    if [ -z "$UUID" ] || [ -z "$ALT" ]; then
        echo "STOP: Pool-Metadaten unvollstaendig."
        FEHLER=1
        continue
    fi

    TREFFER=0
    PARTITION=""
    PARENT=""

    while IFS= read -r DEV; do
        [ -n "$DEV" ] || continue
        [ -b "/dev/$DEV" ] || continue

        DEVTYPE="$(lsblk -ndo TYPE "/dev/$DEV" 2>/dev/null | head -n1)"
        [ "$DEVTYPE" = "part" ] || continue

        DEVUUID="$(lsblk -ndo UUID "/dev/$DEV" 2>/dev/null | head -n1)"
        [ "$DEVUUID" = "$UUID" ] || continue

        DEV_PARENT="$(lsblk -ndo PKNAME "/dev/$DEV" 2>/dev/null | head -n1)"
        [ -n "$DEV_PARENT" ] || continue
        [ -b "/dev/$DEV_PARENT" ] || continue

        TREFFER=$((TREFFER + 1))
        PARTITION="$DEV"
        PARENT="$DEV_PARENT"
    done < <(lsblk -nrpo NAME | sed 's#^/dev/##')

    if [ "$TREFFER" -ne 1 ]; then
        echo "STOP: Pool-UUID wurde auf $TREFFER Partition(en) gefunden."
        FEHLER=1
        continue
    fi

    echo "Partition:   /dev/$PARTITION"
    echo "Parent:      /dev/$PARENT"

    IDENT="$(
        timeout 20 /bin/bash "$SERIAL_ID" "/dev/$PARENT" 2>/dev/null
    )" || {
        echo "STOP: Hardware-Resolver fuer /dev/$PARENT fehlgeschlagen."
        FEHLER=1
        continue
    }

    SOURCE="$(
        printf '%s\n' "$IDENT" |
            awk -F= '$1=="IDENTITY_SOURCE"{print substr($0,index($0,"=")+1); exit}'
    )"

    SHORT="$(
        printf '%s\n' "$IDENT" |
            awk -F= '$1=="ID_SERIAL_SHORT"{print substr($0,index($0,"=")+1); exit}'
    )"

    NEU="$(
        printf '%s\n' "$IDENT" |
            awk -F= '$1=="ID_SERIAL"{print substr($0,index($0,"=")+1); exit}'
    )"

    if [ -z "$SOURCE" ] || [ -z "$SHORT" ] || [ -z "$NEU" ]; then
        echo "STOP: Hardware-Identitaet unvollstaendig."
        FEHLER=1
        continue
    fi

    echo "Quelle:      $SOURCE"
    echo "Serial:      $SHORT"
    echo "Neue ID:     $NEU"

    if [ "$ALT" = "$NEU" ]; then
        echo "Status:      BEREITS_SAUBER"
    else
        echo "Status:      MIGRATION_ERFORDERLICH"
        CHANGE_COUNT=$((CHANGE_COUNT + 1))
    fi
done

echo
echo "===== ZUSAMMENFASSUNG ====="
echo "Pools:                 $POOL_COUNT"
echo "Migration erforderlich: $CHANGE_COUNT"

if [ "$FEHLER" -ne 0 ]; then
    echo "ERGEBNIS: POOL_PREVIEW_STOP"
    exit 1
fi

echo "ERGEBNIS: POOL_PREVIEW_OK"
echo
echo "Preview בלבד."
echo "Keine Pool-CFG geaendert."
echo "Keine Partitionierung."
echo "Keine Dateisystem-Aenderung."
