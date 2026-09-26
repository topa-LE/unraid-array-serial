#!/bin/bash

# topa-LE Unraid Array Serial
#
# Sichere Migration bestehender Unraid-Array-Zuweisungen auf die von
# serial-id.sh erzeugten Hardware-Kennungen.
#
# Standard:
#   nur Preflight, keinerlei Aenderung.
#
# Schreibender Modus:
#   --apply
#
# Grundprinzip:
#   gespeicherter Slot
#   -> bisherige Unraid-ID
#   -> aktuelles Blockgeraet
#   -> echte Hardware-Identitaet
#   -> neue Udev-ID
#   -> erneute eindeutige Zuordnung
#   -> offizielle Unraid-Slot-Zuweisung per emcmd
#
# Bei irgendeiner Mehrdeutigkeit wird vor dem ersten Schreibvorgang
# abgebrochen.

set -euo pipefail

MODUS="PREVIEW"

case "${1:-}" in
    "")
        ;;
    --apply)
        MODUS="APPLY"
        ;;
    *)
        echo "Verwendung: $0 [--apply]"
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "STOP: Root-Rechte erforderlich."
    exit 1
fi

VERZEICHNIS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERIAL_ID="$VERZEICHNIS/serial-id.sh"
MIGRATIONSPLAN="$VERZEICHNIS/migration-plan.tsv"
DISKS_INI="/var/local/emhttp/disks.ini"
VAR_INI="/var/local/emhttp/var.ini"
EMCMD="/usr/local/sbin/emcmd"

# Einzelne SMART-/USB-Abfragen duerfen die Migration niemals
# unbegrenzt blockieren. Bei Timeout wird sicher abgebrochen.
GERAETE_TIMEOUT=20

for DATEI in \
    "$SERIAL_ID" \
    "$VERZEICHNIS/format-disk-id.sh" \
    "$VERZEICHNIS/detect-transport.sh" \
    "$DISKS_INI" \
    "$VAR_INI"
do
    [ -r "$DATEI" ] || {
        echo "STOP: Datei nicht lesbar: $DATEI"
        exit 1
    }
done

for PROGRAMM in udevadm findmnt awk sed grep timeout; do
    command -v "$PROGRAMM" >/dev/null 2>&1 || {
        echo "STOP: Programm fehlt: $PROGRAMM"
        exit 1
    }
done

if [ "$MODUS" = "APPLY" ] && [ ! -x "$EMCMD" ]; then
    echo "STOP: emcmd fehlt oder ist nicht ausfuehrbar."
    exit 1
fi

AKTIVE_UDEV_REGEL="/etc/udev/rules.d/59-array-serial.rules"

if [ "$MODUS" = "APPLY" ]; then
    [ -r "$AKTIVE_UDEV_REGEL" ] || {
        echo "STOP: Die neue Udev-Regel ist fuer APPLY nicht aktiv:"
        echo "      $AKTIVE_UDEV_REGEL"
        echo "      Es wurde noch keine Platte umgeschaltet."
        exit 1
    }

    cmp -s "$VERZEICHNIS/59-array-serial.rules" "$AKTIVE_UDEV_REGEL" || {
        echo "STOP: Aktive Udev-Regel entspricht nicht der getesteten Projektversion."
        echo "      Es wurde noch keine Platte umgeschaltet."
        exit 1
    }
fi

wert_var_ini() {
    local NAME="$1"

    sed -n "s/^${NAME}=\"\\([^\"]*\\)\"/\\1/p" "$VAR_INI" |
        head -n 1
}

FSSTATE="$(wert_var_ini fsState)"
MDSTATE="$(wert_var_ini mdState)"
CONFIG_VALID="$(wert_var_ini configValid)"

echo "===== UNRAID ARRAY SERIAL – SICHERE ID-MIGRATION ====="
echo
echo "Modus:       $MODUS"
echo "configValid: ${CONFIG_VALID:-<leer>}"
echo "mdState:     ${MDSTATE:-<leer>}"
echo "fsState:     ${FSSTATE:-<leer>}"
echo

if [ "$FSSTATE" != "Stopped" ]; then
    echo "STOP: Dateisystemzustand ist nicht Stopped."
    exit 1
fi

case "$MDSTATE" in
    STOPPED)
        ;;
    ERROR:TOO_MANY_MISSING_DISKS)
        echo "Hinweis: Unraid meldet fehlende Array-Geraete."
        echo "Dieser Zustand ist nur fuer die kontrollierte ID-Migration zulaessig."
        echo "Die nachfolgenden Identitaetspruefungen muessen vollstaendig bestehen."
        echo
        ;;
    *)
        echo "STOP: Nicht unterstuetzter mdState: $MDSTATE"
        exit 1
        ;;
