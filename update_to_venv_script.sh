#!/bin/bash
# VoIP Dialer Update Script für Virtual Environment Installation

set -e

echo "=== VoIP Dialer Update (Virtual Environment) ==="
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./update.sh)" 
   exit 1
fi

# Service Status prüfen
if systemctl is-active --quiet voip-dialer; then
    SERVICE_WAS_RUNNING=true
    echo "1. Service wird gestoppt..."
    systemctl stop voip-dialer
else
    SERVICE_WAS_RUNNING=false
    echo "1. Service ist bereits gestoppt"
fi

# Backup der aktuellen Konfiguration
echo "2. Backup der Konfiguration wird erstellt..."
if [ -f "/etc/voip-dialer/config.yml" ]; then
    cp /etc/voip-dialer/config.yml /etc/voip-dialer/config.yml.backup.$(date +%Y%m%d_%H%M%S)
    echo "   Backup erstellt: /etc/voip-dialer/config.yml.backup.*"
fi

# Virtual Environment prüfen
echo "3. Virtual Environment wird überprüft..."
if [ ! -d "/opt/voip-dialer/venv" ]; then
    echo "   Virtual Environment nicht gefunden - wird erstellt..."
    cd /opt/voip-dialer
    python3 -m venv venv
fi

# Python-Pakete aktualisieren
echo "4. Python-Pakete werden aktualisiert..."
/opt/voip-dialer/venv/bin/pip install --upgrade pip

# Requirements prüfen und installieren
if [ -f "/opt/voip-dialer/requirements.txt" ]; then
    echo "   Aktualisiere Pakete aus requirements.txt..."
    /opt/voip-dialer/venv/bin/pip install --upgrade -r /opt/voip-dialer/requirements.txt
else
    echo "   Installiere Standard-Pakete..."
    /opt/voip-dialer/venv/bin/pip install --upgrade pjsua2 RPi.GPIO PyYAML pyaudio
fi

# Hauptprogramm aktualisieren (falls vorhanden)
if [ -f "voip_dialer.py" ]; then
    echo "5. Hauptprogramm wird aktualisiert..."
    
    # Backup des alten Programms
    if [ -f "/opt/voip-dialer/voip_dialer.py" ]; then
        cp /opt/voip-dialer/voip_dialer.py /opt/voip-dialer/voip_dialer.py.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Neues Programm kopieren
    cp voip_dialer.py /opt/voip-dialer/
    chmod +x /opt/voip-dialer/voip_dialer.py
    chown root:root /opt/voip-dialer/voip_dialer.py
    echo "   Hauptprogramm aktualisiert"
else
    echo "5. Hauptprogramm - keine Aktualisierung verfügbar"
fi

# Systemd Service aktualisieren (falls vorhanden)
if [ -f "voip-dialer.service" ]; then
    echo "6. Systemd Service wird aktualisiert..."
    cp voip-dialer.service /etc/systemd/system/
    systemctl daemon-reload
    echo "   Service-Definition aktualisiert"
else
    echo "6. Systemd Service - keine Aktualisierung verfügbar"
fi

# Berechtigungen überprüfen
echo "7. Berechtigungen werden überprüft..."
chown -R root:root /opt/voip-dialer
chmod +x /opt/voip-dialer/voip_dialer.py
if [ -f "/etc/voip-dialer/config.yml" ]; then
    chmod 600 /etc/voip-dialer/config.yml
    chown root:root /etc/voip-dialer/config.yml
fi

# Virtual Environment testen
echo "8. Virtual Environment wird getestet..."
if /opt/voip-dialer/venv/bin/python3 -c "import pjsua2, RPi.GPIO, yaml; print('✓ Alle Module verfügbar')"; then
    echo "   Virtual Environment ist funktionsfähig"
else
    echo "   ✗ Fehler im Virtual Environment!"
    exit 1
fi

# Service wieder starten falls er vorher lief
if [ "$SERVICE_WAS_RUNNING" = true ]; then
    echo "9. Service wird gestartet..."
    systemctl start voip-dialer
    sleep 2
    
    if systemctl is-active --quiet voip-dialer; then
        echo "   ✓ Service erfolgreich gestartet"
    else
        echo "   ✗ Service-Start fehlgeschlagen!"
        echo "   Prüfen Sie: sudo systemctl status voip-dialer"
        echo "   Logs: sudo journalctl -u voip-dialer -f"
    fi
else
    echo "9. Service nicht gestartet (war vorher gestoppt)"
fi

# Update-Info anzeigen
echo
echo "=== Update abgeschlossen ==="
echo
echo "Aktualisierte Komponenten:"
if [ -f "voip_dialer.py" ]; then
    echo "✓ Hauptprogramm aktualisiert"
fi
if [ -f "voip-dialer.service" ]; then
    echo "✓ Systemd Service aktualisiert"
fi
echo "✓ Python-Pakete aktualisiert"
echo
echo "Virtual Environment Status:"
echo "- Python Version: $(/opt/voip-dialer/venv/bin/python3 --version)"
echo "- Installierte Pakete:"
/opt/voip-dialer/venv/bin/pip list | grep -E "(pjsua2|RPi.GPIO|PyYAML|pyaudio)"
echo
echo "Nützliche Kommandos:"
echo "- Service Status: sudo systemctl status voip-dialer"
echo "- Logs anzeigen: sudo journalctl -u voip-dialer -f"
echo "- Konfiguration: sudo nano /etc/voip-dialer/config.yml"
echo "- Service neustarten: sudo systemctl restart voip-dialer"
echo
echo "Backup-Dateien:"
if ls /etc/voip-dialer/config.yml.backup.* 1> /dev/null 2>&1; then
    echo "- Konfiguration: $(ls -1t /etc/voip-dialer/config.yml.backup.* | head -1)"
fi
if ls /opt/voip-dialer/voip_dialer.py.backup.* 1> /dev/null 2>&1; then
    echo "- Programm: $(ls -1t /opt/voip-dialer/voip_dialer.py.backup.* | head -1)"
fi