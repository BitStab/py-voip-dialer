#!/bin/bash
# Linphone VoIP Dialer Deinstallation Script

set -e

echo "=== Linphone VoIP Dialer Deinstallation ==="
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./uninstall-linphone.sh)" 
   exit 1
fi

# Sicherheitsabfrage
echo "⚠️  WARNUNG: Dies wird den Linphone VoIP Dialer vollständig entfernen!"
echo "   - Service wird gestoppt und deaktiviert"
echo "   - Alle Dateien in /opt/voip-dialer werden gelöscht"
echo "   - Konfiguration in /etc/voip-dialer wird gelöscht"
echo "   - Virtual Environment wird entfernt"
echo

read -p "Sind Sie sicher? (yes/nein): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Deinstallation abgebrochen."
    exit 0
fi

echo
echo "Starte Deinstallation..."

# 1. Service stoppen und deaktivieren
echo "1. Service wird gestoppt..."
if systemctl is-active --quiet voip-dialer-linphone; then
    echo "   Stoppe voip-dialer-linphone Service..."
    systemctl stop voip-dialer-linphone
    echo "   ✓ Service gestoppt"
else
    echo "   Service läuft nicht"
fi

if systemctl is-enabled --quiet voip-dialer-linphone 2>/dev/null; then
    echo "   Deaktiviere voip-dialer-linphone Service..."
    systemctl disable voip-dialer-linphone
    echo "   ✓ Service deaktiviert"
else
    echo "   Service ist nicht aktiviert"
fi

# 2. Systemd-Service entfernen
echo "2. Systemd-Service wird entfernt..."
if [ -f "/etc/systemd/system/voip-dialer-linphone.service" ]; then
    rm -f /etc/systemd/system/voip-dialer-linphone.service
    echo "   ✓ Service-Datei entfernt"
    
    systemctl daemon-reload
    echo "   ✓ Systemd neu geladen"
else
    echo "   Service-Datei nicht gefunden"
fi

# 3. Auch alte PJSIP-Services entfernen (falls vorhanden)
echo "3. Prüfe alte PJSIP-Services..."
if [ -f "/etc/systemd/system/voip-dialer.service" ]; then
    echo "   Entferne alten PJSIP voip-dialer Service..."
    systemctl stop voip-dialer 2>/dev/null || true
    systemctl disable voip-dialer 2>/dev/null || true
    rm -f /etc/systemd/system/voip-dialer.service
    echo "   ✓ Alter Service entfernt"
    systemctl daemon-reload
fi

# 4. Anwendungsverzeichnis entfernen
echo "4. Anwendungsverzeichnis wird entfernt..."
if [ -d "/opt/voip-dialer" ]; then
    echo "   Lösche /opt/voip-dialer..."
    rm -rf /opt/voip-dialer
    echo "   ✓ Anwendungsverzeichnis entfernt"
else
    echo "   Anwendungsverzeichnis nicht gefunden"
fi

# 5. Konfiguration entfernen (mit Backup-Option)
echo "5. Konfiguration wird behandelt..."
if [ -d "/etc/voip-dialer" ]; then
    echo "   Erstelle Backup der Konfiguration..."
    
    BACKUP_DIR="/tmp/voip-dialer-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -r /etc/voip-dialer/* "$BACKUP_DIR/" 2>/dev/null || true
    
    echo "   Backup erstellt: $BACKUP_DIR"
    
    echo "   Lösche /etc/voip-dialer..."
    rm -rf /etc/voip-dialer
    echo "   ✓ Konfigurationsverzeichnis entfernt"
    
    echo "   📁 Backup verfügbar unter: $BACKUP_DIR"
else
    echo "   Konfigurationsverzeichnis nicht gefunden"
fi

# 6. Log-Dateien entfernen
echo "6. Log-Dateien werden entfernt..."
if [ -f "/var/log/voip-dialer.log" ]; then
    echo "   Lösche Log-Datei..."
    rm -f /var/log/voip-dialer.log*
    echo "   ✓ Log-Dateien entfernt"
else
    echo "   Keine Log-Dateien gefunden"
fi