esac

if [ "$CONFIG_VALID" != "yes" ]; then
    echo "STOP: Unraid meldet configValid nicht als yes."
    exit 1
fi

if findmnt -rn |
   awk '$2 == "/mnt/user" ||
        $2 == "/mnt/user0" ||
        $2 ~ /^\/mnt\/disk[0-9]+$/ {
            gefunden=1
        }
        END { exit !gefunden }'
then
    echo "STOP: Es sind noch Array-/User-Mounts vorhanden."
    exit 1
fi

BOOT_QUELLE="$(findmnt -n -o SOURCE --target /boot 2>/dev/null || true)"
BOOT_DISK=""

if [[ "$BOOT_QUELLE" =~ ^/dev/(sd[a-z]+)[0-9]+$ ]]; then
    BOOT_DISK="${BASH_REMATCH[1]}"
fi

echo "Boot-Quelle: ${BOOT_QUELLE:-nicht ermittelt}"
echo

declare -a SLOTS=()
declare -A IDX=()
declare -A DEVICE=()
declare -A ALTE_ID=()
declare -A SUPER_ID=()
declare -A STATUS=()
declare -A NEUE_ID=()
declare -A HW_SERIAL=()
declare -A PLAN_ALTE_ID=()
declare -A PLAN_SERIAL=()
declare -A PLAN_NEUE_ID=()
declare -A PLAN_DEVICE=()

declare -A SLOT_IDX_AKTUELL=()
declare -A SLOT_DEVICE_AKTUELL=()
declare -A SLOT_ID_AKTUELL=()
declare -A SLOT_IDSB_AKTUELL=()
declare -A SLOT_STATUS_AKTUELL=()

while IFS='|' read -r SLOT SLOT_IDX SLOT_DEVICE SLOT_ID SLOT_ID_SB SLOT_STATUS; do
    [ -n "$SLOT" ] || continue

    case "$SLOT" in
        parity|parity2|parity3|disk[0-9]*)
            ;;
        *)
            continue
            ;;
    esac

    SLOT_IDX_AKTUELL["$SLOT"]="$SLOT_IDX"
    SLOT_DEVICE_AKTUELL["$SLOT"]="$SLOT_DEVICE"
    SLOT_ID_AKTUELL["$SLOT"]="$SLOT_ID"
    SLOT_IDSB_AKTUELL["$SLOT"]="$SLOT_ID_SB"
    SLOT_STATUS_AKTUELL["$SLOT"]="$SLOT_STATUS"

done < <(
    awk '
        function ausgeben() {
            if (section != "") {
                print section "|" idx "|" device "|" id "|" idSb "|" status
            }
        }

        /^\["[^"]+"\]$/ {
            ausgeben()

            section=$0
            gsub(/^\["|"\]$/, "", section)

            idx=""
            device=""
            id=""
            idSb=""
            status=""
            next
        }

        /^idx="/ {
            idx=$0
            sub(/^idx="/, "", idx)
            sub(/"$/, "", idx)
            next
        }

        /^device="/ {
            device=$0
            sub(/^device="/, "", device)
            sub(/"$/, "", device)
            next
        }

        /^id="/ {
            id=$0
            sub(/^id="/, "", id)
            sub(/"$/, "", id)
            next
        }

        /^idSb="/ {
            idSb=$0
            sub(/^idSb="/, "", idSb)
            sub(/"$/, "", idSb)
            next
        }

        /^status="/ {
            status=$0
            sub(/^status="/, "", status)
            sub(/"$/, "", status)
            next
        }

        END {
            ausgeben()
        }
    ' "$DISKS_INI"
)

plan_gegen_hardware_aufloesen() {
    local SLOT SERIAL NEU
    local SYS NAME AUSGABE IST_SERIAL IST_NEU
    local ANZAHL GEFUNDEN

    declare -A GESEHENE_PLAN_DEVICE=()

    for SLOT in "${SLOTS[@]}"; do
        SERIAL="${PLAN_SERIAL[$SLOT]}"
        NEU="${PLAN_NEUE_ID[$SLOT]}"
        ANZAHL=0
        GEFUNDEN=""

        for SYS in /sys/class/block/sd*; do
            [ -e "$SYS" ] || continue

            NAME="$(basename "$SYS")"
            [[ "$NAME" =~ ^sd[a-z]+$ ]] || continue

            if [ -n "$BOOT_DISK" ] && [ "$NAME" = "$BOOT_DISK" ]; then
                continue
            fi

            printf 'Pruefe %-8s gegen /dev/%-5s ... ' "$SLOT" "$NAME"

            set +e
            AUSGABE="$(
                timeout "$GERAETE_TIMEOUT"                     bash "$SERIAL_ID" "/dev/$NAME" 2>/dev/null
            )"
            RC=$?
            set -e

            case "$RC" in
                0)
                    echo "OK"
                    ;;
                124)
                    echo "TIMEOUT"
                    echo
                    echo "STOP: Hardware-Abfrage fuer /dev/$NAME hat nach"
                    echo "      ${GERAETE_TIMEOUT} Sekunden nicht geantwortet."
                    echo "      Migration wurde sicher abgebrochen."
                    exit 1
                    ;;
                *)
                    echo "keine sichere Kennung"
                    AUSGABE=""
                    ;;
            esac

            IST_SERIAL="$(
                printf '%s\n' "$AUSGABE" |
                    sed -n 's/^ID_SERIAL_SHORT=//p' |
                    head -n 1
            )"

            IST_NEU="$(
                printf '%s\n' "$AUSGABE" |
                    sed -n 's/^ID_SERIAL=//p' |
                    head -n 1
            )"

            if [ "$IST_SERIAL" = "$SERIAL" ] &&
               [ "$IST_NEU" = "$NEU" ]; then
                ANZAHL=$((ANZAHL + 1))
                GEFUNDEN="$NAME"
            fi
        done

        if [ "$ANZAHL" -ne 1 ]; then
            echo "STOP: Hardware fuer $SLOT ist nicht eindeutig aufloesbar."
            echo "HW-Serial: $SERIAL"
            echo "Neue ID:   $NEU"
            echo "Treffer:   $ANZAHL"
            exit 1
        fi

        if [ -n "${GESEHENE_PLAN_DEVICE[$GEFUNDEN]+x}" ]; then
            echo "STOP: /dev/$GEFUNDEN wurde mehreren Slots zugeordnet."
            exit 1
        fi

        GESEHENE_PLAN_DEVICE["$GEFUNDEN"]="$SLOT"
        PLAN_DEVICE["$SLOT"]="$GEFUNDEN"
        DEVICE["$SLOT"]="$GEFUNDEN"
    done
}

