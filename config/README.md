# Gepruefte Herstellerzuordnungen

Die Datei `verified-manufacturers.tsv` enthaelt ausschliesslich
nachvollziehbar gepruefte Zuordnungen von SMART-Modellbezeichnungen
zu Laufwerksherstellern.

## Voraussetzungen fuer einen Eintrag

1. Die Modellbezeichnung muss exakt aus der SMART-Identifikation
   des betreffenden Laufwerks stammen.
2. Der Hersteller muss durch eine nachvollziehbare Quelle fuer
   genau dieses Laufwerksmodell belegt sein, beispielsweise durch
   ein Herstellerdatenblatt oder eine offizielle Produktseite.
3. Die Pruefquelle muss im dritten Tabellenfeld dokumentiert werden.
4. Modellpraefixe, ungepruefte Vermutungen sowie USB-Adapterdaten
   duerfen nicht als Herstellerbeleg verwendet werden.
5. Bei widerspruechlichen oder unzureichenden Belegen wird keine
   Zuordnung eingetragen.

## Tabellenformat

Drei durch echte Tabulatoren getrennte Felder:

EXAKTES_SMART_MODELL    HERSTELLER    PRUEFQUELLE

Die dargestellten Zwischenraeume stehen hier nur zur Veranschaulichung.
Eine spaetere Eintragspruefung muss das tatsaechliche TSV-Format
kontrollieren.

## Verhalten bei fehlender Zuordnung

Ein Modell ohne geprueften Tabelleneintrag bleibt hinsichtlich
des Herstellers unbekannt. Es wird dann keine vollstaendige
Hersteller-Modell-Seriennummer-Kennung erzeugt.

Die Tabelle ist derzeit noch nicht mit dem Diagnosewerkzeug verbunden.
Ein Eintrag allein veraendert weder udev noch Laufwerkszuordnungen.
