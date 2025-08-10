#!/bin/bash
# Linphone VoIP Dialer Installation für Raspberry Pi
# Moderne, problemfreie Alternative zu PJSIP

set -e

echo "=== Linphone VoIP Dialer Installation ==="
echo "Moderne VoIP-Lösung ohne PJSIP-Kompilierungsprobleme"
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install-linphone-venv.sh)" 
   exit 1
fi

# System aktualisieren
echo "1. System wird aktualisiert..."
apt-get update
apt-get upgrade -y

# Systemabhängigkeiten installieren
echo "2. Systemabhängigkeiten werden installiert..."
apt-get install -y \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    build-essential \
    libasound2-dev \
    portaudio19-dev \
    git \
    alsa-utils \
    pkg-config \
    cmake \
    liblinphone-dev \
    liblinphone10 \
    linphone \
    pulseaudio \
    pulseaudio-utils

# Prüfe ob Linphone aus Repository verfügbar ist
echo "2a. Prüfe Linphone-Verfügbarkeit..."
if apt-cache show liblinphone-dev >/dev/null 2>&1; then
    echo "   ✓ Linphone aus Repository verfügbar"
    LINPHONE_FROM_REPO=true
else
    echo "   Repository-Linphone nicht verfügbar - installiere aus Flatpak/Snap"
    LINPHONE_FROM_REPO=false
    
    # Alternative Installation über Flatpak
    if command -v flatpak >/dev/null 2>&1; then
        echo "   Installiere Linphone über Flatpak..."
        flatpak install -y flathub org.linphone.Linphone
    fi
fi

# Verzeichnisse erstellen
echo "3. Projektverzeichnisse werden erstellt..."
mkdir -p /opt/voip-dialer
mkdir -p /etc/voip-dialer
mkdir -p /var/log

# Python Virtual Environment erstellen
echo "4. Python Virtual Environment wird erstellt..."
cd /opt/voip-dialer
python3 -m venv venv

# Python-Pakete installieren
echo "5. Python-Pakete werden installiert..."

# Requirements für Linphone-VoIP-Dialer
cat > /opt/voip-dialer/requirements.txt << 'EOF'
# Linphone VoIP Dialer Dependencies
RPi.GPIO>=0.7.1
PyYAML>=6.0
pyaudio>=0.2.11
linphone>=5.0.0
EOF

# Basis-Pakete installieren
/opt/voip-dialer/venv/bin/pip install --upgrade pip wheel setuptools
/opt/voip-dialer/venv/bin/pip install RPi.GPIO PyYAML pyaudio

# Linphone Python-Bindings installieren
echo "5a. Linphone Python-Bindings werden installiert..."
if /opt/voip-dialer/venv/bin/pip install linphone; then
    echo "   ✓ Linphone Python-Paket installiert"
    LINPHONE_PYTHON_OK=true
else
    echo "   ⚠ Pip-Installation fehlgeschlagen - versuche Alternative..."
    
    # Alternative: System-Paket verwenden
    if apt-get install -y python3-linphone; then
        echo "   ✓ System-Linphone Python-Paket installiert"
        LINPHONE_PYTHON_OK=true
    else
        echo "   ⚠ System-Paket auch nicht verfügbar"
        LINPHONE_PYTHON_OK=false
    fi
fi

echo "6. VoIP Dialer Anwendung wird installiert..."

# Hauptprogramm mit Linphone
cat > /opt/voip-dialer/voip_dialer_linphone.py << 'LINPHONE_EOF'
#!/opt/voip-dialer/venv/bin/python3
"""
Linphone VoIP Dialer Service für Raspberry Pi
Moderne Alternative zu PJSIP ohne Kompilierungsprobleme
"""

import sys
import time
import yaml
import logging
import threading
import signal
import os
from pathlib import Path

try:
    import linphone
    import RPi.GPIO as GPIO
    LINPHONE_AVAILABLE = True
except ImportError as e:
    print(f"Import-Fehler: {e}")
    print("Installieren Sie: apt-get install python3-linphone")
    LINPHONE_AVAILABLE = False
    sys.exit(1)

