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
TRANSACTION="/boot/config/custom/array-serial/pool-migration-transaction.sh"

MODE="preview"

case "${1:-}" in
    "")
        ;;
    --apply)
        MODE="apply"
        ;;
    *)
        echo "STOP: Verwendung: $0 [--apply]"
        exit 1
        ;;
esac

if [ "$MODE" = "apply" ]; then
    PLAN_FILE="/tmp/pool-migration-plan.$$"
    trap 'rm -f "$PLAN_FILE"' EXIT HUP INT TERM
else
    PLAN_FILE="${POOL_MIGRATION_PLAN_FILE:-}"
fi
if [ -n "$PLAN_FILE" ]; then
    : > "$PLAN_FILE" || exit 1
fi


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
    FSTYPE="$(wert_cfg diskFsType "$CFG")"

    echo
    echo "===== POOL: $NAME ====="
    echo "Dateisystem: ${FSTYPE:-unbekannt}"
    echo "Pool-UUID:   ${UUID:-FEHLT}"

    if [ -z "$UUID" ]; then
        echo "STOP: Pool-UUID fehlt."
        FEHLER=1
        continue
    fi

    DISKID_LIST="$(
        awk '
            {
                line=$0
                sub(/\r$/, "", line)

                if (match(line, /^diskId(\.[0-9]+)?="/)) {
                    pos=index(line, "=")
                    key=substr(line, 1, pos-1)
                    value=substr(line, pos+2)
                    sub(/"$/, "", value)

                    if (value != "")
                        print key "\t" value
                }
            }
        ' "$CFG"
    )"

    if [ -z "$DISKID_LIST" ]; then
        echo "STOP: Keine Pool-diskId gefunden."
        FEHLER=1
        continue
    fi

    while IFS="$(printf '\t')" read -r CFG_KEY ALT; do
        [ -n "$CFG_KEY" ] || continue
        [ -n "$ALT" ] || continue

        echo
        echo "Pool-Key:    $CFG_KEY"
        echo "Alte ID:     $ALT"

        TREFFER=0
        MATCH_PARENT=""
        MATCH_SOURCE=""
        MATCH_SHORT=""
        MATCH_NEW=""

        while IFS= read -r DEV; do
            [ -n "$DEV" ] || continue
            [ -b "/dev/$DEV" ] || continue

            DEVTYPE="$(lsblk -ndo TYPE "/dev/$DEV" 2>/dev/null | head -n1)"
            [ "$DEVTYPE" = "disk" ] || continue

            IDENT="$(
                timeout 20 /bin/bash "$SERIAL_ID" "/dev/$DEV" 2>/dev/null
            )" || continue

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

            [ -n "$SOURCE" ] && [ -n "$SHORT" ] && [ -n "$NEU" ] || continue

            case "$ALT" in
                *"$SHORT"*)
                    TREFFER=$((TREFFER + 1))
                    MATCH_PARENT="$DEV"
                    MATCH_SOURCE="$SOURCE"
                    MATCH_SHORT="$SHORT"
                    MATCH_NEW="$NEU"
                    ;;
            esac
        done < <(lsblk -dnro NAME)

        if [ "$TREFFER" -ne 1 ]; then
            echo "STOP: Alte ID wurde auf $TREFFER Hardware-Geraete aufgeloest."
            FEHLER=1
            continue
        fi

        echo "Parent:      /dev/$MATCH_PARENT"
        echo "Quelle:      $MATCH_SOURCE"
        echo "Serial:      $MATCH_SHORT"
        echo "Neue ID:     $MATCH_NEW"

        if [ "$ALT" = "$MATCH_NEW" ]; then
            echo "Status:      BEREITS_SAUBER"
        else
            echo "Status:      MIGRATION_ERFORDERLICH"

            if [ -n "$PLAN_FILE" ]; then
                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$CFG" "$UUID" "$CFG_KEY" "$ALT" "$MATCH_NEW" \
                    "$MATCH_SOURCE" "$MATCH_SHORT" "$MATCH_PARENT" \
                    >> "$PLAN_FILE" || {
                        echo "STOP: Pool-Migrationsplan konnte nicht geschrieben werden."
                        exit 1
                    }
            fi

            CHANGE_COUNT=$((CHANGE_COUNT + 1))
        fi
    done <<< "$DISKID_LIST"
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

if [ "$MODE" = "apply" ]; then
    if [ "$CHANGE_COUNT" -eq 0 ]; then
        echo
        echo "ERGEBNIS: POOL_MIGRATION_NICHT_ERFORDERLICH"
        exit 0
    fi

    [ -s "$PLAN_FILE" ] || {
        echo "STOP: Migrationsplan ist leer."
        exit 1
    }

    [ -r "$TRANSACTION" ] || {
        echo "STOP: Transaktionsbackend fehlt: $TRANSACTION"
        exit 1
    }

    echo
    echo "===== POOL-MIGRATION – APPLY ====="

    POOL_MIGRATION_WRITE_GATE=1         /bin/bash "$TRANSACTION" "$PLAN_FILE" || {
            echo "STOP: Pool-Migration fehlgeschlagen."
            exit 1
        }

    echo
    echo "ERGEBNIS: POOL_MIGRATION_APPLY_OK"
fi
echo
if [ "$MODE" = "preview" ]; then
    echo "Preview."
    echo "Keine Pool-CFG geaendert."
else
    echo "Apply abgeschlossen."
    echo "Pool-CFG-Identitaeten wurden bei Bedarf migriert."
fi
echo "Keine Partitionierung."
echo "Keine Dateisystem-Aenderung."
