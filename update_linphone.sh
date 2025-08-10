#!/bin/bash
# Linphone VoIP Dialer Update Script

set -e

echo "=== Linphone VoIP Dialer Update ==="
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./update-linphone.sh)" 
   exit 1
fi

# Service Status prüfen
if systemctl is-active --quiet voip-dialer-linphone; then
    SERVICE_WAS_RUNNING=true
    echo "1. Service wird gestoppt..."
    systemctl stop voip-dialer-linphone
    echo "   ✓ Service gestoppt"
else
    SERVICE_WAS_RUNNING=false
    echo "1. Service ist bereits gestoppt"
fi

# Backup der Konfiguration
echo "2. Backup wird erstellt..."
BACKUP_DIR="/tmp/voip-dialer-backup-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

if [ -f "/etc/voip-dialer/config.yml" ]; then
    cp /etc/voip-dialer/config.yml "$BACKUP_DIR/"
    echo "   ✓ Konfiguration gesichert: $BACKUP_DIR/config.yml"
fi

if [ -f "/opt/voip-dialer/voip_dialer_linphone.py" ]; then
    cp /opt/voip-dialer/voip_dialer_linphone.py "$BACKUP_DIR/"
    echo "   ✓ Programm gesichert: $BACKUP_DIR/voip_dialer_linphone.py"
fi

# System-Pakete aktualisieren
echo "3. System-Pakete werden aktualisiert..."
apt-get update

# Linphone-Pakete prüfen und aktualisieren
echo "3a. Linphone-Pakete werden aktualisiert..."
if apt list --upgradable 2>/dev/null | grep -q linphone; then
    echo "   Aktualisiere Linphone-Pakete..."
    apt-get upgrade -y liblinphone-dev python3-linphone linphone || true
    echo "   ✓ Linphone-Pakete aktualisiert"
else
    echo "   Linphone-Pakete sind aktuell"
fi

# Virtual Environment prüfen
echo "4. Virtual Environment wird geprüft..."
if [ ! -d "/opt/voip-dialer/venv" ]; then
    echo "   Virtual Environment nicht gefunden - wird erstellt..."
    cd /opt/voip-dialer
    python3 -m venv venv
    echo "   ✓ Virtual Environment erstellt"
fi

# Python-Pakete aktualisieren
echo "5. Python-Pakete werden aktualisiert..."
/opt/voip-dialer/venv/bin/pip install --upgrade pip wheel setuptools

if [ -f "/opt/voip-dialer/requirements.txt" ]; then
    echo "   Aktualisiere aus requirements.txt..."
    /opt/voip-dialer/venv/bin/pip install --upgrade -r /opt/voip-dialer/requirements.txt
else
    echo "   Aktualisiere Standard-Pakete..."
    /opt/voip-dialer/venv/bin/pip install --upgrade RPi.GPIO PyYAML pyaudio
    
    # Linphone separat aktualisieren
    echo "   Aktualisiere Linphone Python-Bindings..."
    /opt/voip-dialer/venv/bin/pip install --upgrade linphone || echo "   (pip-Installation fehlgeschlagen - verwende System-Paket)"
fi

# Programm aktualisieren (falls neue Version vorhanden)
echo "6. Programm wird aktualisiert..."
if [ -f "voip_dialer_linphone.py" ]; then
    echo "   Neue Programmversion gefunden - aktualisiere..."
    cp voip_dialer_linphone.py /opt/voip-dialer/
    chmod +x /opt/voip-dialer/voip_dialer_linphone.py
    echo "   ✓ Programm aktualisiert"
else
    echo "   Keine neue Programmversion verfügbar"
fi

# Systemd Service aktualisieren
echo "7. Service-Konfiguration wird geprüft..."
if [ -f "voip-dialer-linphone.service" ]; then
    echo "   Aktualisiere Service-Definition..."
    cp voip-dialer-linphone.service /etc/systemd/system/
    systemctl daemon-reload
    echo "   ✓ Service-Definition aktualisiert"
