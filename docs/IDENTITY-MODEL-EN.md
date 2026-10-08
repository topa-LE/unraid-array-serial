# Identity Model

## Table of Contents

- [Why a Separate Device Identity?](#why-a-separate-device-identity)
- [Three Central Values](#three-central-values)
- [Identity Sources](#identity-sources)
- [Project ID](#project-id)
- [Identity Baseline](#identity-baseline)
- [Baseline Creation](#baseline-creation)
- [Baseline Validation](#baseline-validation)
- [Udev Authorization](#udev-authorization)
- [Partitions](#partitions)
- [Fail-Closed](#fail-closed)

## Why a Separate Device Identity?

Linux device names are assigned during device detection.

Names such as:

```text
/dev/sda
/dev/sdb
/dev/sdc
/dev/nvme0n1
```

therefore do not permanently identify a specific physical drive.

Unraid, however, requires reproducible device identifiers.

Unraid Array Serial generates such identifiers from verified hardware information.

## Three Central Values

Three values are considered together for authorization:

| Value | Meaning |
|---|---|
| `ID_SERIAL_SHORT` | actual or verified hardware serial number |
| `IDENTITY_SOURCE` | source of the identity |
| `ID_SERIAL` | normalized project ID |

Together, these values form an identity.

## Identity Sources

### ATA

Direct SATA/ATA drives can provide their hardware identity through the ATA path.

```text
ATA
```

### USB-SAT

With suitable USB-SATA bridges, the ATA/SAT identity of the drive behind the bridge can be determined.

```text
USB_SAT
```

The USB bridge itself must not be confused with the identity of the installed drive.

### NVMe

NVMe drives are handled through their native NVMe path.

```text
NVME
```

Because the standard Udev processing can modify the NVMe ID again later, the project provides targeted post-processing through rule 61.

### CACHE

A persistent identity-cache fallback exists for problematic hardware paths.

```text
CACHE
```

This fallback can provide a previously verified identity.

However, `CACHE` is explicitly **not** permitted for the persistent Identity Baseline.

The cache is not an automatic learning system and does not replace a reliable hardware identity.

### FLASH

The physical Unraid boot device has a separate identity source:

```text
FLASH
```

It is not part of the normal data-drive baseline.

## Project ID

The project ID is a normalized, readable device identifier.

Neutral example:

```text
VENDOR-MODEL-EXAMPLE123456
```

The example does not correspond to any real test hardware.

The project ID should remain independent of whether the drive is detected during a particular boot as, for example, `/dev/sdc` or `/dev/sdh`.

## Identity Baseline

The baseline is stored by default at:

```text
/boot/config/custom/array-serial/identity-baseline.tsv
```

It contains exactly three TSV fields:

```text
HW_SERIAL    SOURCE    APPROVED_ID
```

Logically, each line describes:

```text
Hardware serial number
        +
permitted identity source
        +
permitted project ID
```

The baseline is therefore a server-specific authorization list.

## What the Baseline Is Not

The baseline is not:

- a list of current `/dev/sdX` names
- an automatic hardware-learning database
- a substitute for migration
- a mechanism for automatically accepting a replacement drive
- a list containing the Unraid boot device

## Baseline Creation

Before a baseline is created for the first time, `activation-preflight.sh` checks the existing stored Unraid assignments.

Every stored array or pool ID must be unambiguously mapped to a physical drive.

A baseline may be created only when the stored assignments already match the expected project IDs and the identity sources used are baseline-capable.

If there are no stored array/pool assignments at all, the preflight has no basis on which to grant this approval.

## Baseline Validation

`identity-baseline.sh` checks, among other things, the structure, uniqueness and validity of the entries.

Persistent baseline sources are:

```text
ATA
NVME
USB_SAT
```

`CACHE` is rejected as a persistent baseline source.

An existing baseline is validated by `unraid-orchestrator.sh` but is not automatically regenerated from the current hardware configuration.

## Udev Authorization

The Udev rules use the wrappers:

```text
udev-authorized-id.sh
udev-authorized-partition-id.sh
```

The wrapper determines the current identity and compares it exactly with the baseline.

Project properties are output only when there is an authorized match.

## Partitions

Partitions receive the stable identity of their whole-disk parent through the designated partition path.

```text
udev-authorized-partition-id.sh
        |
        v
partition-id.sh
        |
        v
Parent disk
```

No partition tables, file systems, UUIDs or user data are modified.

## Fail-Closed

If an identity cannot be determined or authorized unambiguously, the intended behavior is to stop or not output the project identity.

The project must never guess a persistent identity based on a changing Linux device name.
