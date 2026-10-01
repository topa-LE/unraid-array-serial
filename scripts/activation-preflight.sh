#!/bin/bash
# topa-LE Unraid Array Serial
#
# Rein lesender Sicherheits-Preflight vor der persistenten Aktivierung.
#
# Aufgabe:
# - bestehende Array-Zuweisungen aus dem laufenden Unraid erfassen
# - persistente Pool-diskIds erfassen
# - fuer vorhandene Hardware die zukuenftige Projekt-ID rein lesend berechnen
# - erkennen, ob eine bereits gespeicherte Kennung geaendert werden muesste
#
# Dieses Skript:
# - installiert keine Udev-Regel
# - laedt keine Udev-Regel neu
# - fuehrt keinen Udev-Trigger aus
# - aendert keine Array-/Pool-Zuweisung
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

declare -A GESPEICHERTE_IDS=()
declare -A GESPEICHERTE_QUELLE=()

ARRAY_ZUWEISUNGEN=0
POOL_ZUWEISUNGEN=0

# Array:
# disks.ini enthaelt neben Parity/Data auch Cache/Pool und Flash.
# Fuer den Array-Vertrag werden deshalb ausschliesslich belegte
# Parity- und Data-Slots mit nichtleerer idSb uebernommen.
BLOCK=""
while IFS= read -r ZEILE || [ -n "$ZEILE" ]; do
    if [[ "$ZEILE" =~ ^\[.*\]$ ]]; then
        if [ -n "$BLOCK" ]; then
            TYPE="$(
                printf '%s\n' "$BLOCK" |
                    sed -n 's/^type="\([^"]*\)".*/\1/p' |
                    head -n 1
            )"

            ID="$(
                printf '%s\n' "$BLOCK" |
                    sed -n 's/^idSb="\([^"]*\)".*/\1/p' |
                    head -n 1
            )"

            case "$TYPE" in
                Parity|Data)
                    if [ -n "$ID" ]; then
                        if [ -n "${GESPEICHERTE_IDS[$ID]+x}" ]; then
                            echo "STOP: Gespeicherte Array-ID ist nicht eindeutig: $ID"
                            exit 1
                        fi

                        GESPEICHERTE_IDS["$ID"]=1
                        GESPEICHERTE_QUELLE["$ID"]="ARRAY"
                        ARRAY_ZUWEISUNGEN=$((ARRAY_ZUWEISUNGEN + 1))
                    fi
                    ;;
            esac
        fi

        BLOCK="$ZEILE"$'\n'
    else
        BLOCK+="$ZEILE"$'\n'
    fi
done < "$DISKS_INI"

# Letzten disks.ini-Block auswerten.
if [ -n "$BLOCK" ]; then
    TYPE="$(
        printf '%s\n' "$BLOCK" |
            sed -n 's/^type="\([^"]*\)".*/\1/p' |
            head -n 1
    )"

    ID="$(
        printf '%s\n' "$BLOCK" |
            sed -n 's/^idSb="\([^"]*\)".*/\1/p' |
            head -n 1
    )"

    case "$TYPE" in
        Parity|Data)
            if [ -n "$ID" ]; then
                if [ -n "${GESPEICHERTE_IDS[$ID]+x}" ]; then
                    echo "STOP: Gespeicherte Array-ID ist nicht eindeutig: $ID"
                    exit 1
                fi

                GESPEICHERTE_IDS["$ID"]=1
                GESPEICHERTE_QUELLE["$ID"]="ARRAY"
                ARRAY_ZUWEISUNGEN=$((ARRAY_ZUWEISUNGEN + 1))
            fi
            ;;
    esac
fi

# Pools:
# Persistente Quelle sind ausschliesslich die diskId-Eintraege
# unter /boot/config/pools/*.cfg. Runtime-Cache-Eintraege aus
# disks.ini werden hier bewusst nicht nochmals gezaehlt.
if [ -d "$POOL_DIR" ]; then
    for CFG in "$POOL_DIR"/*.cfg; do
        [ -r "$CFG" ] || continue

        while IFS= read -r ID; do
            [ -n "$ID" ] || continue

            if [ -n "${GESPEICHERTE_IDS[$ID]+x}" ]; then
                echo "STOP: Dieselbe Kennung ist gleichzeitig als Array- und Pool-ID gespeichert:"
                echo "$ID"
                exit 1
            fi

            GESPEICHERTE_IDS["$ID"]=1
            GESPEICHERTE_QUELLE["$ID"]="POOL"
            POOL_ZUWEISUNGEN=$((POOL_ZUWEISUNGEN + 1))
        done < <(
            sed -n \
                's/^diskId\(\.[0-9]\+\)\?="\([^"]\+\)".*/\2/p' \
                "$CFG"
        )
    done