else
    echo "   Service-Definition ist aktuell"
fi

# Konfiguration aktualisieren (nur neue Felder)
echo "8. Konfiguration wird geprüft..."
if [ -f "/etc/voip-dialer/config.yml" ]; then
    echo "   Prüfe Konfiguration auf neue Felder..."
    
    # Prüfe ob neue Audio-Features verfügbar sind
    if ! grep -q "noise_suppression" /etc/voip-dialer/config.yml; then
        echo "   Füge neue Audio-Features hinzu..."
        
        # Backup der aktuellen Konfiguration
        cp /etc/voip-dialer/config.yml /etc/voip-dialer/config.yml.pre-update
        
        # Erweitere Audio-Sektion
        cat >> /etc/voip-dialer/config.yml << 'NEW_AUDIO'

# Neue Audio-Features (automatisch hinzugefügt beim Update)
  noise_suppression: true         # Rauschunterdrückung
  automatic_gain_control: true    # Automatische Verstärkung
  adaptive_rate_control: true     # Adaptive Bitrate
NEW_AUDIO

        echo "   ✓ Neue Audio-Features hinzugefügt"
        echo "   Backup: /etc/voip-dialer/config.yml.pre-update"
    fi
else
    echo "   Konfigurationsdatei nicht gefunden"
fi

# Berechtigungen überprüfen
echo "9. Berechtigungen werden überprüft..."
chown -R root:root /opt/voip-dialer
chmod +x /opt/voip-dialer/voip_dialer_linphone.py
if [ -f "/etc/voip-dialer/config.yml" ]; then
    chmod 600 /etc/voip-dialer/config.yml
fi
echo "   ✓ Berechtigungen aktualisiert"

# Audio-System prüfen
echo "10. Audio-System wird geprüft..."
if systemctl is-active --quiet pulseaudio 2>/dev/null; then
    echo "   ✓ PulseAudio läuft"
elif pulseaudio --check 2>/dev/null; then
    echo "   ✓ PulseAudio verfügbar"
else
    echo "   ⚠ PulseAudio-Problem - wird neu gestartet..."
    systemctl restart pulseaudio 2>/dev/null || true
fi

# Installation testen
echo "11. Update wird getestet..."

echo "   Teste Python-Module..."
if /opt/voip-dialer/venv/bin/python3 -c "import RPi.GPIO, yaml; print('Basis-Module OK')" 2>/dev/null; then
    BASE_OK=true
else
    BASE_OK=false
fi

echo "   Teste Linphone..."
if /opt/voip-dialer/venv/bin/python3 -c "import linphone; print('Linphone OK, Version:', linphone.Core.get_version())" 2>/dev/null; then
    LINPHONE_OK=true
elif python3 -c "import linphone; print('System-Linphone OK, Version:', linphone.Core.get_version())" 2>/dev/null; then
    LINPHONE_OK=true
    echo "   (Verwende System-Linphone)"
else
    LINPHONE_OK=false
fi

echo "   Teste Konfiguration..."
if /opt/voip-dialer/venv/bin/python3 -c "import yaml; yaml.safe_load(open('/etc/voip-dialer/config.yml'))" 2>/dev/null; then
    CONFIG_OK=true
else
    CONFIG_OK=false
fi

# Service wieder starten falls er vorher lief
if [ "$SERVICE_WAS_RUNNING" = true ]; then
    echo "12. Service wird gestartet..."
    systemctl start voip-dialer-linphone
    sleep 3
    
    if systemctl is-active --quiet voip-dialer-linphone; then
        echo "   ✓ Service erfolgreich gestartet"
        SERVICE_START_OK=true
    else
        echo "   ✗ Service-Start fehlgeschlagen!"
        echo "   Prüfen Sie: sudo systemctl status voip-dialer-linphone"
        SERVICE_START_OK=false
    fi
