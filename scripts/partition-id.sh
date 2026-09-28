#!/bin/bash

# Partition Identity Resolver
#
# Ermittelt fuer eine Block-Partition dynamisch das physische
# Whole-Disk-Parent und verwendet fuer dessen Hardware-Identitaet
# ausschliesslich den gemeinsamen serial-id.sh Resolver.
#
# Keine feste Partitionsnummer.
# Keine feste Laufwerksanzahl.
# Keine Aenderung an Partitionstabelle, Dateisystem oder Daten.

set -u

SERIAL_ID="/boot/config/custom/array-serial/serial-id.sh"

DEVNODE="${1:-}"

[ -n "$DEVNODE" ] || exit 1
[ -b "$DEVNODE" ] || exit 1
[ -r "$SERIAL_ID" ] || exit 1

DEVNAME="${DEVNODE#/dev/}"

DEVTYPE="$(
    udevadm info --query=property --name="$DEVNODE" 2>/dev/null |
        awk -F= '$1=="DEVTYPE"{print $2; exit}'
)"

[ "$DEVTYPE" = "partition" ] || exit 1

PARENT="$(
    lsblk -ndo PKNAME "$DEVNODE" 2>/dev/null |
        awk 'NF {print; exit}'
)"

[ -n "$PARENT" ] || exit 1

case "$PARENT" in
    sd[a-z]*|hd[a-z]*|vd[a-z]*|nvme[0-9]*n[0-9]*)
        ;;
    *)
        exit 1
        ;;
esac

PARENT_DEV="/dev/$PARENT"

[ -b "$PARENT_DEV" ] || exit 1

IDENTITY="$(
    timeout 20 /bin/bash "$SERIAL_ID" "$PARENT_DEV" 2>/dev/null
)" || exit 1

SOURCE="$(
    printf '%s\n' "$IDENTITY" |
        awk -F= '$1=="IDENTITY_SOURCE"{print substr($0,index($0,"=")+1); exit}'
)"

SHORT="$(
    printf '%s\n' "$IDENTITY" |
        awk -F= '$1=="ID_SERIAL_SHORT"{print substr($0,index($0,"=")+1); exit}'
)"

SERIAL="$(
    printf '%s\n' "$IDENTITY" |
        awk -F= '$1=="ID_SERIAL"{print substr($0,index($0,"=")+1); exit}'
)"

[ -n "$SOURCE" ] || exit 1
[ -n "$SHORT" ] || exit 1
[ -n "$SERIAL" ] || exit 1

printf 'IDENTITY_SOURCE=%s\n' "$SOURCE"
printf 'ID_SERIAL_SHORT=%s\n' "$SHORT"
printf 'ID_SERIAL=%s\n' "$SERIAL"
printf 'ID_SERIAL_PARENT=%s\n' "$PARENT"