plan_laden() {
    local SLOT SLOT_IDX ALT SERIAL NEU
    local ZEILEN=0

    [ -r "$MIGRATIONSPLAN" ] || {
        echo "STOP: Migrationsplan fehlt: $MIGRATIONSPLAN"
        exit 1
    }

    while IFS=$'\t' read -r SLOT SLOT_IDX ALT SERIAL NEU EXTRA; do
        [ -n "$SLOT" ] || continue

        [ -z "${EXTRA:-}" ] || {
            echo "STOP: Ungueltige Zusatzspalte im Migrationsplan."
            exit 1
        }

        case "$SLOT" in
            parity|parity2|parity3|disk[0-9]*)
                ;;
            *)
                echo "STOP: Ungueltiger Slot im Migrationsplan: $SLOT"
                exit 1
                ;;
        esac

        [[ "$SLOT_IDX" =~ ^[0-9]+$ ]] || {
            echo "STOP: Ungueltige idx im Migrationsplan: $SLOT_IDX"
            exit 1
        }

        [ -n "$ALT" ] || {
            echo "STOP: Alte ID fehlt im Migrationsplan fuer $SLOT."
            exit 1
        }

        [ -n "$SERIAL" ] || {
            echo "STOP: Hardware-Seriennummer fehlt im Migrationsplan fuer $SLOT."
            exit 1
        }

        [ -n "$NEU" ] || {
            echo "STOP: Neue ID fehlt im Migrationsplan fuer $SLOT."
            exit 1
        }

        if [ -n "${PLAN_ALTE_ID[$SLOT]+x}" ]; then
            echo "STOP: Slot ist im Migrationsplan mehrfach vorhanden: $SLOT"
            exit 1
        fi

        SLOTS+=("$SLOT")
        IDX["$SLOT"]="$SLOT_IDX"
        ALTE_ID["$SLOT"]="$ALT"
        SUPER_ID["$SLOT"]="$ALT"
        PLAN_ALTE_ID["$SLOT"]="$ALT"
        PLAN_SERIAL["$SLOT"]="$SERIAL"
        PLAN_NEUE_ID["$SLOT"]="$NEU"
        HW_SERIAL["$SLOT"]="$SERIAL"
        NEUE_ID["$SLOT"]="$NEU"

        ZEILEN=$((ZEILEN + 1))
    done < "$MIGRATIONSPLAN"

    [ "$ZEILEN" -gt 0 ] || {
        echo "STOP: Migrationsplan ist leer."
        exit 1
    }

    plan_gegen_hardware_aufloesen
}