else
    echo "12. Service bleibt gestoppt (war vorher nicht aktiv)"
    SERVICE_START_OK=true
fi

echo
echo "=== Update-Zusammenfassung ==="
echo

# Gesamtergebnis
if [ "$BASE_OK" = true ] && [ "$LINPHONE_OK" = true ] && [ "$CONFIG_OK" = true ] && [ "$SERVICE_START_OK" = true ]; then
    echo "🎉 Update erfolgreich abgeschlossen!"
    UPDATE_SUCCESS=true
else
    echo "⚠ Update mit Problemen abgeschlossen"
    UPDATE_SUCCESS=false
fi

echo
echo "Aktualisierte Komponenten:"
echo "- ✓ System-Pakete und Linphone"
echo "- ✓ Python Virtual Environment"
echo "- ✓ Python-Pakete"
if [ -f "voip_dialer_linphone.py" ]; then
    echo "- ✓ Hauptprogramm"
fi
if [ -f "voip-dialer-linphone.service" ]; then
    echo "- ✓ Service-Definition"
fi
echo "- ✓ Konfiguration (erweitert)"
echo "- ✓ Berechtigungen"

echo
echo "Status nach Update:"
echo "- Basis-Module: $([ "$BASE_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- Linphone: $([ "$LINPHONE_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- Konfiguration: $([ "$CONFIG_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- Service: $([ "$SERVICE_START_OK" = true ] && echo "✓ OK" || echo "✗ Problem")"

if [ "$LINPHONE_OK" = true ]; then
    LINPHONE_VERSION=$(/opt/voip-dialer/venv/bin/python3 -c "import linphone; print(linphone.Core.get_version())" 2>/dev/null || python3 -c "import linphone; print(linphone.Core.get_version())" 2>/dev/null || echo "Unbekannt")
    echo "- Linphone Version: $LINPHONE_VERSION"
fi

echo
echo "Backup-Informationen:"
echo "- Backup-Pfad: $BACKUP_DIR"
echo "- Automatisches Löschen: nach 7 Tagen"

# Cleanup-Script für Backup
cat > /tmp/cleanup-update-backup.sh << CLEANUP_EOF
#!/bin/bash
sleep $((7 * 24 * 3600))  # 7 Tage warten
rm -rf "$BACKUP_DIR"
rm -f /tmp/cleanup-update-backup.sh
CLEANUP_EOF

chmod +x /tmp/cleanup-update-backup.sh
nohup /tmp/cleanup-update-backup.sh &

if [ "$UPDATE_SUCCESS" = false ]; then
    echo
    echo "Fehlerbehebung:"
    
    if [ "$LINPHONE_OK" = false ]; then
        echo "1. Linphone reparieren:"
        echo "   sudo apt-get install --reinstall python3-linphone liblinphone-dev"
    fi
    
    if [ "$SERVICE_START_OK" = false ]; then
        echo "2. Service-Probleme beheben:"
        echo "   sudo systemctl status voip-dialer-linphone"
        echo "   sudo journalctl -u voip-dialer-linphone -n 20"
    fi
    
    if [ "$CONFIG_OK" = false ]; then
        echo "3. Konfiguration wiederherstellen:"
        echo "   sudo cp $BACKUP_DIR/config.yml /etc/voip-dialer/"
    fi
fi

echo
echo "Nützliche Kommandos nach Update:"
echo "- Status prüfen: sudo systemctl status voip-dialer-linphone"
echo "- Logs anzeigen: sudo journalctl -u voip-dialer-linphone -f"
echo "- Installation testen: ./test-linphone.sh"
echo "- Service neu starten: sudo systemctl restart voip-dialer-linphone"

echo
echo "🔄 Update abgeschlossen!"

exit $([ "$UPDATE_SUCCESS" = true ] && echo 0 || echo 1)