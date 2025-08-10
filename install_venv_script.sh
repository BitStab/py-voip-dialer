#!/bin/bash
# VoIP Dialer Installation Script mit Python Virtual Environment

set -e

echo "=== VoIP Dialer Installation (mit Python venv) ==="
echo "Dieses Script installiert den VoIP Dialer Service isoliert in einem Virtual Environment"
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install-venv.sh)" 
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
    libpjproject-dev \
    python3-pjproject \
    git \
    alsa-utils \
    pkg-config

# Verzeichnisse erstellen
echo "3. Projektverzeichnisse werden erstellt..."
mkdir -p /opt/voip-dialer
mkdir -p /etc/voip-dialer
mkdir -p /var/log

# Python Virtual Environment erstellen
echo "4. Python Virtual Environment wird erstellt..."
cd /opt/voip-dialer
python3 -m venv venv

# Virtual Environment aktivieren und Python-Pakete installieren
echo "5. Python-Pakete werden in Virtual Environment installiert..."

# Requirements Datei erstellen
cat > /opt/voip-dialer/requirements.txt << 'EOF'
# VoIP Dialer Python Dependencies für venv
pjsua2>=2.10
RPi.GPIO>=0.7.1
PyYAML>=6.0
pyaudio>=0.2.11
EOF

# Packages im venv installieren
/opt/voip-dialer/venv/bin/pip install --upgrade pip
/opt/voip-dialer/venv/bin/pip install wheel setuptools
/opt/voip-dialer/venv/bin/pip install -r /opt/voip-dialer/requirements.txt

echo "6. Anwendungsdateien werden installiert..."