plan_erzeugen() {
    local TMP
    local SLOT SLOT_IDX SLOT_DEVICE SLOT_ID SLOT_IDSB SLOT_STATUS
    local DEV GENERATOR SERIAL NEU
    local UDEV_AKTUELL
    local ANZAHL=0

    declare -A GESEHENE_IDX=()
    declare -A GESEHENE_DEVICE=()
    declare -A GESEHENE_ALTE_ID=()
    declare -A GESEHENE_SERIAL=()
    declare -A GESEHENE_NEUE_ID=()

    TMP="${MIGRATIONSPLAN}.tmp.$$"
    : > "$TMP"
    chmod 600 "$TMP"

    for SLOT in "${!SLOT_IDX_AKTUELL[@]}"; do
        case "$SLOT" in
            parity|parity2|parity3|disk[0-9]*)
                ;;
            *)
                continue
                ;;
        esac

        SLOT_IDX="${SLOT_IDX_AKTUELL[$SLOT]}"
        SLOT_DEVICE="${SLOT_DEVICE_AKTUELL[$SLOT]}"
        SLOT_ID="${SLOT_ID_AKTUELL[$SLOT]}"
        SLOT_IDSB="${SLOT_IDSB_AKTUELL[$SLOT]}"
        SLOT_STATUS="${SLOT_STATUS_AKTUELL[$SLOT]}"

        # Unbelegte Parity-Slots besitzen weder device noch idSb.
        if [ -z "$SLOT_DEVICE" ] && [ -z "$SLOT_IDSB" ]; then
            continue
        fi

        [ -n "$SLOT_DEVICE" ] || {
            rm -f "$TMP"
            echo "STOP: $SLOT besitzt keine aktuelle Geraetezuordnung."
            echo "      Ein neuer Plan darf nur vor der Udev-Umschaltung erzeugt werden."
            exit 1
        }

        [[ "$SLOT_DEVICE" =~ ^sd[a-z]+$ ]] || {
            rm -f "$TMP"
            echo "STOP: $SLOT verwendet ein nicht unterstuetztes Geraet: $SLOT_DEVICE"
            exit 1
        }

        if [ -n "$BOOT_DISK" ] && [ "$SLOT_DEVICE" = "$BOOT_DISK" ]; then
            rm -f "$TMP"
            echo "STOP: Boot-Laufwerk erscheint als Array-Slot: $SLOT"
            exit 1
        fi

        [ -n "$SLOT_IDX" ] || {
            rm -f "$TMP"
            echo "STOP: idx fehlt fuer $SLOT."
            exit 1
        }

        [[ "$SLOT_IDX" =~ ^[0-9]+$ ]] || {
            rm -f "$TMP"
            echo "STOP: Ungueltige idx fuer $SLOT: $SLOT_IDX"
            exit 1
        }

        [ -n "$SLOT_IDSB" ] || {
            rm -f "$TMP"
            echo "STOP: idSb fehlt fuer $SLOT."
            exit 1
        }

        [ "$SLOT_ID" = "$SLOT_IDSB" ] || {
            rm -f "$TMP"
            echo "STOP: Vor Planerzeugung muessen id und idSb identisch sein."
            echo "Slot: $SLOT"
            echo "id:   ${SLOT_ID:-<leer>}"
            echo "idSb: $SLOT_IDSB"
            exit 1
        }

        DEV="/dev/$SLOT_DEVICE"

        [ -b "$DEV" ] || {
            rm -f "$TMP"
            echo "STOP: Blockgeraet fehlt: $DEV"
            exit 1
        }

        UDEV_AKTUELL="$(
            udevadm info --query=property --name="$DEV" 2>/dev/null |
                sed -n 's/^ID_SERIAL=//p' |
                head -n 1
        )"

        [ "$UDEV_AKTUELL" = "$SLOT_IDSB" ] || {
            rm -f "$TMP"
            echo "STOP: Udev-ID stimmt vor Planerzeugung nicht mit idSb ueberein."
            echo "Slot: $SLOT"
            echo "idSb: $SLOT_IDSB"
            echo "Udev: ${UDEV_AKTUELL:-<leer>}"
            exit 1
        }

        printf 'Ermittle %-8s auf %-10s ... ' "$SLOT" "$DEV"

        set +e
        GENERATOR="$(
            timeout "$GERAETE_TIMEOUT"                 bash "$SERIAL_ID" "$DEV" 2>/dev/null
        )"
        RC=$?
        set -e

        case "$RC" in
            0)
                echo "OK"
                ;;
            124)
                echo "TIMEOUT"
                rm -f "$TMP"
                echo
                echo "STOP: Hardware-Abfrage fuer $DEV hat nach"
                echo "      ${GERAETE_TIMEOUT} Sekunden nicht geantwortet."
                echo "      Migrationsplan wurde NICHT uebernommen."
                exit 1
                ;;
            *)
                echo "FEHLER"
                rm -f "$TMP"
                echo "STOP: Keine sichere Hardware-Kennung fuer $DEV."
                exit 1
                ;;
        esac

        SERIAL="$(
            printf '%s\n' "$GENERATOR" |
                sed -n 's/^ID_SERIAL_SHORT=//p' |
                head -n 1
        )"

        NEU="$(
            printf '%s\n' "$GENERATOR" |
                sed -n 's/^ID_SERIAL=//p' |
                head -n 1
        )"

        [ -n "$SERIAL" ] || {
            rm -f "$TMP"
            echo "STOP: Echte Hardware-Seriennummer fehlt fuer $SLOT."
            exit 1
        }

        [ -n "$NEU" ] || {
            rm -f "$TMP"
            echo "STOP: Neue ID fehlt fuer $SLOT."
            exit 1
        }

        if [ -n "${GESEHENE_IDX[$SLOT_IDX]+x}" ] ||
           [ -n "${GESEHENE_DEVICE[$SLOT_DEVICE]+x}" ] ||
           [ -n "${GESEHENE_ALTE_ID[$SLOT_IDSB]+x}" ] ||
           [ -n "${GESEHENE_SERIAL[$SERIAL]+x}" ] ||
           [ -n "${GESEHENE_NEUE_ID[$NEU]+x}" ]; then
            rm -f "$TMP"
            echo "STOP: Planerzeugung ergab eine nicht eindeutige Zuordnung."
            exit 1
        fi

        GESEHENE_IDX["$SLOT_IDX"]="$SLOT"
        GESEHENE_DEVICE["$SLOT_DEVICE"]="$SLOT"
        GESEHENE_ALTE_ID["$SLOT_IDSB"]="$SLOT"
        GESEHENE_SERIAL["$SERIAL"]="$SLOT"
        GESEHENE_NEUE_ID["$NEU"]="$SLOT"

        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$SLOT" "$SLOT_IDX" "$SLOT_IDSB" "$SERIAL" "$NEU" >> "$TMP"

        ANZAHL=$((ANZAHL + 1))
    done

    if [ "$ANZAHL" -eq 0 ]; then
        rm -f "$TMP"
        echo "STOP: Keine belegten Array-Slots fuer Planerzeugung gefunden."
        exit 1
    fi

    # Deterministische Reihenfolge nach numerischer idx.
    awk -F '\t' '{ printf "%09d\t%s\n", $2, $0 }' "$TMP" |
        sort -n |
        cut -f2- > "${TMP}.sort"

    chmod 600 "${TMP}.sort"
    mv -f "${TMP}.sort" "$MIGRATIONSPLAN"
    rm -f "$TMP"

    echo "Migrationsplan sicher erzeugt: $MIGRATIONSPLAN"
    echo "Plan-Slots: $ANZAHL"
}