class LinphoneVoipDialer:
    def __init__(self, config_path="/etc/voip-dialer/config.yml"):
        self.config = self.load_config(config_path)
        self.core = None
        self.proxy_config = None
        self.current_call = None
        self.running = True
        
        # Logging konfigurieren
        self.setup_logging()
        self.logger.info("Linphone VoIP Dialer wird gestartet...")
        self.logger.info(f"Linphone Version: {linphone.Core.get_version()}")
        
        # Signal Handler
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
    def load_config(self, config_path):
        """YAML-Konfiguration laden"""
        try:
            with open(config_path, 'r', encoding='utf-8') as file:
                return yaml.safe_load(file)
        except FileNotFoundError:
            print(f"Konfigurationsdatei {config_path} nicht gefunden!")
            sys.exit(1)
        except yaml.YAMLError as e:
            print(f"Fehler beim Parsen der YAML-Datei: {e}")
            sys.exit(1)
    
    def setup_logging(self):
        """Logging-System konfigurieren"""
        log_config = self.config.get('logging', {})
        log_level = getattr(logging, log_config.get('level', 'INFO').upper())
        log_file = log_config.get('file', '/var/log/voip-dialer.log')
        
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        
        logging.basicConfig(
            level=log_level,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler(sys.stdout)
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def setup_gpio(self):
        """GPIO-Pins konfigurieren"""
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        
        button_config = self.config['gpio']['buttons']
        
        for button in button_config:
            pin = button['pin']
            GPIO.setup(pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
            GPIO.add_event_detect(
                pin, 
                GPIO.FALLING, 
                callback=self.button_callback,
                bouncetime=300
            )
            self.logger.info(f"GPIO Pin {pin} für '{button['name']}' konfiguriert")
    
    def setup_linphone(self):
        """Linphone Core konfigurieren"""
        try:
            # Linphone Core erstellen
            factory = linphone.Factory.get()
            self.core = factory.create_core(None, None, None)
            
            # Audio-Konfiguration
            audio_config = self.config.get('audio', {})
            
            # Echo-Cancellation konfigurieren
            if audio_config.get('echo_cancellation', True):
                self.core.enable_echo_cancellation(True)
                ec_tail = audio_config.get('echo_tail_length', 250)
                self.core.set_echo_cancellation_tail_length(ec_tail)
                self.logger.info(f"Echo-Cancellation aktiviert (Tail: {ec_tail}ms)")
            
            # Audio-Codecs konfigurieren
            # G.711 (ulaw/alaw) aktivieren
            payloads = self.core.audio_payload_types
            for payload in payloads:
                if payload.mime_type in ['PCMU', 'PCMA']:  # G.711 ulaw/alaw
                    self.core.enable_payload_type(payload, True)
                    self.logger.info(f"Codec aktiviert: {payload.mime_type}")
            
            # SIP-Account konfigurieren
            sip_config = self.config['sip']
            
            # Proxy-Konfiguration erstellen
            proxy_cfg = self.core.create_proxy_config()
            
            # Identity setzen
            identity = f"sip:{sip_config['username']}@{sip_config['server']}"
            proxy_cfg.identity_address = self.core.interpret_url(identity)
            
            # Server-Adresse setzen
            server_addr = f"sip:{sip_config['server']}"
            proxy_cfg.server_addr = server_addr
            
            # Authentifizierung
            auth_info = factory.create_auth_info(
                sip_config['username'],
                None,
                sip_config['password'],
                None,
                None,
                sip_config['server']
            )
            self.core.add_auth_info(auth_info)
            
            # Registrierung aktivieren
            proxy_cfg.register_enabled = True
            
            # Proxy zu Core hinzufügen
            self.core.add_proxy_config(proxy_cfg)
            self.core.default_proxy_config = proxy_cfg
            
            self.proxy_config = proxy_cfg
            
            self.logger.info(f"Linphone konfiguriert für {sip_config['server']}")
            
        except Exception as e:
            self.logger.error(f"Fehler bei Linphone-Setup: {e}")
            raise
    
    def button_callback(self, channel):
        """GPIO-Interrupt Callback"""
        if not self.running:
            return
        threading.Thread(target=self.handle_button_press, args=(channel,), daemon=True).start()
    
    def handle_button_press(self, pin):
        """Tastendruck verarbeiten"""
        self.logger.info(f"Tastendruck auf Pin {pin} erkannt")
        
        button_config = self.config['gpio']['buttons']
        target_number = None
        button_name = None
        
        for button in button_config:
            if button['pin'] == pin:
                target_number = button['number']
                button_name = button['name']
                break
        
        if target_number:
            self.logger.info(f"Anruf gestartet: {button_name} -> {target_number}")
            self.make_call(target_number)
        else:
            self.logger.warning(f"Keine Rufnummer für Pin {pin} konfiguriert")
    
    def make_call(self, number):
        """VoIP-Anruf mit Linphone"""
        if self.current_call and self.current_call.state != linphone.Call.State.End:
            self.logger.warning("Anruf bereits aktiv - neuer Anruf wird ignoriert")
            return
        
        try:
            sip_config = self.config['sip']
            call_uri = f"sip:{number}@{sip_config['server']}"
            
            # Anruf starten
            call_params = self.core.create_call_params(None)
            remote_addr = self.core.interpret_url(call_uri)
            
            self.current_call = self.core.invite_address_with_params(remote_addr, call_params)
            
            if self.current_call:
                self.logger.info(f"Anruf zu {number} gestartet")
                
                # Automatisches Auflegen nach konfigurierbarer Zeit
                call_duration = self.config['call'].get('duration_seconds', 30)
                threading.Timer(call_duration, self.auto_hangup).start()
            else:
                self.logger.error(f"Anruf zu {number} konnte nicht gestartet werden")
                
        except Exception as e:
            self.logger.error(f"Fehler beim Anruf zu {number}: {e}")
    
    def auto_hangup(self):
        """Automatisches Auflegen"""
        if self.current_call and self.current_call.state in [
            linphone.Call.State.StreamsRunning,
            linphone.Call.State.Connected,
            linphone.Call.State.OutgoingProgress
        ]:
            try:
                self.current_call.terminate()
                self.logger.info("Anruf automatisch beendet")
            except Exception as e:
                self.logger.error(f"Fehler beim automatischen Auflegen: {e}")
    
    def signal_handler(self, signum, frame):
        """Signal Handler"""
        self.logger.info(f"Signal {signum} empfangen - Beende Service...")
        self.running = False
        self.cleanup()
        sys.exit(0)
    
    def cleanup(self):
        """Ressourcen freigeben"""
        self.logger.info("Cleanup wird ausgeführt...")
        
        # Aktiven Anruf beenden
        if self.current_call:
            try:
                self.current_call.terminate()
            except:
                pass
        
        # GPIO cleanup
        try:
            GPIO.cleanup()
        except:
            pass
        
        # Linphone Core cleanup
        if self.core:
            try:
                # Unregistrierung
                if self.proxy_config:
                    self.proxy_config.register_enabled = False
                    # Kurz warten für Unregistrierung
                    for _ in range(10):
                        self.core.iterate()
                        time.sleep(0.1)
            except:
                pass
    
    def run(self):
        """Hauptschleife"""
        try:
            self.setup_gpio()
            self.setup_linphone()
            
            self.logger.info("Linphone VoIP Dialer läuft - warte auf Tastendruck...")
            
            # Hauptschleife mit Linphone iterate()
            while self.running:
                self.core.iterate()  # Linphone Event-Processing
                time.sleep(0.02)     # 50Hz Update-Rate
                
        except KeyboardInterrupt:
            self.logger.info("Beende durch Keyboard Interrupt...")
        except Exception as e:
            self.logger.error(f"Unerwarteter Fehler: {e}")
        finally:
            self.cleanup()

def main():
    """Hauptfunktion"""
    config_path = "/etc/voip-dialer/config.yml"
    
    if not os.path.exists(config_path):
        config_path = "config.yml"
    
    dialer = LinphoneVoipDialer(config_path)
    dialer.run()

if __name__ == "__main__":
    main()
LINPHONE_EOF

chmod +x /opt/voip-dialer/voip_dialer_linphone.py

echo "7. Konfigurationsdatei wird installiert..."

# Linphone-optimierte Konfiguration
cat > /etc/voip-dialer/config.yml << 'CONFIG_EOF'
# Linphone VoIP Dialer Konfiguration
# Moderne VoIP-Lösung ohne PJSIP-Probleme

# SIP/VoIP Server Konfiguration
sip:
  server: "192.168.1.100"          # ÄNDERN: IP-Adresse Ihres FreePBX Servers
  username: "1001"                 # ÄNDERN: SIP-Benutzername 
  password: "PASSWORT_HIER"        # ÄNDERN: SIP-Passwort
  local_port: 5060                 # Lokaler SIP-Port

# GPIO Button Konfiguration
gpio:
  buttons:
    - pin: 17                      # GPIO Pin 17
      name: "Taste 1"              # Beschreibung
      number: "100"                # ÄNDERN: Zielrufnummer
    
    - pin: 27                      # GPIO Pin 27  
      name: "Taste 2"              # Beschreibung
      number: "101"                # ÄNDERN: Zielrufnummer

# Anruf-Einstellungen
call:
  duration_seconds: 30             # Automatisches Auflegen nach X Sekunden
  auto_answer: false               # Automatisches Annehmen

# Audio-Konfiguration (Linphone modern)
audio:
  echo_cancellation: true          # Echo-Unterdrückung (Linphone-intern)
  echo_tail_length: 250           # Echo-Tail in ms (100-800)
  adaptive_rate_control: true     # Adaptive Bitrate
  noise_suppression: true         # Rauschunterdrückung
  automatic_gain_control: true    # Automatische Verstärkung

# Logging
logging:
  level: "INFO"                    # DEBUG, INFO, WARNING, ERROR
  file: "/var/log/voip-dialer.log"

# System
system:
  daemon: true
  technology: "linphone"           # Verwendet Linphone statt PJSIP
CONFIG_EOF

chmod 600 /etc/voip-dialer/config.yml

echo "8. Systemd Service wird installiert..."

# Systemd Service für Linphone-Version
cat > /etc/systemd/system/voip-dialer-linphone.service << 'SERVICE_EOF'
[Unit]
Description=Linphone VoIP Dialer Service for Raspberry Pi
Documentation=https://linphone.org/
After=network-online.target sound.target pulseaudio.service
Wants=network-online.target
Requires=sound.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/voip-dialer/venv/bin/python3 /opt/voip-dialer/voip_dialer_linphone.py
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
TimeoutStopSec=30s

# Umgebungsvariablen für Linphone
Environment=PYTHONPATH=/opt/voip-dialer:/opt/voip-dialer/venv/lib/python3.*/site-packages
Environment=PATH=/opt/voip-dialer/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=VIRTUAL_ENV=/opt/voip-dialer/venv
Environment=PULSE_RUNTIME_PATH=/var/run/pulse

# Working Directory
WorkingDirectory=/opt/voip-dialer

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=voip-dialer-linphone

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "9. Berechtigungen werden gesetzt..."
chown -R root:root /opt/voip-dialer
chmod +x /opt/voip-dialer/voip_dialer_linphone.py

# Audio für Linphone konfigurieren
echo "10. Audio-System wird für Linphone konfiguriert..."

# PulseAudio für root-User erlauben
if ! grep -q "load-module module-native-protocol-unix auth-anonymous=1" /etc/pulse/system.pa; then
    echo "load-module module-native-protocol-unix auth-anonymous=1" >> /etc/pulse/system.pa
fi

# ALSA-Konfiguration für Linphone optimieren
cat > /home/pi/.asoundrc << 'ASOUND_EOF'
pcm.!default {
    type pulse
}
ctl.!default {
    type pulse
}
ASOUND_EOF

# Service registrieren
echo "11. Service wird registriert..."
systemctl daemon-reload
systemctl enable voip-dialer-linphone.service

# Installation testen
echo "12. Installation wird getestet..."

echo "   Teste Python-Module..."
if /opt/voip-dialer/venv/bin/python3 -c "import RPi.GPIO, yaml; print('✓ Basis-Module OK')" 2>/dev/null; then
    BASE_OK=true
else
    BASE_OK=false
fi

echo "   Teste Linphone..."
if /opt/voip-dialer/venv/bin/python3 -c "import linphone; print('✓ Linphone verfügbar, Version:', linphone.Core.get_version())" 2>/dev/null; then
    LINPHONE_OK=true
elif python3 -c "import linphone; print('✓ System-Linphone verfügbar, Version:', linphone.Core.get_version())" 2>/dev/null; then
    LINPHONE_OK=true
    echo "   (Verwende System-Linphone)"
else
    LINPHONE_OK=false
fi

echo "   Teste Audio..."
if command -v arecord >/dev/null && arecord -l | grep -q card; then
    AUDIO_OK=true
else
    AUDIO_OK=false
fi

echo
echo "=== Linphone VoIP Dialer Installation abgeschlossen ==="
echo

if [ "$BASE_OK" = true ] && [ "$LINPHONE_OK" = true ]; then
    echo "🎉 Installation erfolgreich!"
    echo
    echo "✅ Vorteile der Linphone-Lösung:"
    echo "  ✓ Keine PJSIP-Kompilierungsprobleme"
    echo "  ✓ Keine WebRTC/NEON-Fehler"
    echo "  ✓ Keine Python 2/3-Konflikte"
    echo "  ✓ Moderne Echo-Cancellation"
    echo "  ✓ Bessere ARM-Kompatibilität"
    echo "  ✓ Aktive Entwicklung und Support"
    
    INSTALL_SUCCESS=true
else
    echo "⚠ Installation mit Problemen"
    INSTALL_SUCCESS=false
fi

echo
echo "NÄCHSTE SCHRITTE:"
echo "1. Konfiguration anpassen: sudo nano /etc/voip-dialer/config.yml"
echo "2. FreePBX-Server IP, Benutzername und Passwort eintragen"
echo "3. Zielrufnummern für GPIO-Tasten konfigurieren"

if [ "$INSTALL_SUCCESS" = true ]; then
    echo "4. Service starten: sudo systemctl start voip-dialer-linphone"
    echo "5. Status prüfen: sudo systemctl status voip-dialer-linphone"
    echo "6. Logs anzeigen: sudo journalctl -u voip-dialer-linphone -f"
else
    echo "4. ERST: Probleme beheben (siehe unten)"
fi

echo
echo "=== Status-Übersicht ==="
echo "- Basis-Module: $([ "$BASE_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- Linphone: $([ "$LINPHONE_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- Audio: $([ "$AUDIO_OK" = true ] && echo "✓ OK" || echo "⚠ Prüfen")"
echo "- Technology: Linphone (statt PJSIP)"

if [ "$LINPHONE_OK" = false ]; then
    echo
    echo "Linphone-Problem beheben:"
    echo "  sudo apt-get install python3-linphone liblinphone-dev"
    echo "  /opt/voip-dialer/venv/bin/pip install linphone"
fi

if [ "$AUDIO_OK" = false ]; then
    echo
    echo "Audio-Test:"
    echo "  arecord -l                    # Geräte auflisten"
    echo "  arecord -d 3 test.wav         # Test-Aufnahme"
    echo "  aplay test.wav                # Test-Wiedergabe"
fi

echo
echo "=== Service-Management ==="
echo "- Starten: sudo systemctl start voip-dialer-linphone"
echo "- Stoppen: sudo systemctl stop voip-dialer-linphone"
echo "- Status: sudo systemctl status voip-dialer-linphone"
echo "- Logs: sudo journalctl -u voip-dialer-linphone -f"
echo "- Neustart: sudo systemctl restart voip-dialer-linphone"

echo
echo "Virtual Environment:"
echo "- Python: /opt/voip-dialer/venv/bin/python3"
echo "- Programm: /opt/voip-dialer/voip_dialer_linphone.py"
echo "- Service: voip-dialer-linphone.service"

echo
echo "WARNUNG: Echte Notrufnummern nur im Notfall verwenden!"

exit $([ "$INSTALL_SUCCESS" = true ] && echo 0 || echo 1)