# Hauptprogramm installieren (mit venv shebang)
cat > /opt/voip-dialer/voip_dialer.py << 'EOF'
#!/opt/voip-dialer/venv/bin/python3
"""
VoIP Dialer Service für Raspberry Pi mit Virtual Environment
Reagiert auf GPIO-Tastendruck und startet VoIP-Anrufe
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
    import pjsua2 as pj
    import RPi.GPIO as GPIO
except ImportError as e:
    print(f"Fehler beim Import: {e}")
    print("Virtual Environment korrekt aktiviert? Packages installiert?")
    sys.exit(1)

class VoipDialer:
    def __init__(self, config_path="/etc/voip-dialer/config.yml"):
        self.config = self.load_config(config_path)
        self.endpoint = None
        self.account = None
        self.current_call = None
        self.running = True
        
        # Logging konfigurieren
        self.setup_logging()
        self.logger.info("VoIP Dialer wird gestartet (Virtual Environment)...")
        self.logger.info(f"Python Version: {sys.version}")
        self.logger.info(f"Python Executable: {sys.executable}")
        
        # Signal Handler für sauberes Beenden
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
        
        # Log-Verzeichnis erstellen falls nicht vorhanden
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
            # Interrupt für Tastendruck registrieren
            GPIO.add_event_detect(
                pin, 
                GPIO.FALLING, 
                callback=self.button_callback,
                bouncetime=300  # Entprellung: 300ms
            )
            self.logger.info(f"GPIO Pin {pin} für Taste '{button['name']}' konfiguriert")
    
    def setup_sip(self):
        """SIP-Client konfigurieren und verbinden"""
        try:
            # PJSUA2 Endpoint erstellen
            ep_cfg = pj.EpConfig()
            self.endpoint = pj.Endpoint()
            self.endpoint.libCreate()
            
            # Endpoint konfigurieren
            self.endpoint.libInit(ep_cfg)
            
            # Transport (UDP) konfigurieren
            sip_config = self.config['sip']
            transport_cfg = pj.TransportConfig()
            transport_cfg.port = sip_config.get('local_port', 5060)
            self.endpoint.transportCreate(pj.PJSIP_TRANSPORT_UDP, transport_cfg)
            
            # Endpoint starten
            self.endpoint.libStart()
            
            # SIP-Account konfigurieren
            acc_cfg = pj.AccountConfig()
            acc_cfg.idUri = f"sip:{sip_config['username']}@{sip_config['server']}"
            acc_cfg.regConfig.registrarUri = f"sip:{sip_config['server']}"
            
            # Authentifizierung
            cred = pj.AuthCredInfo("digest", "*", sip_config['username'], 0, sip_config['password'])
            acc_cfg.sipConfig.authCreds.append(cred)
            
            # Account erstellen
            self.account = VoipAccount(self)
            self.account.create(acc_cfg)
            
            self.logger.info(f"SIP-Client verbunden mit {sip_config['server']}")
            
        except Exception as e:
            self.logger.error(f"Fehler bei SIP-Setup: {e}")
            raise
    
    def button_callback(self, channel):
        """Callback-Funktion für GPIO-Interrupt"""
        if not self.running:
            return
            
        # In separatem Thread ausführen um GPIO-Interrupt nicht zu blockieren
        threading.Thread(target=self.handle_button_press, args=(channel,), daemon=True).start()
    
    def handle_button_press(self, pin):
        """Tastendruck verarbeiten"""
        self.logger.info(f"Tastendruck auf Pin {pin} erkannt")
        
        # Entsprechende Rufnummer finden
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
        """VoIP-Anruf durchführen"""
        if self.current_call and self.current_call.isActive():
            self.logger.warning("Anruf bereits aktiv - neuer Anruf wird ignoriert")
            return
        
        try:
            sip_config = self.config['sip']
            call_uri = f"sip:{number}@{sip_config['server']}"
            
            call = VoipCall(self.account, self)
            call_param = pj.CallOpParam(True)
            
            self.current_call = call
            call.makeCall(call_uri, call_param)
            
            self.logger.info(f"Anruf zu {number} gestartet")
            
        except Exception as e:
            self.logger.error(f"Fehler beim Anruf zu {number}: {e}")
            self.current_call = None
    
    def signal_handler(self, signum, frame):
        """Signal Handler für sauberes Beenden"""
        self.logger.info(f"Signal {signum} empfangen - Beende Service...")
        self.running = False
        self.cleanup()
        sys.exit(0)
    
    def cleanup(self):
        """Ressourcen freigeben"""
        self.logger.info("Cleanup wird ausgeführt...")
        
        # Aktiven Anruf beenden
        if self.current_call and self.current_call.isActive():
            try:
                call_param = pj.CallOpParam()
                self.current_call.hangup(call_param)
            except:
                pass
        
        # GPIO cleanup
        try:
            GPIO.cleanup()
        except:
            pass
        
        # SIP cleanup
        if self.endpoint:
            try:
                self.endpoint.libDestroy()
            except:
                pass
    
    def run(self):
        """Hauptschleife"""
        try:
            self.setup_gpio()
            self.setup_sip()
            
            self.logger.info("VoIP Dialer Service läuft - warte auf Tastendruck...")
            
            # Hauptschleife - warten auf Events
            while self.running:
                time.sleep(1)
                
        except KeyboardInterrupt:
            self.logger.info("Beende durch Keyboard Interrupt...")
        except Exception as e:
            self.logger.error(f"Unerwarteter Fehler: {e}")
        finally:
            self.cleanup()

class VoipAccount(pj.Account):
    """SIP-Account Klasse"""
    
    def __init__(self, dialer):
        pj.Account.__init__(self)
        self.dialer = dialer
    
    def onRegState(self, prm):
        """Registrierungsstatus-Callback"""
        if prm.code == 200:
            self.dialer.logger.info("SIP-Registrierung erfolgreich")
        else:
            self.dialer.logger.warning(f"SIP-Registrierung fehlgeschlagen: {prm.code} {prm.reason}")

class VoipCall(pj.Call):
    """VoIP-Anruf Klasse"""
    
    def __init__(self, account, dialer):
        pj.Call.__init__(self, account)
        self.dialer = dialer
    
    def onCallState(self, prm):
        """Anrufstatus-Callback"""
        ci = self.getInfo()
        self.dialer.logger.info(f"Anrufstatus: {ci.stateText} ({ci.state})")
        
        # Anruf beenden nach konfigurierbarer Zeit
        if ci.state == pj.PJSIP_INV_STATE_CONFIRMED:
            call_duration = self.dialer.config['call'].get('duration_seconds', 30)
            threading.Timer(call_duration, self.auto_hangup).start()
        
        # Call reference löschen wenn beendet
        if ci.state == pj.PJSIP_INV_STATE_DISCONNECTED:
            self.dialer.current_call = None
    
    def auto_hangup(self):
        """Automatisches Auflegen nach konfigurierbarer Zeit"""
        if self.isActive():
            try:
                call_param = pj.CallOpParam()
                self.hangup(call_param)
                self.dialer.logger.info("Anruf automatisch beendet")
            except Exception as e:
                self.dialer.logger.error(f"Fehler beim automatischen Auflegen: {e}")
    
    def onCallMediaState(self, prm):
        """Media-Status Callback"""
        ci = self.getInfo()
        if ci.media:
            for mi in ci.media:
                if mi.type == pj.PJMEDIA_TYPE_AUDIO and mi.status == pj.PJSUA_CALL_MEDIA_ACTIVE:
                    # Audio-Stream mit lokalem Sound-Device verbinden
                    call_media = self.getMedia(mi.index)
                    aud_media = pj.AudioMedia.typecastFromMedia(call_media)
                    
                    # Capture device -> Call
                    cap_dev = pj.Endpoint.instance().audDevManager().getCaptureDevMedia()
                    cap_dev.startTransmit(aud_media)
                    
                    # Call -> Playback device  
                    play_dev = pj.Endpoint.instance().audDevManager().getPlaybackDevMedia()
                    aud_media.startTransmit(play_dev)

def main():
    """Hauptfunktion"""
    config_path = "/etc/voip-dialer/config.yml"
    
    # Fallback auf lokale config.yml wenn /etc/ nicht existiert
    if not os.path.exists(config_path):
        config_path = "config.yml"
    
    dialer = VoipDialer(config_path)
    dialer.run()

if __name__ == "__main__":
    main()
EOF

# Konfiguration (Template)
cat > /etc/voip-dialer/config.yml << 'EOF'
# VoIP Dialer Konfiguration (Virtual Environment Version)
# Pfad: /etc/voip-dialer/config.yml

# SIP/VoIP Server Konfiguration
sip:
  server: "192.168.1.100"          # ÄNDERN: IP-Adresse Ihres FreePBX Servers
  username: "1001"                 # ÄNDERN: SIP-Benutzername 
  password: "PASSWORT_HIER"        # ÄNDERN: SIP-Passwort
  local_port: 5060                 # Lokaler SIP-Port (Standard: 5060)

# GPIO Button Konfiguration
gpio:
  buttons:
    - pin: 17                      # GPIO Pin 17
      name: "Taste 1"              # Beschreibung
      number: "100"                # ÄNDERN: Zu wählende Nummer
    
    - pin: 27                      # GPIO Pin 27  
      name: "Taste 2"              # Beschreibung
      number: "101"                # ÄNDERN: Zu wählende Nummer

# Anruf-Einstellungen
call:
  duration_seconds: 30             # Automatisches Auflegen nach X Sekunden
  auto_answer: false               # Automatisches Annehmen eingehender Anrufe

# Audio-Konfiguration (RaspAudio Mic Ultra+)
audio:
  input_device: "default"          # Audio-Eingabegerät
  output_device: "default"         # Audio-Ausgabegerät
  sample_rate: 8000               # Samplerate für VoIP (8kHz Standard)
  echo_cancellation: true          # Echo-Unterdrückung aktivieren

# Logging-Konfiguration
logging:
  level: "INFO"                    # DEBUG, INFO, WARNING, ERROR
  file: "/var/log/voip-dialer.log" # Log-Datei Pfad
  max_size_mb: 10                  # Maximale Log-Dateigröße
  backup_count: 5                  # Anzahl Backup-Log-Dateien

# System-Einstellungen
system:
  daemon: true                     # Als Service/Daemon laufen
  pid_file: "/var/run/voip-dialer.pid"  # PID-Datei für Service
  venv_path: "/opt/voip-dialer/venv"     # Virtual Environment Pfad
EOF

# Systemd Service (mit venv-Python)
cat > /etc/systemd/system/voip-dialer.service << 'EOF'
[Unit]
Description=VoIP Dialer Service for Raspberry Pi (Virtual Environment)
Documentation=man:voip-dialer(8)
After=network-online.target sound.target
Wants=network-online.target
RequiredBy=multi-user.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/voip-dialer/venv/bin/python3 /opt/voip-dialer/voip_dialer.py
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s
TimeoutStopSec=30s

# Sicherheitseinstellungen
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log /var/run /tmp

# Umgebungsvariablen für Virtual Environment
Environment=PYTHONPATH=/opt/voip-dialer:/opt/voip-dialer/venv/lib/python3.9/site-packages
Environment=PATH=/opt/voip-dialer/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=VIRTUAL_ENV=/opt/voip-dialer/venv
Environment=PYTHONUNBUFFERED=1

# Working Directory
WorkingDirectory=/opt/voip-dialer

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=voip-dialer

[Install]
WantedBy=multi-user.target
EOF

echo "7. Berechtigungen werden gesetzt..."
chmod +x /opt/voip-dialer/voip_dialer.py
chmod 600 /etc/voip-dialer/config.yml
chown -R root:root /opt/voip-dialer
chown root:root /etc/voip-dialer/config.yml

# Virtual Environment Info ausgeben
echo "8. Virtual Environment wird verifiziert..."
echo "Python Version in venv:"
/opt/voip-dialer/venv/bin/python3 --version
echo "Installierte Pakete:"
/opt/voip-dialer/venv/bin/pip list

# Audio-Konfiguration für RaspAudio Mic Ultra+
echo "9. Audio wird konfiguriert..."

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
echo "10. Audio-Hardware wird getestet..."
arecord -l
aplay -l

# Service registrieren
echo "11. Service wird registriert..."
systemctl daemon-reload
systemctl enable voip-dialer.service

# Virtual Environment Test
echo "12. Virtual Environment wird getestet..."
if /opt/voip-dialer/venv/bin/python3 -c "import pjsua2, RPi.GPIO, yaml; print('Alle Module erfolgreich importiert!')"; then
    echo "✓ Virtual Environment erfolgreich konfiguriert"
else
    echo "✗ Fehler im Virtual Environment - Überprüfen Sie die Installation"
fi

echo
echo "=== Installation mit Virtual Environment abgeschlossen ==="
echo
echo "WICHTIGE NÄCHSTE SCHRITTE:"
echo "1. Konfiguration anpassen: sudo nano /etc/voip-dialer/config.yml"
echo "2. FreePBX-Server IP, Benutzername und Passwort eintragen"
echo "3. Zielrufnummern für die Tasten konfigurieren"
echo "4. Service starten: sudo systemctl start voip-dialer"
echo "5. Status prüfen: sudo systemctl status voip-dialer"
echo "6. Logs anzeigen: sudo journalctl -u voip-dialer -f"
echo
echo "Virtual Environment Details:"
echo "- Python Executable: /opt/voip-dialer/venv/bin/python3"
echo "- Packages installiert in: /opt/voip-dialer/venv/lib/python3.*/site-packages/"
echo "- Requirements: /opt/voip-dialer/requirements.txt"
echo
echo "Maintenance Commands:"
echo "- venv aktivieren: source /opt/voip-dialer/venv/bin/activate"
echo "- Packages aktualisieren: /opt/voip-dialer/venv/bin/pip install --upgrade -r /opt/voip-dialer/requirements.txt"
echo "- Neue Packages: /opt/voip-dialer/venv/bin/pip install <package>"
echo
echo "Audio-Test:"
echo "- Aufnahme testen: arecord -d 5 test.wav"
echo "- Wiedergabe testen: aplay test.wav"
echo
echo "Fehlerbehandlung:"
echo "- Log-Datei: tail -f /var/log/voip-dialer.log"
echo "- Service neustarten: sudo systemctl restart voip-dialer"
echo "- venv neu erstellen: sudo rm -rf /opt/voip-dialer/venv && sudo ./install-venv.sh"
echo
echo "WARNUNG: Denken Sie daran, echte Notrufnummern nur im Notfall zu verwenden!"