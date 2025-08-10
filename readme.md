# VoIP Dialer für Raspberry Pi

Ein Service für Raspberry Pi, der bei GPIO-Tastendruck automatisch VoIP-Anrufe über einen PBX Server startet.

## Features

- **GPIO-Tastenüberwachung**: Reagiert auf Tastendruck (Pins 17 & 27 mit Pull-up)
- **VoIP-Integration**: Nutzt PJSIP für robuste SIP-Verbindungen
- **FreePBX-Kompatibilität**: Arbeitet mit vorhandenem FreePBX Server
- **Audio-Support**: RaspAudio Mic Ultra+ Integration
- **YAML-Konfiguration**: Einfache Konfiguration aller Parameter
- **Systemd-Service**: Automatischer Start beim Boot
- **Logging**: Umfassendes Logging und Fehlerbehandlung

## Hardware-Anforderungen

- Raspberry Pi (3B+ oder neuer empfohlen)
- RaspAudio Mic Ultra+ (Mikrofon/Lautsprecher)
- 2x Taster (GPIO Pin 17 und 27, mit Pull-up)
- Netzwerkverbindung zum FreePBX Server

## Software-Anforderungen

- Raspberry Pi OS (Bullseye oder neuer)
- Python 3.7+
- FreePBX Server im Netzwerk

## Installation

### Automatische Installation

```bash
# Repository klonen oder Dateien herunterladen
wget https://raw.githubusercontent.com/BitStab/voip-dialer/main/install.sh

# Installation ausführen
chmod +x install.sh
sudo ./install.sh
```

### Manuelle Installation

1. **System vorbereiten:**
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install python3 python3-pip python3-dev build-essential
   sudo apt install libasound2-dev portaudio19-dev libpjproject-dev
   ```

2. **Python-Pakete installieren:**
   ```bash
   pip3 install pjsua2 RPi.GPIO PyYAML pyaudio
   ```

3. **Dateien installieren:**
   ```bash
   sudo mkdir -p /opt/voip-dialer /etc/voip-dialer
   sudo cp voip_dialer.py /opt/voip-dialer/
   sudo cp config.yml /etc/voip-dialer/
   sudo cp voip-dialer.service /etc/systemd/system/
   sudo chmod +x /opt/voip-dialer/voip_dialer.py
   ```

4. **Service aktivieren:**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable voip-dialer
   ```

## Konfiguration

### 1. FreePBX-Server konfigurieren

Erstellen Sie einen SIP-Account auf Ihrem FreePBX Server:
- Extension: z.B. 1001
- Secret: Sicheres Passwort
- Codec: Mindestens ulaw, alaw
- NAT: Entsprechend Ihrer Netzwerk-Konfiguration

### 2. config.yml anpassen

```bash
sudo nano /etc/voip-dialer/config.yml
```

**Wichtige Einstellungen:**
```yaml
sip:
  server: "192.168.1.100"      # IP Ihres FreePBX Servers
  username: "1001"             # SIP-Extension
  password: "IhrPasswort"      # SIP-Passwort

gpio:
  buttons:
    - pin: 17
      name: "Notruf"
      number: "110"             # Zielrufnummer
    - pin: 27
      name: "Hausmeister"  
      number: "123"             # Interne Rufnummer
```

### 3. Audio-Test

```bash
# Aufnahme testen
arecord -d 5 -f cd test.wav

# Wiedergabe testen  
aplay test.wav

# Audio-Geräte auflisten
arecord -l
aplay -l
```

## Service-Management

```bash
# Service starten
sudo systemctl start voip-dialer

# Status prüfen
sudo systemctl status voip-dialer

# Logs anzeigen
sudo journalctl -u voip-dialer -f

# Service stoppen
sudo systemctl stop voip-dialer

# Service neustarten
sudo systemctl restart voip-dialer
```

## Logs und Debugging

### Log-Dateien
- **Service-Logs**: `sudo journalctl -u voip-dialer -f`
- **Anwendungs-Logs**: `tail -f /var/log/voip-dialer.log`

### Häufige Probleme

**1. SIP-Registrierung fehlgeschlagen**
```bash
# Netzwerk-Konnektivität prüfen
ping [FreePBX-Server-IP]

# FreePBX Logs prüfen
sudo tail -f /var/log/asterisk/full
```

**2. GPIO-Fehler**
```bash
# GPIO-Status prüfen
gpio readall

# Berechtigung prüfen
sudo usermod -a -G gpio $USER
```

**3. Audio-Probleme**
```bash
# Audio-System neustarten
sudo systemctl restart alsa-state

# Lautstärke prüfen
alsamixer
```

## Hardware-Verbindung

### GPIO-Verkabelung
```
GPIO 17 ---- [Taster 1] ---- GND
GPIO 27 ---- [Taster 2] ---- GND
```

### RaspAudio Mic Ultra+
- Automatische Erkennung als Standard-Audio-Device
- Falls nicht erkannt: `sudo raspi-config` → Advanced → Audio → Force 3.5mm

## Erweiterte Konfiguration

### Mehrere Rufnummern
```yaml
gpio:
  buttons:
    - pin: 17
      name: "Notruf Polizei"
      number: "110"
    - pin: 27
      name: "Notruf Feuerwehr"
      number: "112"
    # Weitere Tasten können hinzugefügt werden
```

### Audio-Optimierung
```yaml
audio:
  sample_rate: 8000           # Standard für VoIP
  echo_cancellation: true     # Empfohlen
  input_device: "hw:0,0"     # Spezifisches Device
  output_device: "hw:0,0"    # Spezifisches Device
```

## Sicherheitshinweise

- **Notrufnummern**: Verwenden Sie echte Notrufnummern nur in echten Notfällen
- **Passwörter**: Verwenden Sie sichere SIP-Passwörter
- **Netzwerk**: Stellen Sie sicher, dass Ihr Netzwerk sicher ist
- **Updates**: Halten Sie das System aktuell

## Support

Bei Problemen:
1. Prüfen Sie die Logs: `sudo journalctl -u voip-dialer -f`
2. Testen Sie die Netzwerkverbindung zum FreePBX Server
3. Überprüfen Sie die GPIO-Verkabelung
4. Testen Sie die Audio-Hardware

## Lizenz

MIT License - Siehe LICENSE Datei für Details.

## Disclaimer

Dieses System ist für interne/private Zwecke gedacht. Bei Verwendung für Notrufe stellen Sie sicher, dass alle rechtlichen Anforderungen erfüllt sind.
