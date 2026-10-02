# Flash ID

## Table of Contents

- [Purpose](#purpose)
- [Components](#components)
- [Determining the Boot Device](#determining-the-boot-device)
- [Identity](#identity)
- [Existing Links](#existing-links)
- [What Is Not Modified](#what-is-not-modified)
- [Persistence](#persistence)
- [Verified Reboot Test](#verified-reboot-test)
- [Separation from the Identity Baseline](#separation-from-the-identity-baseline)

## Purpose

The Unraid boot device requires different handling from array, pool and cache drives.

It is therefore not included in the normal Identity Baseline.

The Flash path is technically isolated.

## Components

| File | Purpose |
|---|---|
| `flash-id.sh` | determines and normalizes the identity of the physical boot device |
| `install-flash-id.sh` | installs rule 64 and initializes the boot disk and partitions |
| `64-array-serial-flash.rules` | Udev rule for the physical `/boot` device |

## Determining the Boot Device

The installation first determines which block device provides `/boot`.

This means that no fixed assumption such as `/dev/sda` or `/dev/sdb` is required.

## Identity

The Flash path generates, among other things:

```text
IDENTITY_SOURCE=FLASH
ID_SERIAL_SHORT=<Hardware-ID>
ID_SERIAL=<normalized Flash ID>
```

An additional stable link is created:

```text
/dev/disk/by-id/usb-<ID_SERIAL>
```

The boot partition receives a corresponding partition link.

A neutral example could therefore look like this:

```text
ID_SERIAL=USB-BOOT-FLASH-EXAMPLE123456

/dev/disk/by-id/usb-USB-BOOT-FLASH-EXAMPLE123456
/dev/disk/by-id/usb-USB-BOOT-FLASH-EXAMPLE123456-part1
```

These values are documentation examples and do not originate from real test hardware.

## Existing Links

The native systemd/Udev link of the USB device remains in place for compatibility.

The project adds an additional stable link.

The existing vendor link is not intentionally removed.

In particular, the additional link does **not** mean that the Linux device name such as `/dev/sdb` is physically renamed.

## What Is Not Modified

The Flash-ID path does not modify:

- the file system of the boot device
- the volume label
- UUID
- PARTUUID
- the physical hardware serial number
- Unraid license data

## Persistence

Because `/etc/udev/rules.d/` is part of the Unraid runtime system, rule 64 must be installed again on every boot.

Therefore:

```text
install-flash-id.sh
```

is integrated persistently into `/boot/config/go`.

## Verified Reboot Test

On the tested Unraid 7.3.2 reference system, a normalized Flash ID with an additional project by-id link was successfully created before the reboot.

After a complete normal reboot, both the project link for the boot disk and the corresponding partition link were present again.

The native vendor link remained present in parallel.

This practically verified that the additional project link is recreated by the persistent boot path after a restart.

For privacy and documentation reasons, the real hardware and serial numbers of the reference system are not published here.

## Separation from the Identity Baseline

The boot device is not an array or pool disk.

Therefore:

```text
Data drives  -> Identity Baseline
Boot device  -> separate Flash-ID path
```

This separation is intentional.
