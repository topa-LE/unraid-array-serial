# Architecture

## Table of Contents

- [Overview](#overview)
- [Core Principle](#core-principle)
- [Identity Resolver](#identity-resolver)
- [Identity Tuple](#identity-tuple)
- [Identity Baseline](#identity-baseline)
- [Authorization Before Udev](#authorization-before-udev)
- [Activation Preflight](#activation-preflight)
- [Boot Integration](#boot-integration)
- [Boot Diagnostics](#boot-diagnostics)
- [Installation Orchestrator](#installation-orchestrator)
- [Array Migration](#array-migration)
- [Pool Migration](#pool-migration)
- [Flash ID](#flash-id)

## Overview

Unraid Array Serial consists of several deliberately separated layers.

```text
Physical drive
        |
        v
Hardware detection
        |
        v
serial-id.sh
        |
        v
stable project ID
        |
        v
Identity Baseline
        |
        v
Authorization wrappers
        |
        v
Udev
        |
        v
Unraid
```

The Unraid boot device follows a separate path:

```text
physical /boot device
        |
        v
flash-id.sh
        |
        v
64-array-serial-flash.rules
        |
        v
additional stable USB by-id link
```

## Core Principle

The architecture separates four things from each other:

| Layer | Neutral example | Persistence |
|---|---|---|
| Linux device name | `/dev/sdc` | not guaranteed |
| Hardware serial number | `EXAMPLE123456` | hardware characteristic |
| Project ID | `VENDOR-MODEL-EXAMPLE123456` | reproducible |
| Unraid assignment | stored array/pool ID | persistent |

The examples in this documentation are deliberately generic and do not correspond to any real test hardware.

Linux device names must never be considered permanent identities.

## Identity Resolver

`serial-id.sh` is the central resolver for supported data drives.

It uses additional helper components:

- `detect-transport.sh`
- `format-disk-id.sh`
- `resolve-cached-id.sh`

The detected identity is described, among other things, through the following properties:

```text
ID_SERIAL_SHORT
ID_SERIAL
IDENTITY_SOURCE
```

## Identity Tuple

`identity-tuple.sh` provides the identity in a form suitable for additional safety checks.

The tuple logically consists of:

```text
Hardware serial number
Identity source
Project ID
```

Together, these three values form the basis of the server-specific Identity Baseline.

## Identity Baseline

The persistent baseline is stored by default at:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

Each line contains exactly three tab-separated fields:

```text
HW_SERIAL    SOURCE    APPROVED_ID
```

The baseline is not a discovery cache.

It is an explicit server-specific authorization list.

An existing baseline is validated by the installation orchestrator but is not automatically replaced by a newly detected baseline.

## Authorization Before Udev

The production Udev rules use authorization wrappers:

```text
udev-authorized-id.sh
udev-authorized-partition-id.sh
```

These wrappers determine the current identity and compare it with the baseline.

Project properties are output to Udev only when there is an exact authorized match.

```text
Hardware
   |
   v
Determine identity
   |
   v
Check baseline
   |
   +---- not authorized ---> do not output project ID
   |
   v
Output Udev properties
```

This means that the mere technical ability to generate an ID is not sufficient for persistent authorization.

## Activation Preflight

`activation-preflight.sh` checks existing array and pool assignments against the currently connected hardware.

Among other things, it evaluates:

```text
/var/local/emhttp/disks.ini
/var/local/emhttp/var.ini
/boot/config/pools/*.cfg
```

The boot device is excluded from the normal data-drive path.

The preflight must be able to unambiguously map stored assignments to the physical hardware.

Possible results include:

```text
BEREITS_SAUBER
MIGRATION_ERFORDERLICH
UDEV_NICHT_SAUBER
CACHE_NICHT_BASELINEFAEHIG
```

Only a completely clean state may lead to initial baseline creation.

A system without stored array or pool assignments provides the preflight with no production assignment basis. A completely unconfigured new installation must therefore not be confused with a system that already has assignments but does not yet have a baseline.

## Boot Integration

Unraid rebuilds significant parts of its runtime system on every boot.

The runtime Udev rules must therefore be installed again on every startup.

Persistent project source:

```text
/boot/config/custom/array-serial/
```

Runtime rules:

```text
/etc/udev/rules.d/
```

`enable-boot.sh` configures the core hooks in `/boot/config/go`.

The central orchestrator `install.sh` first checks whether the core hooks are already present unambiguously.

If `boot-log.sh`, `boot-capture.sh` and `install-boot.sh` are each present exactly once, `enable-boot.sh` does not need to be executed again.

The separate persistent Flash hook is also checked by the orchestrator.

## Boot Diagnostics

Two components capture the early boot state:

```text
boot-log.sh
boot-capture.sh
```

Persistent diagnostic information is stored under:

```text
/boot/logs/array-serial/
```

`boot-capture.sh` creates several time-delayed snapshots during the boot phase.

This makes it possible to trace block devices, Udev properties and the Unraid state during startup.

## Installation Orchestrator

`scripts/install.sh` coordinates the installation or update of the project files that have already been provided on the target server.

The process includes:

1. checking required project files,
2. checking shell syntax,
3. validating an existing baseline or creating it once after a successful preflight,
4. checking core boot hooks,
5. checking the Flash boot hook,
6. installing or checking runtime Udev rules,
7. initializing baseline-authorized drives,
8. activating the Flash ID,
9. performing the final verification.

An existing baseline is not automatically replaced.

`install.sh` is not a repository downloader or Git synchronization mechanism. The project files must already be completely present in the persistent project directory before it is invoked.

## Array Migration

Migration of existing array IDs is separate from the normal installation path.

The central components are:

```text
migrate-array-ids.sh
md-migration-transaction.sh
```

The developed safe path operates in multiple phases and maintains a persistent resume state between phases.

The array path was developed and verified through real two-phase and reboot tests. A successful slot-persistence test must not be confused with a blanket statement about the validity of existing parity data.

Details:

[MIGRATION-EN.md](MIGRATION-EN.md)

## Pool Migration

Pools have their own migration path:

```text
migrate-pool-ids.sh
pool-migration-transaction.sh
```

Array and pool migration are deliberately handled separately.

The pool transaction path backs up the affected configuration files and provides a rollback path for configurations that have already been written.

## Flash ID

The Unraid boot device is not part of the normal data-drive baseline.

Resolver:

```text
flash-id.sh
```

Installation:

```text
install-flash-id.sh
```

Udev rule:

```text
64-array-serial-flash.rules
```

The Flash path adds a stable project link without intentionally removing the native vendor link.

Details:

[FLASH-ID-EN.md](FLASH-ID-EN.md)
