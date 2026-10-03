# Migration of Existing Device IDs

## Purpose

Installing the new Udev identities alone is not necessarily sufficient on an existing Unraid system.

Unraid may still have existing array or pool assignments stored under older device IDs.

In this case, the persistent Unraid assignments must be migrated to the new project ID in a controlled manner.

## Basic Rule

A required migration must never be bypassed by creating a new baseline.

The correct process is:

```text
existing Unraid assignment
        |
        v
unambiguously identify physical hardware
        |
        v
determine expected project ID
        |
        v
safe migration
        |
        v
verify persistent state
        |
        v
authorize baseline
```

## Array and Pools Are Separate

The project uses separate paths:

| Area | Main components |
|---|---|
| Array | `migrate-array-ids.sh`, `md-migration-transaction.sh` |
| Pools | `migrate-pool-ids.sh`, `pool-migration-transaction.sh` |

A pool migration must not be mixed with the MD/array migration.

## Array Migration

### Normal User Workflow

To migrate an existing array, the user does not need to invoke internal
migration scripts individually or manually edit Unraid configuration files.

On the Unraid server, run the central installer as `root` with migration mode:

~~~bash
/bin/bash /boot/config/custom/array-serial/install.sh --migrate-array
~~~

The installer performs the preparatory Phase A. Only if the run completes
successfully and ends with

~~~text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
~~~

should Unraid be rebooted normally:

~~~bash
reboot
~~~

After the reboot, Phase B is continued automatically through the persistent
resume hook. The user does not need to start Phase B manually or invoke any
internal migration scripts.

> [!IMPORTANT]
> During a prepared migration, do not manually modify `super.dat`, the
> identity baseline, the resume state, or the stored array assignments.

### Parity During Migration

The safe migration path does not mark existing parity data as valid without
verification after rebuilding the persistent array assignments.

Instead, the migration deliberately uses the safe parity synchronization
policy. After the automatic continuation, parity synchronization must be
allowed to complete.


### Background

Early investigations showed that neither simply changing the visible runtime assignment nor directly replacing an ID field in `super.dat` at the binary level is sufficient as a generally safe migration mechanism.

A controlled transaction path was therefore developed.

The complete development history is available in:

[ARRAY-ID-MIGRATION-DEVELOPMENT.md](ARRAY-ID-MIGRATION-DEVELOPMENT.md)

### Two-Phase Model

The developed array path operates in two logically separate phases.

#### Phase A

Phase A prepares the transaction.

Among other things, it:

- verifies the plan and hardware assignment,
- backs up the existing configuration,
- records hashes and manifest information,
- persistently stores the resume state required for the reboot.

After Phase A, a reboot is part of the transaction.

#### Phase B

After the reboot, Phase B may continue only if the stored transaction state completely matches the expected data.

The devices are resolved again from their hardware identities.

Only then is the new persistent array assignment built in a controlled manner.

The resume state is removed only after successful validation.

## Safety Features of the Array Transaction

The transaction uses, among other things:

- persistent backups,
- hash verification,
- plan verification,
- manifest verification,
- renewed hardware resolution after reboot,
- verification of the expected slots,
- verification of MD sizes,
- checks for missing or new drives.

The transaction is intended to stop if a discrepancy is detected.

## Verified Development Tests

### Single-Disk Test

The complete two-phase path was successfully executed on a test system with one data drive.

After another normal reboot, the new persistent assignment remained in place.

### Parity Array

An array containing:

```text
1 parity drive
7 data drives
```

was subsequently tested.

After a normal reboot, the parity drive and all seven data drives remained assigned to the expected slots using the normalized IDs.

This test confirmed persistence of the device assignment.

It must not be confused with a statement that existing parity data can automatically be considered valid after every New-Config-like operation.

In the documented test, parity reconstruction was started.

## Pool Migration

`migrate-pool-ids.sh` resolves persistent pool configurations using the pool UUID, existing partition and parent disk.

The write-capable backend path is located in:

```text
pool-migration-transaction.sh
```

The transaction path verifies the planned changes, backs up the original pool configuration files and provides a rollback path for configurations that have already been written.

It does not modify partitioning, file-system UUIDs or user data.

## Before a Production Migration

Before every production migration, the current state and existing backups must be checked.

In particular, no migration run may be started based merely on an assumption about `/dev/sdX` or `/dev/nvmeXnY`.

Hardware resolution must be unambiguous.

## After a Migration

After a successful migration, at least the following must be verified:

- stored Unraid assignments,
- expected project IDs,
- slot assignments,
- missing or new drives,
- pool configuration,
- reboot persistence.

Only a successful reboot test confirms persistent adoption of the new device identities.
