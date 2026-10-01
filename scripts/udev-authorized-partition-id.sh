#!/bin/bash
#
# Autorisierter Udev-Wrapper fuer Partitionen.
#
# Eine Partition darf Projekt-Eigenschaften nur erhalten, wenn ihr
# physisches Parent-Laufwerk durch udev-authorized-id.sh autorisiert ist.

set -euo pipefail

BASE="/boot/config/custom/array-serial"
DISK_AUTH="$BASE/udev-authorized-id.sh"
PARTITION_ID="$BASE/partition-id.sh"
TIMEOUT=20

PARTITION="${1:-}"

[ -n "$PARTITION" ] || exit 1
[ -b "$PARTITION" ] || exit 1
[ -f "$DISK_AUTH" ] || exit 1
[ -f "$PARTITION_ID" ] || exit 1

NAME="${PARTITION##*/}"

SYSDEV="$(readlink -f "/sys/class/block/$NAME" 2>/dev/null)" || exit 1
[ -n "$SYSDEV" ] || exit 1

PARENT_SYS="$(dirname "$SYSDEV")"
PARENT_NAME="${PARENT_SYS##*/}"

case "$PARENT_NAME" in
    sd[a-z]*|nvme[0-9]*n[0-9]*)
        ;;
    *)
        exit 1
        ;;
esac

PARENT="/dev/$PARENT_NAME"

[ -b "$PARENT" ] || exit 1

# Nur Autorisierung pruefen; Ausgabe des Disk-Wrappers nicht an
# das Partitionsevent weiterreichen.
timeout "$TIMEOUT" \
    /bin/bash "$DISK_AUTH" "$PARENT" \
    >/dev/null 2>&1 || exit 1

timeout "$TIMEOUT" \
    /bin/bash "$PARTITION_ID" "$PARTITION" \
    2>/dev/null
