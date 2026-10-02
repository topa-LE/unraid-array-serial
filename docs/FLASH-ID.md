# Flash-ID

## Inhaltsverzeichnis

- [Zweck](#zweck)
- [Komponenten](#komponenten)
- [Ermittlung des Boot-Laufwerks](#ermittlung-des-boot-laufwerks)
- [Identität](#identität)
- [Bestehende Links](#bestehende-links)
- [Nicht verändert](#nicht-verändert)
- [Persistenz](#persistenz)
- [Verifizierter Reboot-Test](#verifizierter-reboot-test)
- [Abgrenzung zur Identity-Baseline](#abgrenzung-zur-identity-baseline)

## Zweck

Der Unraid-Bootstick benötigt eine andere Behandlung als Array-, Pool- und Cache-Laufwerke.

Er wird deshalb nicht in die normale Identity-Baseline aufgenommen.

Der Flash-Pfad ist technisch isoliert.

## Komponenten

| Datei | Aufgabe |
|---|---|
| `flash-id.sh` | ermittelt und normalisiert die Identität des physischen Boot-Laufwerks |
| `install-flash-id.sh` | installiert Regel 64 und initialisiert Boot-Disk und Partitionen |
| `64-array-serial-flash.rules` | Udev-Regel für das physische `/boot`-Laufwerk |

## Ermittlung des Boot-Laufwerks

Die Installation ermittelt zunächst, welches Blockgerät `/boot` bereitstellt.

Damit ist keine feste Annahme wie `/dev/sda` oder `/dev/sdb` notwendig.

## Identität

Der Flash-Pfad erzeugt unter anderem:

```text
IDENTITY_SOURCE=FLASH
ID_SERIAL_SHORT=<Hardware-ID>
ID_SERIAL=<normalisierte Flash-ID>
```

Zusätzlich wird ein stabiler Link erzeugt:

```text
/dev/disk/by-id/usb-<ID_SERIAL>
```

Die Bootpartition erhält entsprechend einen Partitionslink.

Ein neutrales Beispiel könnte damit so aussehen:

```text
ID_SERIAL=USB-BOOT-FLASH-EXAMPLE123456

/dev/disk/by-id/usb-USB-BOOT-FLASH-EXAMPLE123456
/dev/disk/by-id/usb-USB-BOOT-FLASH-EXAMPLE123456-part1
```

Diese Werte sind Dokumentationsbeispiele und stammen nicht von realer Testhardware.

## Bestehende Links

Der native systemd-/Udev-Link des USB-Geräts bleibt aus Kompatibilitätsgründen bestehen.

Das Projekt ergänzt einen weiteren stabilen Link.

Der bestehende Hersteller-Link wird nicht absichtlich entfernt.

Der zusätzliche Link bedeutet insbesondere **nicht**, dass der Linux-Gerätename wie `/dev/sdb` physisch umbenannt wird.

## Nicht verändert

Der Flash-ID-Pfad verändert nicht:

- das Dateisystem des Bootsticks
- das Volume-Label
- UUID
- PARTUUID
- die physische Hardware-Seriennummer
- Unraid-Lizenzdaten

## Persistenz

Da `/etc/udev/rules.d/` zum Unraid-Laufzeitsystem gehört, muss Regel 64 bei jedem Boot erneut installiert werden.

Deshalb wird:

```text
install-flash-id.sh
```

persistent in `/boot/config/go` eingebunden.

## Verifizierter Reboot-Test

Auf dem getesteten Unraid-7.3.2-Referenzsystem wurde vor dem Reboot erfolgreich eine normalisierte Flash-ID mit zusätzlichem Projekt-by-id-Link erzeugt.

Nach einem vollständigen normalen Reboot waren sowohl der Projekt-Link der Boot-Disk als auch der entsprechende Partitionslink erneut vorhanden.

Der native Hersteller-Link blieb parallel erhalten.

Damit wurde praktisch verifiziert, dass der zusätzliche Projekt-Link durch den persistenten Bootpfad nach einem Neustart erneut hergestellt wird.

Aus Datenschutz- und Dokumentationsgründen werden die realen Hardware- und Seriennummern des Referenzsystems hier nicht veröffentlicht.

## Abgrenzung zur Identity-Baseline

Der Bootstick ist keine Array- oder Pool-Disk.

Deshalb gilt:

```text
Datenlaufwerke -> Identity-Baseline
Bootstick      -> separater Flash-ID-Pfad
```

Diese Trennung ist beabsichtigt.