# 7. System-Pakete (optional entfernen)
echo "7. System-Pakete (optional)..."
echo "   Die folgenden Pakete könnten entfernt werden, werden aber von anderen"
echo "   Anwendungen verwendet werden können:"
echo "   - liblinphone-dev, python3-linphone"
echo "   - pulseaudio, alsa-utils"
echo "   - python3-venv, python3-dev"

read -p "   System-Pakete auch entfernen? (yes/nein): " -r
if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "   Entferne VoIP-spezifische Pakete..."
    
    # Nur VoIP-spezifische Pakete entfernen
    apt-get remove -y python3-linphone liblinphone-dev linphone 2>/dev/null || true
    
    echo "   ✓ VoIP-Pakete entfernt"
    echo "   (Basis-Pakete wie python3-venv wurden nicht entfernt)"
else
    echo "   System-Pakete bleiben installiert"
fi

# 8. Temporäre Dateien aufräumen
echo "8. Temporäre Dateien werden bereinigt..."
rm -f /tmp/test_audio.wav 2>/dev/null || true
rm -f /tmp/voip-test-* 2>/dev/null || true
echo "   ✓ Temporäre Dateien entfernt"

# 9. Audio-Konfiguration zurücksetzen (optional)
echo "9. Audio-Konfiguration..."
if [ -f "/home/pi/.asoundrc" ]; then
    read -p "   Audio-Konfiguration (/home/pi/.asoundrc) zurücksetzen? (yes/nein): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        mv /home/pi/.asoundrc /home/pi/.asoundrc.backup.$(date +%Y%m%d_%H%M%S)
        echo "   ✓ Audio-Konfiguration zurückgesetzt (Backup erstellt)"
    else
        echo "   Audio-Konfiguration bleibt unverändert"
    fi
fi

echo
echo "=== Deinstallation abgeschlossen ==="
echo

echo "✅ Entfernte Komponenten:"
echo "  ✓ Linphone VoIP Dialer Service"
echo "  ✓ Systemd Service-Dateien"
echo "  ✓ Anwendungsverzeichnis (/opt/voip-dialer)"
echo "  ✓ Konfigurationsverzeichnis (/etc/voip-dialer)"
echo "  ✓ Log-Dateien"
echo "  ✓ Virtual Environment"

if [ -d "$BACKUP_DIR" ]; then
    echo
    echo "📁 Backup erstellt:"
    echo "  Pfad: $BACKUP_DIR"
    echo "  Inhalt: Konfigurationsdateien"
    echo "  Automatisches Löschen: nach 30 Tagen"
    
    # Automatisches Backup-Cleanup Script erstellen
    cat > /tmp/cleanup-voip-backup.sh << CLEANUP_EOF
#!/bin/bash
# Automatisches Cleanup nach 30 Tagen
sleep $((30 * 24 * 3600))  # 30 Tage warten
rm -rf "$BACKUP_DIR"
rm -f /tmp/cleanup-voip-backup.sh
CLEANUP_EOF
    
    chmod +x /tmp/cleanup-voip-backup.sh
    nohup /tmp/cleanup-voip-backup.sh &
fi

echo
echo "🔧 Falls benötigt - Neuinstallation:"
echo "  wget https://raw.githubusercontent.com/ihr-repo/voip-dialer/main/install-linphone-venv.sh"
echo "  sudo ./install-linphone-venv.sh"

if [ -d "$BACKUP_DIR" ]; then
    echo
    echo "🔄 Konfiguration wiederherstellen:"
    echo "  sudo mkdir -p /etc/voip-dialer"
    echo "  sudo cp $BACKUP_DIR/* /etc/voip-dialer/"
fi

echo
echo "📋 Verbleibende System-Komponenten:"
echo "  - Python 3 und Basis-Pakete"
echo "  - Audio-System (ALSA/PulseAudio)"
echo "  - GPIO-System"
echo "  (Diese werden von anderen Anwendungen verwendet)"

echo
echo "🎉 Deinstallation erfolgreich abgeschlossen!"
echo
echo "Hinweis: Ein Neustart wird empfohlen um alle Services sauber zu beenden:"
echo "  sudo reboot"