fi

GESAMT_ZUWEISUNGEN=$((ARRAY_ZUWEISUNGEN + POOL_ZUWEISUNGEN))

echo "===== ARRAY SERIAL – AKTIVIERUNGS-PREFLIGHT ====="
echo
echo "Boot-Laufwerk ausgeschlossen: /dev/$BOOT_GERAET"
echo "Array-Zuweisungen:            $ARRAY_ZUWEISUNGEN"
echo "Pool-Zuweisungen:             $POOL_ZUWEISUNGEN"
echo "Gespeicherte Zuweisungen:     $GESAMT_ZUWEISUNGEN"
echo

FEHLER=0
GEPRUEFT=0
ZUORDNUNGEN=0

declare -A GESEHENE_HW_SERIALS=()

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

    KENNUNG="$(
        timeout "$TIMEOUT" \
            /bin/bash "$SERIAL_ID" "/dev/$NAME" \
            2>/dev/null
    )" || {
        echo "STOP: Sichere Kennung fuer /dev/$NAME nicht ermittelbar."
        FEHLER=1
        continue
    }

    NEUE_ID="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    HW_SERIAL="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    SOURCE="$(
        printf '%s\n' "$KENNUNG" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n 1
    )"

    [ -n "$NEUE_ID" ] &&
    [ -n "$HW_SERIAL" ] &&
    [ -n "$SOURCE" ] || {
        echo "STOP: Unvollstaendige Hardware-Identitaet fuer /dev/$NAME."
        FEHLER=1
        continue
    }

    case "$SOURCE" in
        ATA|NVME|USB_SAT|CACHE)
            ;;
        *)
            echo "STOP: Unzulaessige Identitaetsquelle fuer /dev/$NAME: $SOURCE"
            FEHLER=1
            continue
            ;;
    esac

    if [ -n "${GESEHENE_HW_SERIALS[$HW_SERIAL]+x}" ]; then
        echo "STOP: Hardware-Seriennummer ist nicht eindeutig: $HW_SERIAL"
        echo "Erstes Geraet: ${GESEHENE_HW_SERIALS[$HW_SERIAL]}"
        echo "Weiteres Geraet: /dev/$NAME"
        FEHLER=1
        continue
    fi

    GESEHENE_HW_SERIALS["$HW_SERIAL"]="/dev/$NAME"

    UDEV_ID="$(
        udevadm info --query=property --name="/dev/$NAME" 2>/dev/null |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    GEPRUEFT=$((GEPRUEFT + 1))

    echo "----- /dev/$NAME -----"
    echo "Quelle:       $SOURCE"
    echo "HW-Serial:    $HW_SERIAL"
    echo "Aktuelle ID:  ${UDEV_ID:-<leer>}"
    echo "Projekt-ID:   $NEUE_ID"

    if [ -n "$UDEV_ID" ] &&
       [ -n "${GESPEICHERTE_IDS[$UDEV_ID]+x}" ]; then

        ZUORDNUNGEN=$((ZUORDNUNGEN + 1))

        echo "Gespeichert:  ${GESPEICHERTE_QUELLE[$UDEV_ID]}"

        if [ "$UDEV_ID" != "$NEUE_ID" ]; then
            echo "Status:       MIGRATION_ERFORDERLICH"
            FEHLER=1
        else
            echo "Status:       BEREITS_SAUBER"
        fi
    elif [ -n "${GESPEICHERTE_IDS[$NEUE_ID]+x}" ]; then

        ZUORDNUNGEN=$((ZUORDNUNGEN + 1))

        echo "Gespeichert:  ${GESPEICHERTE_QUELLE[$NEUE_ID]}"
        echo "Status:       BEREITS_SAUBER"
    else
        echo "Gespeichert:  NEIN"
        echo "Status:       NICHT_ZUGEWIESEN"
    fi

    echo
done

