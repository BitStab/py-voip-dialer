#!/bin/bash
# Linphone VoIP Dialer Installation Test Script

echo "=== Linphone VoIP Dialer Test ==="
echo

ERRORS=0

# Test-Funktion
test_check() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "Testing $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo "✓ OK"
        return 0
    else
        echo "✗ FEHLER"
        ((ERRORS++))
        return 1
    fi
}

# 1. Verzeichnisse und Dateien
echo "1. Installation prüfen:"
test_check "Hauptverzeichnis" "[ -d /opt/voip-dialer ]"
test_check "Konfigverzeichnis" "[ -d /etc/voip-dialer ]"
test_check "Virtual Environment" "[ -d /opt/voip-dialer/venv ]"
test_check "Linphone-Programm" "[ -f /opt/voip-dialer/voip_dialer_linphone.py ]"
test_check "Konfigurationsdatei" "[ -f /etc/voip-dialer/config.yml ]"
test_check "Systemd Service" "[ -f /etc/systemd/system/voip-dialer-linphone.service ]"

echo

# 2. Python-Module
echo "2. Python-Module:"
test_check "Python Virtual Environment" "/opt/voip-dialer/venv/bin/python3 --version"
test_check "RPi.GPIO" "/opt/voip-dialer/venv/bin/python3 -c 'import RPi.GPIO'"
test_check "PyYAML" "/opt/voip-dialer/venv/bin/python3 -c 'import yaml'"
test_check "PyAudio" "/opt/voip-dialer/venv/bin/python3 -c 'import pyaudio'"

# Linphone separat testen
echo -n "Testing Linphone Python... "
if /opt/voip-dialer/venv/bin/python3 -c 'import linphone; print("Version:", linphone.Core.get_version())' >/dev/null 2>&1; then
    echo "✓ OK (venv)"
    LINPHONE_VENV=true
elif python3 -c 'import linphone; print("Version:", linphone.Core.get_version())' >/dev/null 2>&1; then
    echo "✓ OK (system)"
    LINPHONE_VENV=false
else
    echo "✗ FEHLER"
    ((ERRORS++))
    LINPHONE_VENV=false
fi

echo

# 3. System-Bibliotheken
echo "3. System-Bibliotheken:"
test_check "liblinphone" "ldconfig -p | grep linphone"
test_check "ALSA" "arecord -l | grep card"
test_check "PulseAudio" "pulseaudio --check"

echo

# 4. Audio-System
echo "4. Audio-System:"
test_check "Audio-Eingabe" "arecord -l | grep -q card"
test_check "Audio-Ausgabe" "aplay -l | grep -q card"

# Audio-Test (optional)
echo -n "Testing Audio-Funktionalität... "
if arecord -d 1 -f cd /tmp/test_audio.wav >/dev/null 2>&1 && [ -f /tmp/test_audio.wav ]; then
    echo "✓ OK"
    rm -f /tmp/test_audio.wav
    AUDIO_FUNCTIONAL=true
else
    echo "⚠ Eingeschränkt"
    AUDIO_FUNCTIONAL=false
fi

echo

# 5. Linphone-Funktionalität
echo "5. Linphone-Funktionalität:"

# Linphone Core Test
echo -n "Testing Linphone Core... "
if /opt/voip-dialer/venv/bin/python3 -c "
import linphone
factory = linphone.Factory.get()
core = factory.create_core(None, None, None)
print('✓ Core erstellt')
" >/dev/null 2>&1; then
    echo "✓ OK"
    LINPHONE_CORE_OK=true
else
    echo "✗ FEHLER"
    ((ERRORS++))
    LINPHONE_CORE_OK=false
fi

# Audio-Codecs prüfen
echo -n "Testing Audio-Codecs... "
CODECS=$(/opt/voip-dialer/venv/bin/python3 -c "
import linphone
factory = linphone.Factory.get()
core = factory.create_core(None, None, None)
payloads = core.audio_payload_types
g711_found = False
for p in payloads:
    if p.mime_type in ['PCMU', 'PCMA']:
        g711_found = True
        break
print('G.711 available' if g711_found else 'No G.711')
" 2>/dev/null)

if echo "$CODECS" | grep -q "G.711 available"; then
    echo "✓ OK (G.711 verfügbar)"
    CODECS_OK=true
else
    echo "⚠ Eingeschränkt"
    CODECS_OK=false
fi

echo

# 6. Konfiguration
echo "6. Konfiguration:"
test_check "YAML-Syntax" "/opt/voip-dialer/venv/bin/python3 -c 'import yaml; yaml.safe_load(open(\"/etc/voip-dialer/config.yml\"))'"

# Konfigurationswerte
echo -n "Testing Konfigurationswerte... "
CONFIG_STATUS=$(/opt/voip-dialer/venv/bin/python3 -c "
import yaml
with open('/etc/voip-dialer/config.yml') as f:
    config = yaml.safe_load(f)

if config['sip']['password'] == 'PASSWORT_HIER':
    print('NOT_CONFIGURED')
elif config['sip']['server'] == '192.168.1.100':
    print('DEFAULT_IP')
else:
    print('CONFIGURED')
" 2>/dev/null)

case $CONFIG_STATUS in
    "NOT_CONFIGURED")
        echo "⚠ Passwort nicht gesetzt"
        ;;
    "DEFAULT_IP")
        echo "⚠ Standard-IP aktiv"
        ;;
    "CONFIGURED")
        echo "✓ Konfiguriert"
        ;;
    *)
        echo "✗ Konfigurationsfehler"
        ((ERRORS++))
        ;;
