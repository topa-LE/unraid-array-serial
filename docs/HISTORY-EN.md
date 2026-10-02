# Project History

## Overview

Unraid Array Serial was developed step by step from the investigation of how Unraid identifies drives and how readable, stable device identifiers can be generated without relying on changing Linux device names.

Development was iterative and included real hardware, Udev, array, migration and reboot tests.

## Development Phases

### Phase 1 – Diagnostics and Identity Analysis

Initially, read-only tools were created to compare hardware, Udev and SMART information.

| Commit | Content |
|---|---|
| `9cb6fe6` | Unraid 7.3.2 reference for serial identification |
| `382d71a` | read-only disk identification diagnostics |
| `7b4821a` | hardware and Udev serial comparison |
| `96b3028` | reversible preview of readable disk IDs |

### Phase 2 – Readable Hardware IDs

The formatting of stable and readable device identifiers was then developed.

| Commit | Content |
|---|---|
| `d17cab8` | readable SMART-based disk ID |
| `85d638d` | boot integration |
| `648eb0a` | WDC prefix and hyphen format |
| `7e7abbd` | ATA detection before formatting |
| `3f74bc5` | unified SATA, USB and NVMe identification |

### Phase 3 – Problematic USB-SATA Bridges

For hardware that does not provide a reliably usable ATA identity directly during boot, a persistent cache fallback was investigated and implemented.

| Commit | Content |
|---|---|
| `159cf32` | persistent identity cache fallback |
| `6dc048d` | identity source and hardened Udev processing |
| `2463420` | dynamic boot disk detection |

The cache was later deliberately excluded from the persistent Identity Baseline.

### Phase 4 – Safe Array ID Migration

The investigation showed that a persistent change to existing array assignments cannot be achieved through simple Udev changes.

This led to the development of a safeguarded transaction model.

| Commit | Content |
|---|---|
| `15aba35` | block unsafe apply path |
| `5f52956` | document migration findings |
| `1be9137` | verified MD transaction backend |
| `38340af` | safeguarded MD persistence transaction |
| `7f374de` | persistent two-phase backend |
| `3e2be77` | Phase B migration flow |
| `cf2d52d` | persistent Phase A reboot entry point |
| `3d2a34e` | successful two-phase persistence test |
| `e4a2649` | complete parity-array reboot test |

The parity-array test confirmed persistent slot assignment after the reboot.

It is not a general statement that existing parity data automatically remains valid after every New-Config-like operation. In the documented test, parity reconstruction was started.

### Phase 5 – Partitions, NVMe and Pools

Stable identity was extended to partitions and NVMe by-id links.

At the same time, a separate pool migration path was developed.

| Commit | Content |
|---|---|
| `745bbce` | stable identity inheritance for partitions |
| `36923a8` | pool migration preview |
| `9b2e90a` | pool transaction backend |
| `a984be6` | verified pool migration planning |
| `4d4d882` | pool ID migration apply |
| `e55947f` | persistent partition Udev rules |
| `f8d3fc5` | stable NVMe by-id links |

### Phase 6 – Persistent Boot Process

The boot path was extended, cleaned up and equipped with diagnostic functions.

| Commit | Content |
|---|---|
| `9e581b9` | persistent boot and multi-device pool path |
| `320119a` | safe cleanup of old boot hooks |
| `4edfe04` | cleanup of orphaned hook remnants |
| `7b42a45` | safe cleanup of old hook blocks |
| `fecbbb6` | boot diagnostics before Unraid initialization |

### Phase 7 – Separate Flash ID Path

The Unraid boot device was deliberately separated from the normal drive path.

| Commit | Content |
|---|---|
| `0439400` | isolated boot Flash identity |
| `dbc41a2` | Flash installer on FAT boot media |

### Phase 8 – Authorized Identity Baseline

Identity generation was then supplemented with an explicit server-specific authorization layer.

| Commit | Content |
|---|---|
| `7810e46` | persistent identity authorization helpers |
| `58741bb` | Activation Preflight and baseline preview |
| `39d1156` | hardened baseline TSV parsing |
| `ed57fc2` | exclude CACHE from persistent baseline |
| `0541f5b` | assignment resolution through hardware identity |
| `d230295` | validated baseline writer |
| `909c642` | authorize Udev identities through baseline |

### Phase 9 – Central Installation Orchestrator

With commit:

```text
7bb03ed – Add idempotent installation orchestrator
```

`install.sh` was added as the central installation and update entry point.

The orchestrator combines:

- project verification
- syntax verification
- Identity Baseline
- boot hooks
- runtime Udev
- Flash ID
- final validation

## Orchestrator Reference Test

The current orchestrator was subsequently fully installed on an Unraid 7.3.2 reference system and tested through a normal reboot.

Before the reboot, the installer confirmed:

```text
INSTALLATION ERFOLGREICH
BEREIT_FUER_REBOOT
```

After the reboot, the following were confirmed, among other things:

- all four persistent boot hooks were present exactly once each
- project rules were active again
- the Identity Baseline remained valid
- the baseline remained unchanged
- the separate Flash by-id link was present again
- no open array migration resume file existed
- the array was subsequently started normally

This practically verified the complete installation, boot and reboot path of the current orchestrator.

## Historical Development Documentation

The detailed investigations of the array ID migration remain available in:

[ARRAY-ID-MIGRATION-DEVELOPMENT.md](ARRAY-ID-MIGRATION-DEVELOPMENT.md)

This file is deliberately retained because it documents the development process, discarded approaches and the later successful tests.

It is a development journal and should not be understood as the sole current installation guide.
