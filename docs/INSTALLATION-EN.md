# Installation and Update

## Table of Contents

- [Purpose](#purpose)
- [Prerequisites](#prerequisites)
- [Repository as Source](#repository-as-source)
- [Initial Installation](#initial-installation)
- [Orchestrator Process](#orchestrator-process)
- [Reboot](#reboot)
- [Update](#updating-an-already-configured-system)
- [Important Boundary](#important-boundary)
- [Unconfigured New System](#unconfigured-new-system)
- [Successful Reference Run](#successful-reference-run)

## Purpose

This document describes the installation or update of Unraid Array Serial on a target system.

The GitHub bootstrap automatically provides the repository files. For manual installation, the files must already be completely present under the following directory before the installation orchestrator is invoked:

```text
/boot/config/custom/array-serial/
```

## Prerequisites

Before installation, at least the following conditions should be met:

- The target system is running an intended and verified Unraid version.
- Array and pool assignments are known.
- The project files originate from a controlled repository state.
- The administrator has root access.
- A current backup exists before production migrations.
- Existing device assignments are not changed manually.

Reference tests with existing array/pool assignments and reboot were performed on **Unraid 7.3.2**. A complete GitHub initial installation on a new server with seven data drives was successfully completed on **Unraid 7.3.3**; reboot verification is still pending.

## Repository as Source

The project files should originate from the repository.

One target server should not be used as the source for another target server.

```text
Development/build system
        |
        v
Git repository
        |
        v
Target server
```

> [!IMPORTANT]
> The `unraid-orchestrator.sh` does not synchronize or clone the repository itself. The GitHub bootstrap provides the project files before starting the orchestrator.

## Initial Installation

### Direct Installation from GitHub

Run on the Unraid server as `root`:

~~~bash
curl -fsSL https://raw.githubusercontent.com/topa-LE/unraid-array-serial/main/scripts/bootstrap.sh | bash
~~~

The bootstrap downloads the repository, checks the shell syntax,
installs the project files under
`/boot/config/custom/array-serial/` and starts the orchestrator.

This method is intended for both initial installation and updates.
Existing array and pool assignments remain subject to the
orchestrator's safety and migration checks.

### Manual Orchestrator Invocation

As an alternative to the GitHub bootstrap, after manually providing the project files, run the following on the target server as `root`:

```bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh
```

The orchestrator performs the checks in a defined sequence.

## Orchestrator Process

### 1. Project Files

First, the installer checks whether the scripts and Udev rules required for installation are present.

If a required file is missing, the installation is aborted.

### 2. Shell Syntax

The central shell scripts are syntactically checked with Bash.

Installation does not continue if a syntax error is detected.

### 3. Server Identity and Baseline

If the following file already exists:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

it is validated.

An existing baseline is not automatically replaced.

If no baseline exists yet, the orchestrator invokes the Activation Preflight and uses its validated baseline writer.

A new baseline may be written only if the stored array and pool assignments are unambiguous, already clean and baseline-capable.

> [!IMPORTANT]
> If a baseline already exists, `unraid-orchestrator.sh` validates the baseline itself. In this branch, the orchestrator does not automatically rerun the complete assignment preflight against the current hardware configuration. A hardware or assignment change must therefore not be considered “confirmed” merely because the installer has been run again.

### 4. Persistent Core Boot Process

The following are checked:

```text
boot-log.sh
boot-capture.sh
install-boot.sh
```

If these hooks are already present exactly once each, the existing core boot process is retained.

Otherwise, `enable-boot.sh` is used.

Duplicate or contradictory hooks are not silently accepted.

### 5. Flash Boot Persistence

The installer additionally checks whether:

```text
install-flash-id.sh
```

is present exactly once in the persistent boot process.

The Flash hook is integrated before the Unraid Management Utility starts.

### 6. Array/Pool Udev

`install-boot.sh` installs or updates the runtime rules:

```text
59-array-serial.rules
61-array-serial-nvme.rules
62-array-serial-partitions.rules
63-array-serial-nvme-links.rules
```

Only baseline-authorized devices are then initialized.

The physical boot device is excluded from this normal drive path.

### 7. Flash ID

`install-flash-id.sh` installs:

```text
64-array-serial-flash.rules
```

and initializes only the physical drive on which `/boot` resides.

### 8. Final Verification

At the end of the process, the following are checked, among other things:

- Identity Baseline
- runtime Udev rules
- persistent boot hooks
- Flash-ID runtime state
- Flash-ID boot persistence

A successful installation run ends with:

```text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
```

## Reboot

The system should be rebooted normally only after the installation has completed successfully.

After the reboot, at least the following must be verified:

- The host is reachable again.
- Array-Serial boot hooks are still present exactly once each.
- Runtime Udev rules were installed again.
- The Identity Baseline is still valid.
- The Flash by-id link was recreated.
- Array and pool assignments match the expected state.
- The array can be started normally.

## Updating an Already Configured System

For an update, the current repository files are again provided completely under:

```text
/boot/config/custom/array-serial/
```

The same orchestrator is then executed again:

```bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh
```

The orchestrator is designed for repeated execution.

An existing valid baseline is not automatically replaced.

Core boot hooks that are already correctly present are not rebuilt unnecessarily.

> [!NOTE]
> The orchestrator is not a general-purpose file synchronization tool and does not automatically remove every file that may remain from older development states. Providing the repository state and performing the installation are separate tasks.

## Important Boundary

`unraid-orchestrator.sh` is not a substitute for a required array or pool ID migration.

If the Activation Preflight reports:

```text
MIGRATION_ERFORDERLICH
```

the designated array migration path must be used first.

On the Unraid server as `root`:

~~~bash
/bin/bash /boot/config/custom/array-serial/unraid-orchestrator.sh --migrate-array
~~~

Only if this run completes successfully and reports

~~~text
===== INSTALLATION ERFOLGREICH =====
BEREIT_FUER_REBOOT
~~~

should Unraid be rebooted normally:

~~~bash
reboot
~~~

After the reboot, Phase B is continued automatically through the persistent
resume hook. Internal migration scripts do not need to be invoked manually.

The safe migration path then uses parity synchronization and does not mark
existing parity data as valid without verification.

A new baseline must not be used to bypass a stored Unraid assignment that has not yet been migrated.

See:

[MIGRATION-EN.md](MIGRATION-EN.md)

## Unconfigured New System

A “new server” can refer to two different states:

1. Unraid already has stored array/pool assignments but does not yet have an Array-Serial baseline.
2. The system is completely unconfigured and does not yet have stored array/pool assignments.

The Activation Preflight requires stored assignments as the basis for its safety check.

A completely unconfigured new server without stored array or pool assignments is handled by the dedicated new-server installation path. After successful device verification, this path can create the server-specific Identity Baseline automatically. This procedure was successfully tested on Unraid 7.3.3.

For existing array or pool configurations, stored assignments must be verified unambiguously before controlled migration. For completely unconfigured new servers, the dedicated new-server installation path applies instead.

## Successful Reference Run

The current orchestrator was fully executed on an Unraid 7.3.2 system.

The test included:

- an existing array
- pools
- NVMe
- USB-SATA
- server-specific baseline
- persistent boot process
- separate Flash-ID path
- complete reboot

After the reboot, the project hooks were still present, the baseline remained valid and unchanged, and the additional Flash by-id link was present again.

The array could subsequently be started normally.
