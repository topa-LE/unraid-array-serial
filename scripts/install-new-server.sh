#!/bin/bash
# topa-LE Unraid Array Serial – Erstinstallation
set -euo pipefail

BASE="${ARRAY_SERIAL_SCRIPT_DIR:-/boot/config/custom/array-serial}"
BASELINE="$BASE/identity-baseline.tsv"
MODUS="${1:---preview}"

stop() {
    echo "STOP: $*" >&2
    exit 1
}

case "$MODUS" in
    --preview|--apply) ;;
    *) stop "Verwendung: $0 [--preview|--apply]" ;;
esac

[ "$(id -u)" -eq 0 ] || stop "Root erforderlich."

for datei in \
    /proc/mdstat \
    /var/local/emhttp/var.ini \
    /var/local/emhttp/disks.ini \
    /boot/config/disk.cfg \
    /boot/config/super.dat
do
    [ -r "$datei" ] && { [ "$datei" = /proc/mdstat ] || [ -s "$datei" ]; } ||
        stop "Konfiguration fehlt oder ist nicht lesbar: $datei"
done

[ -d /boot/config/pools ] &&
[ -r /boot/config/pools ] ||
    stop "Pool-Konfiguration nicht lesbar."

[ ! -e "$BASELINE" ] ||
    stop "Identity-Baseline existiert bereits."

wert() {
    local datei="$1" key="$2"
    local zeile="" ergebnis="" anzahl=0

    while IFS= read -r zeile; do
        [[ "$zeile" == "$key="* ]] || continue
        ergebnis="${zeile#*=}"
        ergebnis="${ergebnis%$'\r'}"
        ergebnis="$(printf '%s' "$ergebnis" | tr -d '\042')"
        anzahl=$((anzahl + 1))
    done < "$datei"

    [ "$anzahl" -eq 1 ] && [ -n "$ergebnis" ] || return 1
    printf '%s\n' "$ergebnis"
}

[ "$(wert /proc/mdstat mdState)" = STOPPED ] ||
    stop "MD ist nicht STOPPED."

for key in mdNumDisks mdNumMissing mdNumNew; do
    [ "$(wert /proc/mdstat "$key")" = 0 ] ||
        stop "MD-Zaehler nicht leer: $key"
done

[ "$(wert /var/local/emhttp/var.ini mdState)" = STOPPED ] ||
    stop "Unraid meldet kein gestopptes Array."

[ "$(wert /var/local/emhttp/var.ini mdNumDisks)" = 0 ] ||
    stop "Unraid meldet vorhandene Array-Disks."

# startArray ist eine Einstellung in disk.cfg.
# Entscheidend fuer die Erstinstallation bleibt der gestoppte,
# zuweisungsfreie Array-Zustand.
startarray="$(wert /boot/config/disk.cfg startArray)" ||
    stop "Persistente startArray-Einstellung nicht lesbar."

case "$startarray" in
    no|yes) ;;
    *) stop "Ungueltige startArray-Einstellung: $startarray" ;;
esac

slots=0
while IFS= read -r zeile; do
    [[ "$zeile" == *=* ]] || continue
    key="${zeile%%=*}"
    id="${zeile#*=}"

    if [[ "$key" =~ ^diskId\.[0-9]+$ ]]; then
        slots=$((slots + 1))
        [ -z "$id" ] || stop "Belegter MD-Slot: $key"
    fi
done < /proc/mdstat

[ "$slots" -gt 0 ] || stop "MD-Slots nicht nachweisbar."

# Alle persistenten und aktuellen Array-Zuweisungen ablehnen.
for konfig in /var/local/emhttp/disks.ini /boot/config/disk.cfg; do
    while IFS= read -r zeile; do
        [[ "$zeile" == *=* ]] || continue
        key="${zeile%%=*}"
        id="${zeile#*=}"
        id="${id#\"}"
        id="${id%\"}"

        case "$key" in
            idSb|diskId|diskId.*)
                [ -z "$id" ] ||
                    stop "Vorhandene Laufwerkszuweisung: $konfig / $key"
                ;;
        esac
    done < "$konfig"