if [ "$MODUS" = "APPLY" ] && [ -s "$MIGRATIONSPLAN" ]; then
    echo "===== BESTEHENDEN MIGRATIONSPLAN FUER APPLY LADEN ====="
    echo
    echo "Plan: $MIGRATIONSPLAN"
    plan_laden

elif [ "$MDSTATE" = "ERROR:TOO_MANY_MISSING_DISKS" ]; then
    echo "===== BESTEHENDEN MIGRATIONSPLAN LADEN ====="
    echo
    plan_laden

else
    echo "===== MIGRATIONSPLAN VOR UDEV-UMSCHALTUNG ERZEUGEN ====="
    echo
    plan_erzeugen

    # Den gerade geschriebenen Plan erneut einlesen und physisch aufloesen.
    SLOTS=()
    plan_laden
fi

declare -A GESEHENE_IDX=()
declare -A GESEHENE_DEVICE=()
declare -A GESEHENE_ALTE_ID=()
declare -A GESEHENE_SERIAL=()
declare -A GESEHENE_NEUE_ID=()

AENDERUNGEN=0

echo
echo "===== PREFLIGHT ====="
echo

for SLOT in "${SLOTS[@]}"; do
    DEV="/dev/${PLAN_DEVICE[$SLOT]}"

    SLOT_IDX_AUS_PLAN="${IDX[$SLOT]}"
    SLOT_IDSB_AKTUELL_WERT="${SLOT_IDSB_AKTUELL[$SLOT]:-}"
    SLOT_ID_AKTUELL_WERT="${SLOT_ID_AKTUELL[$SLOT]:-}"
    SLOT_IDX_AKTUELL_WERT="${SLOT_IDX_AKTUELL[$SLOT]:-}"
    SLOT_STATUS_AKTUELL_WERT="${SLOT_STATUS_AKTUELL[$SLOT]:-}"

    echo "------------------------------------------------------------"
    echo "Slot:       $SLOT"
    echo "idx:        $SLOT_IDX_AUS_PLAN"
    echo "Geraet:     $DEV"
    echo "Status:     ${SLOT_STATUS_AKTUELL_WERT:-<leer>}"
    echo "Alte ID:    ${PLAN_ALTE_ID[$SLOT]}"
    echo "HW-Serial:  ${PLAN_SERIAL[$SLOT]}"
    echo "Neue ID:    ${PLAN_NEUE_ID[$SLOT]}"

    [ "$SLOT_IDX_AKTUELL_WERT" = "$SLOT_IDX_AUS_PLAN" ] || {
        echo "STOP: Aktuelle idx stimmt nicht mit dem Migrationsplan ueberein."
        exit 1
    }

    if [ "$SLOT_IDSB_AKTUELL_WERT" != "${PLAN_ALTE_ID[$SLOT]}" ] &&
       [ "$SLOT_IDSB_AKTUELL_WERT" != "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "STOP: Aktuelle idSb ist weder geplante Alt-ID noch geplante Neu-ID."
        echo "Alt:  ${PLAN_ALTE_ID[$SLOT]}"
        echo "Neu:  ${PLAN_NEUE_ID[$SLOT]}"
        echo "Ist:  ${SLOT_IDSB_AKTUELL_WERT:-<leer>}"
        exit 1
    fi

    if [ -n "$SLOT_ID_AKTUELL_WERT" ] &&
       [ "$SLOT_ID_AKTUELL_WERT" != "${PLAN_ALTE_ID[$SLOT]}" ] &&
       [ "$SLOT_ID_AKTUELL_WERT" != "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "STOP: Aktuelle id enthaelt eine unerwartete dritte Kennung."
        echo "Alt:  ${PLAN_ALTE_ID[$SLOT]}"
        echo "Neu:  ${PLAN_NEUE_ID[$SLOT]}"
        echo "id:   $SLOT_ID_AKTUELL_WERT"
        exit 1
    fi

    if [ "$SLOT_IDSB_AKTUELL_WERT" = "${PLAN_NEUE_ID[$SLOT]}" ] &&
       [ -n "$SLOT_ID_AKTUELL_WERT" ] &&
       [ "$SLOT_ID_AKTUELL_WERT" != "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "STOP: idSb ist bereits neu, aber id passt nicht zur neuen Kennung."
        echo "Slot: $SLOT"
        echo "id:   $SLOT_ID_AKTUELL_WERT"
        echo "idSb: $SLOT_IDSB_AKTUELL_WERT"
        exit 1
    fi

    if [ -n "${GESEHENE_IDX[$SLOT_IDX_AUS_PLAN]+x}" ] ||
       [ -n "${GESEHENE_DEVICE[${PLAN_DEVICE[$SLOT]}]+x}" ] ||
       [ -n "${GESEHENE_ALTE_ID[${PLAN_ALTE_ID[$SLOT]}]+x}" ] ||
       [ -n "${GESEHENE_SERIAL[${PLAN_SERIAL[$SLOT]}]+x}" ] ||
       [ -n "${GESEHENE_NEUE_ID[${PLAN_NEUE_ID[$SLOT]}]+x}" ]; then
        echo "STOP: Migrationsplan ist nicht eindeutig."
        exit 1
    fi

    GESEHENE_IDX["$SLOT_IDX_AUS_PLAN"]="$SLOT"
    GESEHENE_DEVICE["${PLAN_DEVICE[$SLOT]}"]="$SLOT"
    GESEHENE_ALTE_ID["${PLAN_ALTE_ID[$SLOT]}"]="$SLOT"
    GESEHENE_SERIAL["${PLAN_SERIAL[$SLOT]}"]="$SLOT"
    GESEHENE_NEUE_ID["${PLAN_NEUE_ID[$SLOT]}"]="$SLOT"

    UDEV_AKTUELL="$(
        udevadm info --query=property --name="$DEV" 2>/dev/null |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    echo "Udev aktuell: ${UDEV_AKTUELL:-<leer>}"
    echo "Ermittle echte Hardware-Seriennummer fuer $DEV ..."

    GENERATOR_AUSGABE="$(
        timeout "$GERAETE_TIMEOUT" \
            /bin/bash "$SERIAL_ID" "$DEV" 2>/dev/null
    )"
    GENERATOR_RC=$?

    if [ "$GENERATOR_RC" -eq 124 ]; then
        echo "STOP: Hardware-Ermittlung fuer $DEV hat Timeout erreicht."
        exit 1
    fi

    if [ "$GENERATOR_RC" -ne 0 ]; then
        echo "STOP: Hardware-Ermittlung fuer $DEV ist fehlgeschlagen."
        exit 1
    fi

    UDEV_SHORT="$(
        printf '%s\n' "$GENERATOR_AUSGABE" |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    echo "HW-Serial:    ${UDEV_SHORT:-<leer>}"

    [ "$UDEV_SHORT" = "${PLAN_SERIAL[$SLOT]}" ] || {
        echo "STOP: Aktuelle Hardware-Seriennummer stimmt nicht mit dem Plan ueberein."
        echo "Erwartet: ${PLAN_SERIAL[$SLOT]}"
        echo "Ist:      ${UDEV_SHORT:-<leer>}"
        exit 1
    }

    if [ "$UDEV_AKTUELL" != "${PLAN_ALTE_ID[$SLOT]}" ] &&
       [ "$UDEV_AKTUELL" != "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "STOP: Aktuelle Udev-ID ist weder Alt-ID noch geplante Neu-ID."
        echo "Alt:  ${PLAN_ALTE_ID[$SLOT]}"
        echo "Neu:  ${PLAN_NEUE_ID[$SLOT]}"
        echo "Udev: ${UDEV_AKTUELL:-<leer>}"
        exit 1
    fi

    if [ "${PLAN_ALTE_ID[$SLOT]}" = "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "Plan:       keine Aenderung"
    elif [ "$SLOT_IDSB_AKTUELL_WERT" = "${PLAN_NEUE_ID[$SLOT]}" ]; then
        echo "Plan:       bereits migriert"
    else
        echo "Plan:       Kennung migrieren"
        AENDERUNGEN=$((AENDERUNGEN + 1))
    fi

    echo
done

echo "===== PREFLIGHT-ERGEBNIS ====="
echo "Belegte gepruefte Array-Slots: ${#SLOTS[@]}"
echo "Geplante ID-Aenderungen:       $AENDERUNGEN"
echo

if [ "$MODUS" = "PREVIEW" ]; then
    echo "ERGEBNIS: OK"
    echo "Alle Zuordnungen sind eindeutig."
    echo "Keine Udev-ID und keine Unraid-Slot-Zuweisung wurde veraendert."

    if [ "$MDSTATE" = "STOPPED" ]; then
        echo "Hinweis: Der Migrationsplan wurde als Vorbereitung persistent gespeichert:"
        echo "         $MIGRATIONSPLAN"
    else
        echo "Der bereits vorhandene Migrationsplan wurde nur gelesen."
    fi

    exit 0
fi

if [ "$AENDERUNGEN" -eq 0 ]; then
    echo "ERGEBNIS: OK"
    echo "Keine Migration erforderlich."
    exit 0
fi

echo "===== APPLY – SLOTWEISE UDEV- UND UNRAID-MIGRATION ====="
echo

# Ab jetzt wird jeder Slot einzeln vollstaendig migriert:
#
#   1. physisches Geraet aus dem vorab verifizierten Plan verwenden
#   2. nur dieses Geraet per Udev neu erkennen
#   3. neue Udev-ID exakt pruefen
#   4. denselben Unraid-Slot unmittelbar auf diese neue ID setzen
#   5. Laufzeitzustand dieses Slots pruefen
#
# Erst danach wird der naechste Slot angefasst.

for SLOT in "${SLOTS[@]}"; do
    ALT="${PLAN_ALTE_ID[$SLOT]}"
    NEU="${PLAN_NEUE_ID[$SLOT]}"
    NAME="${PLAN_DEVICE[$SLOT]}"
    SLOT_IDX="${IDX[$SLOT]}"
    DEV="/dev/$NAME"

    echo "------------------------------------------------------------"
    echo "Migriere:   $SLOT"
    echo "idx:        $SLOT_IDX"
    echo "Geraet:     $DEV"
    echo "Alt:        $ALT"
    echo "Neu:        $NEU"

    if [ "$ALT" = "$NEU" ]; then
        echo "Status:     keine ID-Aenderung erforderlich"
        echo
        continue
    fi

    echo
    echo "Udev-Neuerkennung fuer $DEV ..."

    udevadm trigger \
        --action=add \
        --sysname-match="$NAME" \
        --subsystem-match=block

    udevadm settle

    UDEV_NEU="$(
        udevadm info --query=property --name="$DEV" 2>/dev/null |
            sed -n 's/^ID_SERIAL=//p' |
            head -n 1
    )"

    UDEV_SHORT="$(
        udevadm info --query=property --name="$DEV" 2>/dev/null |
            sed -n 's/^ID_SERIAL_SHORT=//p' |
            head -n 1
    )"

    echo "Udev-ID:    ${UDEV_NEU:-<leer>}"
    echo "HW-Serial:  ${UDEV_SHORT:-<leer>}"

    if [ "$UDEV_SHORT" != "${PLAN_SERIAL[$SLOT]}" ]; then
        echo "STOP: Hardware-Seriennummer hat sich beim Udev-Wechsel geaendert."
        echo "Erwartet: ${PLAN_SERIAL[$SLOT]}"
        echo "Ist:      ${UDEV_SHORT:-<leer>}"
        echo "Array NICHT starten."
        exit 1
    fi

    if [ "$UDEV_NEU" != "$NEU" ]; then
        echo "STOP: Neue Udev-ID stimmt nicht mit dem Migrationsplan ueberein."
        echo "Erwartet: $NEU"
        echo "Ist:      ${UDEV_NEU:-<leer>}"
        echo "Array NICHT starten."
        exit 1
    fi

    echo
    echo "Setze Unraid-Slot $SLOT / idx $SLOT_IDX auf neue ID ..."

    "$EMCMD" "changeDevice=apply&slotId.${SLOT_IDX}=${NEU}"

    sleep 1

    IST_ID="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^id="/ {
                wert=$0
                sub(/^id="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_IDSB="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^idSb="/ {
                wert=$0
                sub(/^idSb="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_DEVICE="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^device="/ {
                wert=$0
                sub(/^device="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_STATUS="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^status="/ {
                wert=$0
                sub(/^status="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    echo "Slot-ID:    ${IST_ID:-<leer>}"
    echo "Slot-idSb:  ${IST_IDSB:-<leer>}"
    echo "Slot-Dev:   ${IST_DEVICE:-<leer>}"
    echo "Slotstatus: ${IST_STATUS:-<leer>}"

    if [ "$IST_ID" != "$NEU" ] ||
       [ "$IST_IDSB" != "$NEU" ] ||
       [ -z "$IST_DEVICE" ] ||
       [ "$IST_STATUS" != "DISK_OK" ]; then

        echo
        echo "STOP: $SLOT wurde nach der ID-Aenderung nicht sauber neu zugeordnet."
        echo "Keine weitere Platte wird migriert."
        echo "Array NICHT starten."
        exit 1
    fi

    echo "Status:     $SLOT erfolgreich migriert"
    echo
done

echo "===== APPLY – UNRAID-SLOT-ZUWEISUNGEN NACHPRUEFEN ====="
echo

FEHLER=0

for SLOT in "${SLOTS[@]}"; do
    ERWARTET="${NEUE_ID[$SLOT]}"

    IST_ID="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^id="/ {
                wert=$0
                sub(/^id="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_IDSB="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^idSb="/ {
                wert=$0
                sub(/^idSb="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_DEVICE="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^device="/ {
                wert=$0
                sub(/^device="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    IST_STATUS="$(
        awk -v ziel="$SLOT" '
            $0 == "[\"" ziel "\"]" {
                drin=1
                next
            }

            drin && /^\["[^"]+"\]$/ {
                exit
            }

            drin && /^status="/ {
                wert=$0
                sub(/^status="/, "", wert)
                sub(/"$/, "", wert)
                print wert
                exit
            }
        ' "$DISKS_INI"
    )"

    printf '%-10s device=%-6s status=%-20s\n' \
        "$SLOT" "${IST_DEVICE:-<leer>}" "${IST_STATUS:-<leer>}"
    printf '%-10s id=%s\n' "" "${IST_ID:-<leer>}"
    printf '%-10s idSb=%s\n' "" "${IST_IDSB:-<leer>}"

    if [ "$IST_ID" != "$ERWARTET" ] ||
       [ "$IST_IDSB" != "$ERWARTET" ] ||
       [ -z "$IST_DEVICE" ] ||
       [ "$IST_STATUS" != "DISK_OK" ]; then
        FEHLER=1
    fi
done

echo

MDSTATE_NACH="$(wert_var_ini mdState)"
MDNUMMISSING_NACH="$(wert_var_ini mdNumMissing)"
MDNUMNEW_NACH="$(wert_var_ini mdNumNew)"

echo "mdState:      ${MDSTATE_NACH:-<leer>}"
echo "mdNumMissing: ${MDNUMMISSING_NACH:-<leer>}"
echo "mdNumNew:     ${MDNUMNEW_NACH:-<leer>}"
echo

if [ "$FEHLER" -ne 0 ] ||
   [ "$MDSTATE_NACH" != "STOPPED" ] ||
   [ "$MDNUMMISSING_NACH" != "0" ] ||
   [ "$MDNUMNEW_NACH" != "0" ]; then

    echo "STOP: Die neue Slot-Zuordnung ist noch nicht vollstaendig gruен."
    echo "Array NICHT starten."
    exit 1
fi

echo "ERGEBNIS: OK"
echo "Alle migrierten Array-Slots sind mit den neuen IDs eindeutig zugeordnet."
echo "Keine Array-Platte fehlt und keine Platte wird als neu gemeldet."
echo "Array wurde NICHT gestartet."
