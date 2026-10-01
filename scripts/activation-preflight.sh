#!/bin/bash
#
# topa-LE Unraid Array Serial
#
# Rein lesender Sicherheits-Preflight vor der persistenten Aktivierung.
#
# Sicherheitsmodell:
#
# - Array-Zuweisungen werden aus dem laufenden Unraid gelesen.
# - Pool-Zuweisungen werden aus /boot/config/pools/*.cfg gelesen.
# - Jede gespeicherte Zuweisung muss genau einem physischen Laufwerk
#   zugeordnet werden koennen.
# - Die Zuordnung erfolgt ueber die echte Hardware-Seriennummer bzw.
#   bereits vorhandene Projekt-ID.
# - Eine persistente Baseline darf nur fuer bereits sauber migrierte
#   Zuweisungen erzeugt werden.
# - CACHE ist fuer eine persistente Baseline nicht zulaessig.
#
# Dieses Skript:
#
# - installiert keine Udev-Regel
# - laedt keine Udev-Regel neu
# - fuehrt keinen Udev-Trigger aus
# - aendert keine Array-/Pool-Zuweisung
# - schreibt keine Baseline
# - schreibt keinen Freigabe-Marker

set -euo pipefail

BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_ID="$BASE/serial-id.sh"

DISKS_INI="/var/local/emhttp/disks.ini"
VAR_INI="/var/local/emhttp/var.ini"
POOL_DIR="/boot/config/pools"

TIMEOUT=20

[ "$(id -u)" -eq 0 ] || {
    echo "STOP: Root-Rechte erforderlich."
    exit 1
}

for DATEI in \
    "$SERIAL_ID" \
    "$BASE/format-disk-id.sh" \
    "$BASE/detect-transport.sh" \
    "$DISKS_INI" \
    "$VAR_INI"
do
    [ -r "$DATEI" ] || {
        echo "STOP: Erforderliche Datei nicht lesbar: $DATEI"
        exit 1
    }
done

for PROGRAMM in udevadm findmnt lsblk sed grep awk timeout; do
    command -v "$PROGRAMM" >/dev/null 2>&1 || {
        echo "STOP: Programm fehlt: $PROGRAMM"
        exit 1
    }
done

BOOT_QUELLE="$(findmnt -n -o SOURCE --target /boot)" || {
    echo "STOP: Boot-Quelle nicht ermittelbar."
    exit 1
}

BOOT_GERAET="$(lsblk -r -n -s -o NAME "$BOOT_QUELLE" | tail -n 1)" || {
    echo "STOP: Boot-Laufwerk nicht ermittelbar."
    exit 1
}

[ -n "$BOOT_GERAET" ] || {
    echo "STOP: Boot-Laufwerk ist leer."
    exit 1
}

#
# Gespeicherte Zuweisungen.
#
declare -A STORED_KIND=()
declare -A STORED_LABEL=()

ARRAY_ZUWEISUNGEN=0
POOL_ZUWEISUNGEN=0

gespeicherte_id_aufnehmen() {
    local ID="$1"
    local KIND="$2"
    local LABEL="$3"

    [ -n "$ID" ] || return 0

    if [ -n "${STORED_KIND[$ID]+x}" ]; then
        echo "STOP: Gespeicherte Kennung ist mehrfach vergeben:"
        echo "ID:       $ID"
        echo "Vorhanden: ${STORED_KIND[$ID]} / ${STORED_LABEL[$ID]}"
        echo "Weiter:    $KIND / $LABEL"
        exit 1
    fi

    STORED_KIND["$ID"]="$KIND"
    STORED_LABEL["$ID"]="$LABEL"
}

#
# Array aus disks.ini.
#
BLOCK=""

array_block_auswerten() {
    local BLOCK_IN="$1"
    local NAME=""
    local TYPE=""
    local ID=""

    [ -n "$BLOCK_IN" ] || return 0

    NAME="$(
        printf '%s\n' "$BLOCK_IN" |
            sed -n '1s/^\["\([^"]*\)"\]$/\1/p'
    )"

    TYPE="$(
        printf '%s\n' "$BLOCK_IN" |
            sed -n 's/^type="\([^"]*\)".*/\1/p' |
            head -n 1
    )"

    ID="$(
        printf '%s\n' "$BLOCK_IN" |
            sed -n 's/^idSb="\([^"]*\)".*/\1/p' |
            head -n 1
    )"

    case "$TYPE" in
        Parity|Data)
            if [ -n "$ID" ]; then
                gespeicherte_id_aufnehmen \
                    "$ID" \
                    "ARRAY" \
                    "${NAME:-unbekannter-Slot}"

                ARRAY_ZUWEISUNGEN=$((ARRAY_ZUWEISUNGEN + 1))
            fi
            ;;
    esac
}