done

# Keine vorhandenen Pool- oder Migrationszustaende uebernehmen.
for zustand in \
    "$BASE/md-migration-resume.state" \
    "$BASE/md-migration-transaction.state"
do
    [ ! -e "$zustand" ] ||
        stop "Vorhandener Migrationszustand: $zustand"
done

shopt -s nullglob
pools=(/boot/config/pools/*.cfg)
[ "${#pools[@]}" -eq 0 ] ||
    stop "Bestehende Pool-Konfiguration gefunden."

for datei in \
    "$BASE/serial-id.sh" \
    "$BASE/identity-baseline.sh"
do
    [ -r "$datei" ] || stop "Projektdatei fehlt: $datei"
done

bootquelle="$(findmnt -n -o SOURCE --target /boot)" ||
    stop "Bootquelle nicht ermittelbar."

bootdisk="$(lsblk -n -r -o PKNAME "$bootquelle" | head -n 1)"
[ -n "$bootdisk" ] || stop "Bootdisk nicht ermittelbar."
[ -b "/dev/$bootdisk" ] || stop "Bootdisk ungueltig."

echo "===== NEW-SERVER – $MODUS ====="
echo "Bootdisk ausgeschlossen: /dev/$bootdisk"

declare -A serien=()
declare -A ids=()
zeilen=()

for pfad in /sys/class/block/*; do
    name="${pfad##*/}"

    [[ "$name" =~ ^sd[a-z]+$ ||
       "$name" =~ ^nvme[0-9]+n[0-9]+$ ]] || continue

    [ "$name" != "$bootdisk" ] || continue
    [ -r "$pfad/dev" ] || continue

    ausgabe="$(timeout 20 /bin/bash "$BASE/serial-id.sh" "/dev/$name")" ||
        stop "Hardware-ID nicht ermittelbar: /dev/$name"

    hw=""
    source=""
    id=""

    while IFS= read -r zeile; do
        case "$zeile" in
            ID_SERIAL_SHORT=*) hw="${zeile#*=}" ;;
            IDENTITY_SOURCE=*) source="${zeile#*=}" ;;
            ID_SERIAL=*) id="${zeile#*=}" ;;
        esac
    done <<< "$ausgabe"

    case "$source" in
        ATA|NVME|USB_SAT) ;;
        *) stop "Nicht persistente Identitaetsquelle: /dev/$name ($source)" ;;
    esac

    [ -n "$hw" ] && [ -n "$id" ] ||
        stop "Unvollstaendige Hardware-ID: /dev/$name"

    [ -z "${serien[$hw]+x}" ] ||
        stop "Doppelte Hardware-Seriennummer: $hw"

    [ -z "${ids[$id]+x}" ] ||
        stop "Doppelte persistente ID: $id"

    serien["$hw"]=1
    ids["$id"]=1
    zeilen+=("$hw"$'\t'"$source"$'\t'"$id")

    echo "/dev/$name -> $id"
done

[ "${#zeilen[@]}" -gt 0 ] ||
    stop "Keine geeigneten Datenlaufwerke gefunden."

echo "Erkannte Datenlaufwerke: ${#zeilen[@]}"

if [ "$MODUS" = "--preview" ]; then
    echo "PREVIEW_OK – keine Aenderungen."
    exit 0
fi

[ -d "$BASE" ] || stop "Projektverzeichnis fehlt."

tmp="$(mktemp "$BASE/.identity-baseline.XXXXXXXX")" ||
    stop "Temporaere Baseline nicht erstellbar."

trap 'rm -f -- "$tmp"' EXIT

printf '%s\n' "${zeilen[@]}" > "$tmp"

sort -o "$tmp" "$tmp"

/bin/bash "$BASE/identity-baseline.sh" --validate "$tmp" ||
    stop "Baseline-Validierung fehlgeschlagen."

[ ! -e "$BASELINE" ] ||
    stop "Baseline wurde zwischenzeitlich angelegt."

ln "$tmp" "$BASELINE" ||
    stop "Baseline konnte nicht exklusiv angelegt werden."

echo "NEW_SERVER_BASELINE_OK"
