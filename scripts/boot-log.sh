#!/bin/bash

set -u

LOG_BASIS="/boot/logs/array-serial"
BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unbekannt)"
ZEIT="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG="$LOG_BASIS/boot-${ZEIT}-${BOOT_ID}.log"

mkdir -p "$LOG_BASIS" || exit 1

exec >>"$LOG" 2>&1

echo "===== UNRAID ARRAY-SERIAL BOOT-LOG ====="
echo "Zeit       : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "Hostname   : $(hostname 2>/dev/null || echo unbekannt)"
echo "Boot-ID    : $BOOT_ID"
echo "Kernel     : $(uname -a)"
echo "Uptime     : $(cat /proc/uptime 2>/dev/null || true)"
echo

echo "===== KERNEL-COMMANDLINE ====="
cat /proc/cmdline 2>/dev/null || true
echo

echo "===== BOOT-KERNELLOG ====="
dmesg -T 2>/dev/null || dmesg 2>/dev/null || true
echo

echo "===== BLOCKGERAETE ====="
lsblk -b -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,MODEL,SERIAL,TRAN 2>/dev/null || true
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

    echo
    echo "--- $DEV ---"

    udevadm info --query=property --name="$DEV" 2>/dev/null |
        grep -E \
        '^(DEVNAME|DEVPATH|ID_BUS|ID_MODEL|ID_SERIAL|ID_SERIAL_SHORT|ID_VENDOR|ID_PATH|ID_PATH_TAG)=' |
        sort || true

    echo "SYSFS_DEVICE=$(readlink -f "$SYSDEV/device" 2>/dev/null || true)"
done

echo
echo "===== UNRAID VAR.INI ====="

if [ -f /var/local/emhttp/var.ini ]; then
    grep -E \
        '^(mdState|mdNumDisks|mdNumMissing|mdNumNew|fsState|csrf_token)=' \
        /var/local/emhttp/var.ini 2>/dev/null |
        sed 's/^csrf_token=.*/csrf_token="[ENTFERNT]"/' || true
else
    echo "var.ini noch nicht vorhanden."
fi

echo
echo "===== UNRAID DISKS.INI ====="

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

echo
echo "===== CUSTOM UDEV-REGELN ====="

for FILE in \
    /etc/udev/rules.d/59-array-serial.rules \
    /etc/udev/rules.d/59-topa-array-serial.rules
do
    if [ -f "$FILE" ]; then
        echo "--- $FILE ---"
        sha256sum "$FILE"
        cat "$FILE"
    fi
done

echo
echo "===== BOOT-STICK / GO ====="

if [ -f /boot/config/go ]; then
    echo "--- /boot/config/go ---"
    cat /boot/config/go
fi

echo
echo "===== PLUGIN-PAKETE ====="

if [ -d /boot/extra ]; then
    echo "--- /boot/extra ---"
    find /boot/extra -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
fi

if [ -d /boot/packages ]; then
    echo "--- /boot/packages ---"
    find /boot/packages -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort
fi

echo
echo "===== BOOT-LOG ENDE ====="
echo "Zeit: $(date '+%Y-%m-%d %H:%M:%S %z')"