while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do
    if [[ "$ZEILE" =~ ^\[.*\]$ ]]; then
        if [ -n "$BLOCK" ]; then
            array_block_auswerten "$BLOCK"
        fi

        BLOCK="$ZEILE"$'\n'
    else
        BLOCK+="$ZEILE"$'\n'
    fi
done < "$DISKS_INI"

if [ -n "$BLOCK" ]; then
    array_block_auswerten "$BLOCK"
fi

#
# Pools aus persistenten Pool-CFGs.
#
if [ -d "$POOL_DIR" ]; then
    for CFG in "$POOL_DIR"/*.cfg; do
        [ -r "$CFG" ] || continue

        POOL_NAME="$(basename "$CFG" .cfg)"

        while IFS=$'\t' read -r CFG_KEY ID; do
            [ -n "$CFG_KEY" ] || continue
            [ -n "$ID" ] || continue

            gespeicherte_id_aufnehmen \
                "$ID" \
                "POOL" \
                "$POOL_NAME/$CFG_KEY"

            POOL_ZUWEISUNGEN=$((POOL_ZUWEISUNGEN + 1))
        done < <(
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
        )
    done
fi

GESAMT_ZUWEISUNGEN=$((ARRAY_ZUWEISUNGEN + POOL_ZUWEISUNGEN))

[ "$GESAMT_ZUWEISUNGEN" -gt 0 ] || {
    echo "STOP: Keine gespeicherten Array-/Pool-Zuweisungen gefunden."
    exit 1
}

#
# Hardware einmal vollstaendig erfassen.
#
declare -a HW_DEVICES=()
declare -A HW_SERIAL=()
declare -A HW_SOURCE=()
declare -A HW_PROJECT_ID=()
declare -A HW_UDEV_ID=()

declare -A SEEN_SERIAL=()
declare -A SEEN_PROJECT_ID=()

for SYSDEV in /sys/class/block/*; do
    [ -e "$SYSDEV" ] || continue

    NAME="${SYSDEV##*/}"

    if [[ "$NAME" =~ ^sd[a-z]+$ ]]; then
        :
    elif [[ "$NAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        :
    else
        continue
    fi

    [ "$NAME" != "$BOOT_GERAET" ] || continue

    DEVTYPE="$(
        udevadm info --query=property --path="$SYSDEV" 2>/dev/null |
            sed -n 's/^DEVTYPE=//p' |
            head -n 1
    )"

    [ "$DEVTYPE" = "disk" ] || continue

    set +e
    IDENT="$(
        timeout "$TIMEOUT" \
            /bin/bash "$SERIAL_ID" "/dev/$NAME" \
            2>/dev/null
    )"
    RC=$?
    set -e

    if [ "$RC" -eq 124 ]; then
        echo "STOP: Hardware-Ermittlung fuer /dev/$NAME hat Timeout erreicht."
        exit 1
    fi

    if [ "$RC" -ne 0 ]; then
        echo "STOP: Hardware-Ermittlung fuer /dev/$NAME ist fehlgeschlagen."
        exit 1
    fi

    SERIAL="$(
        printf '%s\n' "$IDENT" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    SOURCE="$(
        printf '%s\n' "$IDENT" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
    )"

    PROJECT_ID="$(
        printf '%s\n' "$IDENT" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    [ -n "$SERIAL" ] &&
    [ -n "$SOURCE" ] &&
    [ -n "$PROJECT_ID" ] || {
        echo "STOP: Unvollstaendige Hardware-Identitaet fuer /dev/$NAME."
        exit 1
    }

    case "$SOURCE" in
        ATA|NVME|USB_SAT|CACHE)
            ;;
        *)
            echo "STOP: Unzulaessige Identitaetsquelle fuer /dev/$NAME: $SOURCE"
            exit 1
            ;;
    esac

    if [ -n "${SEEN_SERIAL[$SERIAL]+x}" ]; then
        echo "STOP: Hardware-Seriennummer ist nicht eindeutig: $SERIAL"
        echo "Erstes Geraet: ${SEEN_SERIAL[$SERIAL]}"
        echo "Weiteres Geraet: /dev/$NAME"
        exit 1
    fi

    if [ -n "${SEEN_PROJECT_ID[$PROJECT_ID]+x}" ]; then
        echo "STOP: Projekt-ID ist nicht eindeutig: $PROJECT_ID"
        echo "Erstes Geraet: ${SEEN_PROJECT_ID[$PROJECT_ID]}"
        echo "Weiteres Geraet: /dev/$NAME"
        exit 1
    fi

    UDEV_ID="$(
        udevadm info --query=property --name="/dev/$NAME" 2>/dev/null |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    SEEN_SERIAL["$SERIAL"]="/dev/$NAME"
    SEEN_PROJECT_ID["$PROJECT_ID"]="/dev/$NAME"

    HW_DEVICES+=("$NAME")
    HW_SERIAL["$NAME"]="$SERIAL"
    HW_SOURCE["$NAME"]="$SOURCE"
    HW_PROJECT_ID["$NAME"]="$PROJECT_ID"
    HW_UDEV_ID["$NAME"]="$UDEV_ID"
