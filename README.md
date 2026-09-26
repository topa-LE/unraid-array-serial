# Unraid Array Serial

Stabile Laufwerksidentifikation fuer Unraid.

## Projektstatus

Entwicklung. Noch kein universeller Installer und keine Freigabe
fuer den Einsatz auf weiteren Unraid-Servern.

## Bisher getesteter Stand

Unraid 7.3.2, USB-SATA-Adapter VIA Labs 2109:0715.

Die Referenzimplementierung liest die ATA-Seriennummer ueber
smartctl und uebergibt sie an udev.

## Geplante Erweiterungen

- Geraetekennung aus Hersteller, Modell und echter Seriennummer
- Unterstuetzung weiterer USB-SATA-Adapter
- Pruefung der Identifikation von Array-, Cache- und Pool-Laufwerken
- Versionspruefung, Installation, Sicherung und Deinstallation

Bestehende Laufwerkszuordnungen und ZFS-Metadaten werden nicht
automatisch veraendert.

## USB-SATA-Bridges ohne zuverlässige ATA-Identität

Einige USB-SATA-Bridges geben die Identität der angeschlossenen physischen
Festplatte beim Booten nicht zuverlässig an Linux weiter.

Ein nachgewiesener Fall ist eine JMicron-JMS567-Multi-LUN-Bridge. Hinter
dieser Bridge konnte `ata_id` für mehrere SATA-Festplatten keine vollständige
ATA-Identität liefern. SMART/SAT konnte die echte Hardware-Identität teilweise
ermitteln, reagierte jedoch nicht deterministisch und konnte einzelne Zugriffe
für viele Sekunden blockieren.

Eine solche Abfrage ist deshalb für den zeitkritischen Udev-/Bootpfad nicht
geeignet.

### Persistenter Identity-Cache

`unraid-array-serial` verwendet für solche Geräte einen persistenten
Identity-Cache als Fallback.

Die echte Hardware-Identität muss zuvor verifiziert worden sein. Der
Bootpfad verwendet anschließend keine wechselnden Linux-Gerätenamen wie
`sdX` als persistente Identität.

Der Cache-Resolver ordnet den gespeicherten Datensatz anhand folgender
Merkmale zu:

- stabiler physischer `ID_PATH` der Bridge bzw. des LUN
- exakte Laufwerkskapazität

Bei einem eindeutigen Treffer werden die zuvor verifizierte
Hardware-Seriennummer und die daraus erzeugte stabile Laufwerkskennung
bereitgestellt.

Für ATA/SATA-Laufwerke hinter einer solchen Bridge werden außerdem die für
die weitere Udev-Verarbeitung notwendigen Basiseigenschaften bereitgestellt:

- `ID_ATA=1`
- `ID_BUS=ata`
- `ID_TYPE=disk`
- `ID_MODEL`
- `ID_SERIAL_SHORT`
- `ID_SERIAL`

Eine nicht vorhandene WWN wird ausdrücklich nicht erfunden.

Dadurch kann die nachfolgende Standard-Udev-Verarbeitung einen konsistenten
`/dev/disk/by-id/ata-...`-Link erzeugen.

Direkte SATA-Laufwerke oder Bridges, bei denen die Hardware-Identität
zuverlässig direkt ermittelt werden kann, benötigen diesen Cache-Fallback
nicht.

### Sicherheitsgrenze des Cache-Fallbacks

`ID_PATH` und Kapazität allein beweisen nicht dauerhaft, dass sich noch
derselbe physische Datenträger im betreffenden Schacht befindet.

Ein gleich großer Ersatzdatenträger am selben Anschluss darf deshalb nicht
blind die gespeicherte Identität seines Vorgängers übernehmen.

Vor einer allgemeinen Freigabe des automatischen Cache-Lernens muss deshalb
ein kontrollierter Replacement-/Relearn-Mechanismus implementiert werden.
Bei fehlender oder widersprüchlicher Zuordnung muss die Migration sicher
abbrechen, statt eine Identität zu erraten.

### Verifizierter Testfall

Auf einem Unraid-7.3.2-Testsystem wurden fünf SATA-Laufwerke hinter einer
JMicron-JMS567-Multi-LUN-Bridge getestet.

Für alle fünf Laufwerke erzeugte die vollständige Udev-Regelverarbeitung
erfolgreich:

- die zuvor verifizierte echte Hardware-Seriennummer
- die erwartete stabile `ID_SERIAL`
- vollständige ATA-Basismetadaten
- einen sauberen `/dev/disk/by-id/ata-...`-Link

SMART/SAT war für diesen erfolgreichen Bootpfad nicht erforderlich.