esac

echo

# 7. Service
echo "7. Service-System:"
test_check "Service registriert" "systemctl list-unit-files | grep voip-dialer-linphone"
test_check "Service aktiviert" "systemctl is-enabled voip-dialer-linphone"

echo -n "Testing Service-Status... "
if systemctl is-active --quiet voip-dialer-linphone; then
    echo "✓ Läuft"
    SERVICE_RUNNING=true
else
    echo "⚠ Gestoppt"
    SERVICE_RUNNING=false
fi

echo

# 8. GPIO (falls verfügbar)
echo "8. GPIO-System:"
if [ -c /dev/gpiomem ]; then
    test_check "GPIO-Device" "[ -c /dev/gpiomem ]"
    test_check "GPIO-Berechtigungen" "[ -r /dev/gpiomem ]"
    GPIO_OK=true
else
    echo "   ⚠ GPIO nicht verfügbar (normale Umgebung?)"
    GPIO_OK=false
fi

echo

# 9. Zusammenfassung
echo "=== Test-Zusammenfassung ==="
echo

if [ $ERRORS -eq 0 ]; then
    echo "🎉 Alle Tests bestanden!"
    OVERALL_STATUS="ERFOLG"
else
    echo "⚠ $ERRORS Tests fehlgeschlagen"
    OVERALL_STATUS="PROBLEME"
fi

echo
echo "Status-Details:"
echo "- Installation: $OVERALL_STATUS"
echo "- Linphone: $([ "$LINPHONE_CORE_OK" = true ] && echo "Voll funktionsfähig" || echo "Problematisch")"
echo "- Audio: $([ "$AUDIO_FUNCTIONAL" = true ] && echo "Funktional" || echo "Eingeschränkt")"
echo "- Codecs: $([ "$CODECS_OK" = true ] && echo "G.711 verfügbar" || echo "Begrenzt")"
echo "- Service: $([ "$SERVICE_RUNNING" = true ] && echo "Läuft" || echo "Gestoppt")"
echo "- GPIO: $([ "$GPIO_OK" = true ] && echo "Verfügbar" || echo "Nicht verfügbar")"
echo "- Konfiguration: $CONFIG_STATUS"

echo
echo "=== Empfehlungen ==="

if [ $ERRORS -gt 0 ]; then
    echo "Probleme beheben:"
    
    if [ "$LINPHONE_CORE_OK" = false ]; then
        echo "1. Linphone reparieren:"
        echo "   sudo apt-get install --reinstall liblinphone-dev python3-linphone"
        echo "   sudo /opt/voip-dialer/venv/bin/pip install --force-reinstall linphone"
    fi
    
    if [ "$AUDIO_FUNCTIONAL" = false ]; then
        echo "2. Audio-System prüfen:"
        echo "   sudo systemctl restart pulseaudio"
        echo "   arecord -l && aplay -l"
    fi
fi

if [ "$CONFIG_STATUS" != "CONFIGURED" ]; then
    echo "3. Konfiguration vervollständigen:"
    echo "   sudo nano /etc/voip-dialer/config.yml"
    echo "   - FreePBX-Server IP setzen"
    echo "   - SIP-Benutzername und Passwort eintragen"
    echo "   - Zielrufnummern konfigurieren"
fi

if [ "$SERVICE_RUNNING" = false ] && [ $ERRORS -eq 0 ]; then
    echo "4. Service starten:"
    echo "   sudo systemctl start voip-dialer-linphone"
    echo "   sudo systemctl status voip-dialer-linphone"
fi

echo
echo "Debugging-Kommandos:"
echo "- Live-Logs: sudo journalctl -u voip-dialer-linphone -f"
echo "- Konfiguration testen: /opt/voip-dialer/venv/bin/python3 /opt/voip-dialer/voip_dialer_linphone.py"
echo "- Audio-Test: arecord -d 5 test.wav && aplay test.wav"
echo "- Linphone-Version: python3 -c 'import linphone; print(linphone.Core.get_version())'"

echo
echo "Support-Informationen:"
echo "- OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')"
echo "- Hardware: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unbekannt')"
echo "- Python: $(/opt/voip-dialer/venv/bin/python3 --version)"

if [ "$LINPHONE_VENV" = true ]; then
    echo "- Linphone: $(/opt/voip-dialer/venv/bin/python3 -c 'import linphone; print(linphone.Core.get_version())' 2>/dev/null || echo 'Fehler')"
else
    echo "- Linphone: $(python3 -c 'import linphone; print(linphone.Core.get_version())' 2>/dev/null || echo 'Nicht verfügbar')"
fi

exit $ERRORS