done

echo "===== ARRAY SERIAL – AKTIVIERUNGS-PREFLIGHT ====="
echo
echo "Boot-Laufwerk ausgeschlossen: /dev/$BOOT_GERAET"
echo "Array-Zuweisungen:            $ARRAY_ZUWEISUNGEN"
echo "Pool-Zuweisungen:             $POOL_ZUWEISUNGEN"
echo "Gespeicherte Zuweisungen:     $GESAMT_ZUWEISUNGEN"
echo "Hardware-Laufwerke geprueft:  ${#HW_DEVICES[@]}"
echo

#
# Jede gespeicherte Zuweisung einzeln auf Hardware aufloesen.
#
declare -A ASSIGNED_DEVICE=()
declare -A ASSIGNED_STORED_ID=()

declare -A BASELINE_HW=()
declare -A BASELINE_ID=()

ZUORDNUNGEN=0
FEHLER=0

for STORED_ID in "${!STORED_KIND[@]}"; do
    TREFFER=0
    MATCH_DEV=""

    for NAME in "${HW_DEVICES[@]}"; do
        SERIAL="${HW_SERIAL[$NAME]}"
        PROJECT_ID="${HW_PROJECT_ID[$NAME]}"

        MATCH=0

        #
        # Bereits sauber:
        # gespeicherte ID entspricht exakt der Projekt-ID.
        #
        if [ "$STORED_ID" = "$PROJECT_ID" ]; then
            MATCH=1
        else
            #
            # Bestehende alte Kennung:
            # dieselbe konservative Seriennummern-Aufloesung wie im
            # Array-Recovery-/Pool-Migrationspfad.
            #
            case "$STORED_ID" in
                "$SERIAL"|*_"$SERIAL"|*-"$SERIAL")
                    MATCH=1
                    ;;
            esac
        fi

        if [ "$MATCH" -eq 1 ]; then
            TREFFER=$((TREFFER + 1))
            MATCH_DEV="$NAME"
        fi
    done

    echo "------------------------------------------------------------"
    echo "Gespeichert: $STORED_ID"
    echo "Bereich:     ${STORED_KIND[$STORED_ID]}"
    echo "Zuordnung:   ${STORED_LABEL[$STORED_ID]}"

    if [ "$TREFFER" -ne 1 ]; then
        echo "Status:      NICHT_EINDEUTIG"
        echo "Treffer:     $TREFFER"
        FEHLER=1
        echo
        continue
    fi

    if [ -n "${ASSIGNED_DEVICE[$MATCH_DEV]+x}" ]; then
        echo "Status:      MEHRFACH_ZUGEORDNET"
        echo "Geraet:      /dev/$MATCH_DEV"
        echo "Bereits fuer: ${ASSIGNED_STORED_ID[$MATCH_DEV]}"
        FEHLER=1
        echo
        continue
    fi

    ASSIGNED_DEVICE["$MATCH_DEV"]=1
    ASSIGNED_STORED_ID["$MATCH_DEV"]="$STORED_ID"

    SERIAL="${HW_SERIAL[$MATCH_DEV]}"
    SOURCE="${HW_SOURCE[$MATCH_DEV]}"
    PROJECT_ID="${HW_PROJECT_ID[$MATCH_DEV]}"
    UDEV_ID="${HW_UDEV_ID[$MATCH_DEV]}"

    echo "Geraet:      /dev/$MATCH_DEV"
    echo "Quelle:      $SOURCE"
    echo "HW-Serial:   $SERIAL"
    echo "Udev-ID:     ${UDEV_ID:-<leer>}"
    echo "Projekt-ID:  $PROJECT_ID"

    if [ "$STORED_ID" != "$PROJECT_ID" ]; then
        echo "Status:      MIGRATION_ERFORDERLICH"
        FEHLER=1
        echo
        continue
    fi

    if [ "$UDEV_ID" != "$PROJECT_ID" ]; then
        echo "Status:      UDEV_NICHT_SAUBER"
        FEHLER=1
        echo
        continue
    fi

    #
    # CACHE darf nicht in eine persistente Baseline gelangen.
    #
    if [ "$SOURCE" = "CACHE" ]; then
        echo "Status:      CACHE_NICHT_BASELINEFAEHIG"
        FEHLER=1
        echo
        continue
    fi

    case "$SOURCE" in
        ATA|NVME|USB_SAT)
            ;;
        *)
            echo "Status:      UNGUELTIGE_BASELINE_QUELLE"
            FEHLER=1
            echo
            continue
            ;;
    esac

    if [ -n "${BASELINE_HW[$SERIAL]+x}" ]; then
        echo "Status:      BASELINE_HW_DOPPELT"
        FEHLER=1
        echo
        continue
    fi

    if [ -n "${BASELINE_ID[$PROJECT_ID]+x}" ]; then
        echo "Status:      BASELINE_ID_DOPPELT"
        FEHLER=1
        echo
        continue
    fi

    BASELINE_HW["$SERIAL"]="$MATCH_DEV"
    BASELINE_ID["$PROJECT_ID"]="$MATCH_DEV"

    ZUORDNUNGEN=$((ZUORDNUNGEN + 1))

    echo "Status:      BEREITS_SAUBER"
    echo