echo "===== ZUSAMMENFASSUNG ====="
echo "Hardware geprueft:        $GEPRUEFT"
echo "Array-Zuweisungen:        $ARRAY_ZUWEISUNGEN"
echo "Pool-Zuweisungen:         $POOL_ZUWEISUNGEN"
echo "Gesamt gespeichert:       $GESAMT_ZUWEISUNGEN"
echo "Zuweisungen zugeordnet:   $ZUORDNUNGEN"

if [ "$ZUORDNUNGEN" -ne "$GESAMT_ZUWEISUNGEN" ]; then
    echo
    echo "STOP: Nicht alle gespeicherten Array-/Pool-Zuweisungen konnten"
    echo "einem vorhandenen Laufwerk eindeutig zugeordnet werden."
    echo "Zugeordnet:  $ZUORDNUNGEN"
    echo "Gespeichert: $GESAMT_ZUWEISUNGEN"
    FEHLER=1
fi

if [ "$FEHLER" -ne 0 ]; then
    echo
    echo "ERGEBNIS: AKTIVIERUNG_GESPERRT"
    echo "Bestehende Kennungen muessen vor der Boot-Aktivierung"
    echo "ueber den jeweiligen sicheren Migrationsweg behandelt werden."
    exit 1
fi

echo
echo "ERGEBNIS: AKTIVIERUNG_PREFLIGHT_OK"
echo "Keine bestehende Array-/Pool-Zuweisung muss durch die Aktivierung"
echo "ihre Kennung wechseln."


echo
echo "===== BASELINE-PREVIEW ====="

declare -A BASELINE_PREVIEW_HW=()
declare -A BASELINE_PREVIEW_ID=()

BASELINE_PREVIEW_ANZAHL=0

for SYS in /sys/class/block/*; do
    [ -e "$SYS" ] || continue

    NAME="${SYS##*/}"

    if [[ "$NAME" =~ ^sd[a-z]+$ ]]; then
        :
    elif [[ "$NAME" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
        :
    else
        continue
    fi

    [ "$NAME" != "$BOOT_GERAET" ] || continue

    DEVTYPE="$(
        udevadm info --query=property --path="$SYS" 2>/dev/null |
            sed -n 's/^DEVTYPE=//p' |
            head -n1
    )"

    [ "$DEVTYPE" = "disk" ] || continue

    GENERIERT="$(
        timeout "$TIMEOUT" \
            /bin/bash "$SERIAL_ID" "/dev/$NAME" \
            2>/dev/null
    )" || {
        echo "STOP: Baseline-Preview kann Identitaet nicht ermitteln: /dev/$NAME"
        exit 1
    }

    HW_SERIAL="$(
        printf '%s\n' "$GENERIERT" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n1
    )"

    SOURCE="$(
        printf '%s\n' "$GENERIERT" |
            sed -n 's/^IDENTITY_SOURCE=//p' |
            head -n1
    )"

    FUTURE_ID="$(
        printf '%s\n' "$GENERIERT" |
            sed -n 's/^ID_SERIAL=//p' |
            head -n1
    )"

    [ -n "$HW_SERIAL" ] &&
    [ -n "$SOURCE" ] &&
    [ -n "$FUTURE_ID" ] || {
        echo "STOP: Unvollstaendiges Baseline-Tupel: /dev/$NAME"
        exit 1
    }

    case "$SOURCE" in
        ATA|NVME|USB_SAT|CACHE)
            ;;
        *)
            echo "STOP: Ungueltige Baseline-Quelle '$SOURCE': /dev/$NAME"
            exit 1
            ;;
    esac

    # Nur bereits sauber zugeordnete Array-/Pool-IDs duerfen
    # in die Baseline aufgenommen werden.
    if [ -z "${GESPEICHERTE_IDS[$FUTURE_ID]+x}" ]; then
        continue
    fi

    [ -z "${BASELINE_PREVIEW_HW[$HW_SERIAL]+x}" ] || {
        echo "STOP: HW_SERIAL mehrfach im Baseline-Preview: $HW_SERIAL"
        exit 1
    }

    [ -z "${BASELINE_PREVIEW_ID[$FUTURE_ID]+x}" ] || {
        echo "STOP: APPROVED_ID mehrfach im Baseline-Preview: $FUTURE_ID"
        exit 1
    }

    BASELINE_PREVIEW_HW["$HW_SERIAL"]=1
    BASELINE_PREVIEW_ID["$FUTURE_ID"]=1

    printf 'BASELINE\t%s\t%s\t%s\n' \
        "$HW_SERIAL" \
        "$SOURCE" \
        "$FUTURE_ID"

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
