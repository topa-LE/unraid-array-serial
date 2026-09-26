#!/bin/bash

set -u

LOG_BASIS="/boot/logs/array-serial"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unbekannt)"
STARTZEIT="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="$LOG_BASIS/capture-${STARTZEIT}-${BOOT_ID}.log"

mkdir -p "$LOG_BASIS" || exit 1

exec >>"$LOG" 2>&1

snapshot()
{
    LABEL="$1"

    echo
    echo "================================================================"
    echo "SNAPSHOT: $LABEL"
    echo "Zeit    : $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Uptime  : $(cat /proc/uptime 2>/dev/null || true)"
    echo "================================================================"

    echo
    echo "===== BLOCKGERAETE ====="

    lsblk -b \
        -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN \
        2>/dev/null || true

    echo
    echo "===== DISK-IDENTITAETEN ====="

    for SYSDEV in /sys/class/block/sd*; do
        [ -e "$SYSDEV" ] || continue

        NAME="$(basename "$SYSDEV")"

        case "$NAME" in
            *[0-9])
                continue
                ;;
        esac

        DEV="/dev/$NAME"

        echo "--- $DEV ---"

        udevadm info --query=property --name="$DEV" 2>/dev/null |
            grep -E \
            '^(DEVNAME|ID_BUS|ID_MODEL|ID_SERIAL|ID_SERIAL_SHORT|ID_PATH)=' |
            sort || true
    done

    echo
    echo "===== UNRAID ARRAY-ZUSTAND ====="

    if [ -f /var/local/emhttp/var.ini ]; then
        grep -E \
            '^(mdState|mdNumDisks|mdNumMissing|mdNumNew|fsState)=' \
            /var/local/emhttp/var.ini 2>/dev/null || true
    else
        echo "var.ini noch nicht vorhanden."
    fi

    echo
    echo "===== UNRAID SLOTS ====="

    if [ -f /var/local/emhttp/disks.ini ]; then
        awk '
            /^\["(parity|parity2|disk[0-9]+)"\]$/ {
                aktiv=1
                print
                next
            }

            /^\[/ {
                aktiv=0
            }

            aktiv && /^(idx|device|id|status|idSb|deviceSb|state|size)=/ {
                print
            }
        ' /var/local/emhttp/disks.ini
    else
        echo "disks.ini noch nicht vorhanden."
    fi

    echo
    echo "===== DEVS.INI ====="

    if [ -s /var/local/emhttp/devs.ini ]; then
        cat /var/local/emhttp/devs.ini
    else
        echo "devs.ini leer oder noch nicht vorhanden."
    fi
}

echo "===== UNRAID ARRAY-SERIAL BOOT-CAPTURE ====="
echo "Hostname : $(hostname 2>/dev/null || echo unbekannt)"
echo "Boot-ID  : $BOOT_ID"
echo "Start    : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo

snapshot "START"

sleep 5
snapshot "+5 SEKUNDEN"

sleep 10
snapshot "+15 SEKUNDEN"

sleep 15
snapshot "+30 SEKUNDEN"

sleep 30
snapshot "+60 SEKUNDEN"

sleep 60
snapshot "+120 SEKUNDEN"

echo
echo "===== KERNELLOG DES BOOTS ====="

dmesg -T 2>/dev/null || dmesg 2>/dev/null || true

echo
echo "===== CAPTURE ABGESCHLOSSEN ====="
echo "Ende: $(date '+%Y-%m-%d %H:%M:%S %z')"

# Nur die letzten 10 Capture-Logs behalten.
ls -1t "$LOG_BASIS"/capture-*.log 2>/dev/null |
    awk 'NR > 10' |
    while read -r ALT; do
        rm -f -- "$ALT"
    done