done

echo "===== ZUSAMMENFASSUNG ====="
echo "Array-Zuweisungen:        $ARRAY_ZUWEISUNGEN"
echo "Pool-Zuweisungen:         $POOL_ZUWEISUNGEN"
echo "Gesamt gespeichert:       $GESAMT_ZUWEISUNGEN"
echo "Sauber autorisierbar:     $ZUORDNUNGEN"

if [ "$ZUORDNUNGEN" -ne "$GESAMT_ZUWEISUNGEN" ]; then
    FEHLER=1
fi

if [ "$FEHLER" -ne 0 ]; then
    echo
    echo "ERGEBNIS: AKTIVIERUNG_GESPERRT"
    echo "Mindestens eine bestehende Array-/Pool-Zuweisung ist"
    echo "nicht eindeutig oder benoetigt noch eine sichere Migration."
    exit 1
fi

#
# Erst NACH erfolgreicher vollstaendiger Assignment-Pruefung
# darf eine Baseline-Vorschau ausgegeben werden.
#
echo
echo "===== BASELINE-PREVIEW ====="

BASELINE_PREVIEW_ANZAHL=0

for NAME in "${HW_DEVICES[@]}"; do
    [ -n "${ASSIGNED_DEVICE[$NAME]+x}" ] || continue

    SERIAL="${HW_SERIAL[$NAME]}"
    SOURCE="${HW_SOURCE[$NAME]}"
    PROJECT_ID="${HW_PROJECT_ID[$NAME]}"

    case "$SOURCE" in
        ATA|NVME|USB_SAT)
            ;;
        CACHE)
            echo "STOP: CACHE darf nicht in eine persistente Baseline aufgenommen werden: /dev/$NAME"
            exit 1
            ;;
        *)
            echo "STOP: Ungueltige Baseline-Quelle '$SOURCE': /dev/$NAME"
            exit 1
            ;;
    esac

    printf 'BASELINE\t%s\t%s\t%s\n' \
        "$SERIAL" \
        "$SOURCE" \
        "$PROJECT_ID"

    BASELINE_PREVIEW_ANZAHL=$((BASELINE_PREVIEW_ANZAHL + 1))
done

[ "$BASELINE_PREVIEW_ANZAHL" -eq "$GESAMT_ZUWEISUNGEN" ] || {
    echo "STOP: Baseline-Preview deckt nicht alle gespeicherten Zuweisungen ab."
    echo "Gespeicherte Zuweisungen: $GESAMT_ZUWEISUNGEN"
    echo "Baseline-Eintraege:       $BASELINE_PREVIEW_ANZAHL"
    exit 1
}

echo
echo "Baseline-Eintraege: $BASELINE_PREVIEW_ANZAHL"
echo "BASELINE_PREVIEW_OK"

echo
echo "ERGEBNIS: AKTIVIERUNG_PREFLIGHT_OK"
echo "Alle bestehenden Array-/Pool-Zuweisungen wurden eindeutig"
echo "auf Hardware aufgeloest und sind baseline-faehig."
