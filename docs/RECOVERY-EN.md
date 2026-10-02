# Recovery and Error Cases

## Table of Contents

- [Basic Principle](#basic-principle)
- [Baseline Errors](#installation-stops-because-of-the-baseline)
- [Migration Required](#activation-preflight-reports-migration-required)
- [Udev Not Clean](#udev-not-clean)
- [CACHE Not Baseline-Capable](#cache-not-baseline-capable)
- [Boot Hooks](#boot-hooks)
- [Boot Logs](#boot-logs)
- [Runtime Udev Rules](#runtime-udev-rules)
- [Flash ID Missing](#flash-id-missing-after-reboot)
- [Migration Backups](#migration-backups)
- [super.dat](#superdat)
- [Before Recovery](#before-recovery)
- [After Recovery](#after-recovery)

## Basic Principle

If an error occurs, no attempt should be made to guess a device identity or Unraid assignment.

First, the current state is recorded.

Only then is it decided whether installation, migration or recovery may continue.

## Installation Stops Because of the Baseline

If `identity-baseline.sh` rejects an existing baseline, it must not be automatically deleted or regenerated.

Among other things, the following should be checked:

- TSV structure
- duplicate hardware serial numbers
- duplicate project IDs
- permitted identity source
- consistency with the expected server hardware

An existing baseline is a safety boundary, not a temporary cache file.

## Activation Preflight Reports Migration Required

If the preflight reports:

```text
MIGRATION_ERFORDERLICH
```

the stored Unraid ID does not yet match the expected project ID.

In this state, a new baseline must not be created as a shortcut.

See:

[MIGRATION-EN.md](MIGRATION-EN.md)

## Udev Not Clean

If the preflight reports:

```text
UDEV_NICHT_SAUBER
```

the reason why the current Udev ID does not match the expected project ID must first be investigated.

Possible areas to check include:

- installed runtime rules
- order of the Udev rules
- authorization wrappers
- hardware identity
- boot process

## CACHE Not Baseline-Capable

If the preflight reports:

```text
CACHE_NICHT_BASELINEFAEHIG
```

this entry must not be added to the persistent baseline.

A cache fallback is not permanent authorization of a hardware identity.

## Boot Hooks

The production boot process expects exactly one invocation of each of the following:

```text
boot-log.sh
boot-capture.sh
install-boot.sh
install-flash-id.sh
```

Duplicate or missing hooks must be resolved before a production reboot.

## Boot Logs

Persistent diagnostic information is stored under:

```text
/boot/logs/array-serial/
```

`boot-log.sh` records the early boot state.

`boot-capture.sh` creates several time-delayed snapshots during the boot phase.

The specific retention or rotation logic should be checked directly against the currently deployed script version during recovery.

## Runtime Udev Rules

After every boot, the project rules must again be present under:

```text
/etc/udev/rules.d/
```

The expected rules are:

```text
59-array-serial.rules
61-array-serial-nvme.rules
62-array-serial-partitions.rules
63-array-serial-nvme-links.rules
64-array-serial-flash.rules
```

The installation orchestrator compares the expected runtime rules with the persistent project files.

## Flash ID Missing After Reboot

If the additional Flash by-id link is missing after a reboot, the following should be checked in particular:

1. Is `install-flash-id.sh` present exactly once in `/boot/config/go`?
2. Is rule 64 present at runtime?
3. Is `/boot` provided by the expected physical device?
4. Which properties does `udevadm` report for the boot disk?
5. Are the native USB by-id links present?

The native vendor link may exist in parallel with the project link.

## Migration Backups

Migration transactions deliberately create backups and state information.

These must not be automatically cleaned up while a transaction is still active or its state is unclear.

In particular, an existing resume state must be treated as an indication of a transaction that may not yet be complete.

Transaction state must not be deleted merely because an installation or update is to be performed.

## super.dat

`super.dat` is a critical component of the persistent Unraid array configuration.

Historical development attempts showed that simply replacing an ID field directly is not a generally safe migration method.

The current array migration architecture therefore uses a controlled transaction path with backups, manifests, hash verification and validation.

`super.dat` should not be modified experimentally outside this designated transaction path.

## Before Recovery

Before any write-capable recovery steps, at least the following should be backed up or documented:

- current Unraid assignments
- relevant pool CFGs
- existing Identity Baseline
- existing migration backups
- existing resume state
- `/boot/config/go`
- current project version or Git commit

If a migration is active or its state is unclear, the existing transaction state must first be understood.

## After Recovery

Recovery is complete only after the state has been checked again following a normal reboot.

A state that appears correct only in the currently running system does not yet prove persistence.
