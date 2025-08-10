#!/bin/bash
# VoIP Dialer Installation Script für Raspberry Pi

set -e

echo "=== VoIP Dialer Installation ==="
echo "Dieses Script installiert den VoIP Dialer Service auf Ihrem Raspberry Pi"
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install.sh)" 
   exit 1
fi

# System aktualisieren
echo "1. System wird aktualisiert..."
apt-get update
apt-get upgrade -y

# Abhängigkeiten installieren
echo "2. Systemabhängigkeiten werden installiert..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    build-essential \
    libasound2-dev \
    portaudio19-dev \
    libpjproject-dev \
    python3-pjproject \
    git \
    alsa-utils

# Python-Abhängigkeiten installieren
echo "3. Python-Pakete werden installiert..."
pip3 install --upgrade pip
pip3 install \
    pjsua2 \
    RPi.GPIO \
    PyYAML \
    pyaudio

# Verzeichnisse erstellen
echo "4. Verzeichnisse werden erstellt..."
mkdir -p /opt/voip-dialer
mkdir -p /etc/voip-dialer
mkdir -p /var/log

# Dateien kopieren
echo "5. Dateien werden installiert..."

# Hauptprogramm
cat > /opt/voip-dialer/voip_dialer.py << 'EOF'
# Hier würde der Inhalt von voip_dialer.py stehen
# (aus Platzgründen nicht komplett wiederholt)
EOF

# Konfiguration (Template)
cat > /etc/voip-dialer/config.yml << 'EOF'
# WICHTIG: Passen Sie diese Konfiguration an Ihre Umgebung an!

sip:
  server: "192.168.1.100"          # ÄNDERN: IP Ihres FreePBX Servers
  username: "1001"                 # ÄNDERN: Ihr SIP-Benutzername  
  password: "PASSWORT_HIER"        # ÄNDERN: Ihr SIP-Passwort
  local_port: 5060

gpio:
  buttons:
    - pin: 17
      name: "Taste 1"
      number: "100"                # ÄNDERN: Zielrufnummer
    - pin: 27  
      name: "Taste 2"
      number: "101"                # ÄNDERN: Zielrufnummer

call:
  duration_seconds: 30

audio:
  input_device: "default"
  output_device: "default" 
  sample_rate: 8000
  echo_cancellation: true

logging:
  level: "INFO"
  file: "/var/log/voip-dialer.log"
EOF

# Systemd Service
cat > /etc/systemd/system/voip-dialer.service << 'EOF'
[Unit]
Description=VoIP Dialer Service for Raspberry Pi
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 /opt/voip-dialer/voip_dialer.py
Restart=on-failure
RestartSec=5s
WorkingDirectory=/opt/voip-dialer
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Berechtigungen setzen
echo "6. Berechtigungen werden gesetzt..."
chmod +x /opt/voip-dialer/voip_dialer.py
chmod 600 /etc/voip-dialer/config.yml
chown root:root /opt/voip-dialer/voip_dialer.py
chown root:root /etc/voip-dialer/config.yml

# Audio-Konfiguration für RaspAudio Mic Ultra+
echo "7. Audio wird konfiguriert..."

# ALSA-Konfiguration
cat > /home/pi/.asoundrc << 'EOF'
pcm.!default {
    type hw
    card 0
    device 0
}

ctl.!default {
    type hw
    card 0
}
EOF

# Audio-Test
echo "8. Audio-Hardware wird getestet..."
arecord -l
aplay -l

# Service registrieren
echo "9. Service wird registriert..."
systemctl daemon-reload
systemctl enable voip-dialer.service

echo
echo "=== Installation abgeschlossen ==="
echo
echo "WICHTIGE NÄCHSTE SCHRITTE:"
echo "1. Konfiguration anpassen: sudo nano /etc/voip-dialer/config.yml"
echo "2. FreePBX-Server IP, Benutzername und Passwort eintragen"
echo "3. Zielrufnummern für die Tasten konfigurieren"
echo "4. Service starten: sudo systemctl start voip-dialer"
echo "5. Status prüfen: sudo systemctl status voip-dialer"
echo "6. Logs anzeigen: sudo journalctl -u voip-dialer -f"
echo
echo "Audio-Test:"
echo "- Aufnahme testen: arecord -d 5 test.wav"
echo "- Wiedergabe testen: aplay test.wav"
echo
echo "Fehlerbehandlung:"
echo "- Log-Datei: tail -f /var/log/voip-dialer.log"
echo "- Service neustarten: sudo systemctl restart voip-dialer"
echo
echo "WARNUNG: Denken Sie daran, echte Notrufnummern nur im Notfall zu verwenden!"