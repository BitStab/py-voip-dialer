#!/bin/bash
# Offizielles Linphone SDK mit Python-Bindings kompilieren
# Basiert auf: https://github.com/BelledonneCommunications/linphone-sdk

set -e

# Zeit-Tracking für Monitoring
START_TIME=$(date +%s)
export LINPHONE_BUILD_START_TIME=$START_TIME

echo "=== Linphone SDK Installation für Raspberry Pi ==="
echo "Kompiliert offizielle Linphone SDK mit Python-Bindings"
echo "Repository: https://github.com/BelledonneCommunications/linphone-sdk"
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install-linphone-sdk.sh)" 
   exit 1
fi

# System-Info anzeigen
echo "System-Information:"
echo "- Hardware: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unbekannt')"
echo "- Architektur: $(uname -m)"
echo "- OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')"
echo "- RAM: $(free -h | grep 'Mem:' | awk '{print $2}')"
echo

# Warnung über Kompilierzeit
echo "⚠️  WARNUNG: Linphone SDK Kompilierung"
echo "   - Dauer: 45-90 Minuten auf Raspberry Pi"
echo "   - RAM-Bedarf: Mindestens 2GB (Swap wird automatisch konfiguriert)"
echo "   - Speicher: ~3GB für Quellcode und Build"
echo

read -p "Fortfahren? (yes/nein): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Installation abgebrochen."
    exit 0
fi

# System aktualisieren
echo "1. System wird aktualisiert..."
apt-get update
apt-get upgrade -y

# Build-Dependencies installieren
echo "2. Build-Dependencies werden installiert..."
apt-get install -y \
    build-essential \
    cmake \
    git \
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    pkg-config \
    libssl-dev \
    libsqlite3-dev \
    libxml2-dev \
    libzlib1g-dev \
    libasound2-dev \
    pulseaudio \
    libpulse-dev \
    libspeex-dev \
    libspeexdsp-dev \
    libgsm1-dev \
    libopus-dev \
    libvpx-dev \
    libbcg729-dev \
    libsrtp2-dev \
    libavcodec-dev \
    libavformat-dev \
    libavdevice-dev \
    libswscale-dev \
    libv4l-dev \
    libudev-dev \
    intltool \
    nasm \
    yasm

# RAM prüfen und Swap konfigurieren
echo "3. Speicher wird konfiguriert..."
TOTAL_RAM=$(free -m | grep 'Mem:' | awk '{print $2}')
echo "   Verfügbarer RAM: ${TOTAL_RAM}MB"

if [ "$TOTAL_RAM" -lt 2048 ]; then
    echo "   Wenig RAM - Swap wird erhöht..."
    
    # Backup der aktuellen Swap-Konfiguration
    if [ -f /etc/dphys-swapfile ]; then
        cp /etc/dphys-swapfile /etc/dphys-swapfile.backup
        
        # Swap auf 2GB erhöhen
        sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
        
        # Swap neu starten
        dphys-swapfile swapoff || true
        dphys-swapfile setup
        dphys-swapfile swapon
        
        echo "   ✓ Swap auf 2GB erhöht"
    fi
fi

# Arbeitsverzeichnis erstellen
echo "4. Arbeitsverzeichnis wird vorbereitet..."
BUILD_DIR="/tmp/linphone-sdk-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Linphone SDK klonen
echo "5. Linphone SDK wird heruntergeladen..."
echo "   Klone Linphone SDK Repository..."
git clone --recursive https://github.com/BelledonneCommunications/linphone-sdk.git
cd linphone-sdk

echo "   Repository-Info:"
echo "   - Commit: $(git rev-parse --short HEAD)"
echo "   - Branch: $(git branch --show-current)"
echo "   - Submodules: $(git submodule status | wc -l) Module"

# Build-Verzeichnis erstellen
echo "6. Build-Konfiguration wird erstellt..."
mkdir -p build
cd build

# CMake-Konfiguration für Raspberry Pi optimiert
echo "7. CMake-Konfiguration..."
echo "   Konfiguriere für ARM/Raspberry Pi..."

cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DENABLE_PYTHON_WRAPPER=ON \
    -DENABLE_CSHARP_WRAPPER=OFF \
    -DENABLE_JAVA_WRAPPER=OFF \
    -DENABLE_SWIFT_WRAPPER=OFF \
    -DENABLE_VIDEO=OFF \
    -DENABLE_ADVANCED_IM=OFF \
    -DENABLE_DB_STORAGE=ON \
    -DENABLE_LDAP=OFF \
    -DENABLE_LIME_X3DH=OFF \
    -DENABLE_WEBRTC_AEC=OFF \
    -DENABLE_WEBRTC_AECM=OFF \
    -DENABLE_MKV=OFF \
    -DENABLE_OPENH264=OFF \
    -DENABLE_VPX=OFF \
    -DENABLE_FFMPEG=OFF \
    -DENABLE_V4L=OFF \
    -DENABLE_PCAP=OFF \
    -DENABLE_POLARSSL=OFF \
    -DENABLE_MBEDTLS=ON \
    -DENABLE_OPUS=ON \
    -DENABLE_SPEEX=ON \
    -DENABLE_GSM=ON \
    -DENABLE_BV16=OFF \
    -DENABLE_SILK=OFF \
    -DENABLE_G729=ON \
    -DENABLE_G729B_CNG=ON \
    -DENABLE_SRTP=ON \
    -DENABLE_ZRTP=ON \
    -DENABLE_DTLS=ON \
    -DENABLE_ECHO_CANCELLATION=ON \
    -DENABLE_NOISE_GATE=ON \
    -DPYTHON_EXECUTABLE=$(which python3) \
    -DCMAKE_C_FLAGS="-O2 -DNDEBUG -DPJ_HAS_IPV6=1" \
    -DCMAKE_CXX_FLAGS="-O2 -DNDEBUG" \
    -DCMAKE_VERBOSE_MAKEFILE=ON

echo "   ✓ CMake-Konfiguration abgeschlossen"

# Anzahl CPU-Kerne ermitteln
CPU_CORES=$(nproc)
MAKE_JOBS=$((CPU_CORES > 4 ? 4 : CPU_CORES))  # Max 4 parallele Jobs
echo "   Build mit $MAKE_JOBS parallelen Jobs (von $CPU_CORES Kernen)"

# Kompilierung starten
echo "8. Linphone SDK wird kompiliert..."
echo "   ⏱️  Dies dauert 45-90 Minuten..."
echo "   Start: $(date)"

# Progress-Monitoring im Hintergrund
(
    while [ ! -f /tmp/linphone_build_done ]; do
        sleep 300  # Alle 5 Minuten
        echo "   📊 Build läuft... $(date) - Memory: $(free -h | grep 'Mem:' | awk '{print $3 "/" $2}')"
        
        # Build-Fortschritt schätzen (falls möglich)
        if [ -d "WORK" ]; then
            BUILT_LIBS=$(find WORK -name "*.so" -o -name "*.a" | wc -l)
            echo "   📚 Bibliotheken kompiliert: $BUILT_LIBS"
        fi
    done
) &
MONITOR_PID=$!

# Hauptkompilierung
if make -j$MAKE_JOBS; then
    touch /tmp/linphone_build_done
    kill $MONITOR_PID 2>/dev/null || true
    echo "   ✓ Kompilierung erfolgreich abgeschlossen"
    echo "   Ende: $(date)"
else
    touch /tmp/linphone_build_done
    kill $MONITOR_PID 2>/dev/null || true
    echo "   ✗ Kompilierung fehlgeschlagen!"
    
    echo "   Versuche Single-Thread Build..."
    if make -j1; then
        echo "   ✓ Single-Thread Kompilierung erfolgreich"
    else
        echo "   ✗ Auch Single-Thread Build fehlgeschlagen"
        exit 1
    fi
fi

# Installation
echo "9. Linphone SDK wird installiert..."
make install

# ldconfig aktualisieren
echo "10. Library-Cache wird aktualisiert..."
ldconfig

# Python Virtual Environment für VoIP Dialer
echo "11. VoIP Dialer Virtual Environment wird erstellt..."
mkdir -p /opt/voip-dialer
cd /opt/voip-dialer

# Virtual Environment erstellen
python3 -m venv venv

# Basis-Pakete installieren
/opt/voip-dialer/venv/bin/pip install --upgrade pip wheel setuptools
/opt/voip-dialer/venv/bin/pip install RPi.GPIO PyYAML

# Linphone Python-Bindings installieren
echo "12. Linphone Python-Bindings werden installiert..."

# Linphone Python Wrapper finden und installieren
LINPHONE_PYTHON_BUILD="$BUILD_DIR/linphone-sdk/build/linphone-sdk/desktop/lib/python*/site-packages"
LINPHONE_PYTHON_FILES=$(find $BUILD_DIR/linphone-sdk/build -path "*/python*/site-packages/linphone*" -type d 2>/dev/null | head -1)

if [ -n "$LINPHONE_PYTHON_FILES" ] && [ -d "$LINPHONE_PYTHON_FILES" ]; then
    echo "   Gefunden: $LINPHONE_PYTHON_FILES"
    
    # Site-packages Pfad im venv
    VENV_SITE_PACKAGES=$(/opt/voip-dialer/venv/bin/python3 -c "import site; print(site.getsitepackages()[0])")
    echo "   Installiere nach: $VENV_SITE_PACKAGES"
    
    # Kopiere Linphone Python-Module
    cp -r "$LINPHONE_PYTHON_FILES"/* "$VENV_SITE_PACKAGES/"
    
    echo "   ✓ Linphone Python-Bindings installiert"
    
    # Test der Installation
    echo "   Teste Linphone Python Import..."
    if /opt/voip-dialer/venv/bin/python3 -c "import linphone; print('✓ Linphone Python-Bindings funktionieren'); print('Version:', linphone.Core.get_version())" 2>/dev/null; then
        echo "   ✓ Import erfolgreich"
        LINPHONE_PYTHON_OK=true
    else
        echo "   ✗ Import fehlgeschlagen"
        LINPHONE_PYTHON_OK=false
    fi
else
    echo "   ✗ Python-Bindings nicht gefunden im Build"
    LINPHONE_PYTHON_OK=false
    
    # Alternative: Direkte Installation aus Build-Tree
    echo "   Versuche alternative Installation..."
    
    # Suche nach Python-Wrapper im gesamten Build-Tree
    PYTHON_WRAPPER_DIR=$(find "$BUILD_DIR/linphone-sdk" -name "python" -type d | grep -E "(wrapper|binding)" | head -1)
    
    if [ -n "$PYTHON_WRAPPER_DIR" ] && [ -d "$PYTHON_WRAPPER_DIR" ]; then
        echo "   Gefunden: $PYTHON_WRAPPER_DIR"
        cd "$PYTHON_WRAPPER_DIR"
        
        # Versuche setup.py Installation falls vorhanden
        if [ -f "setup.py" ]; then
            echo "   Installiere via setup.py..."
            /opt/voip-dialer/venv/bin/python3 setup.py install
            LINPHONE_PYTHON_OK=true
        else
            LINPHONE_PYTHON_OK=false
        fi
    fi
fi

# Swap zurücksetzen falls geändert
echo "13. System-Konfiguration wird zurückgesetzt..."
if [ -f /etc/dphys-swapfile.backup ]; then
    echo "   Setze Swap-Konfiguration zurück..."
    mv /etc/dphys-swapfile.backup /etc/dphys-swapfile
    dphys-swapfile swapoff || true
    dphys-swapfile setup
    dphys-swapfile swapon
    echo "   ✓ Swap-Konfiguration zurückgesetzt"
fi

# Cleanup
echo "14. Build-Verzeichnis wird bereinigt..."
cd /
rm -rf "$BUILD_DIR"
rm -f /tmp/linphone_build_done
echo "   ✓ Temporäre Dateien entfernt"

# VoIP Dialer Anwendung erstellen
echo "15. VoIP Dialer Anwendung wird installiert..."

cat > /opt/voip-dialer/voip_dialer_linphone_sdk.py << 'LINPHONE_SDK_EOF'
#!/opt/voip-dialer/venv/bin/python3
"""
VoIP Dialer mit offiziellem Linphone SDK
Kompiliert aus: https://github.com/BelledonneCommunications/linphone-sdk
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
    print(f"Linphone SDK Version: {linphone.Core.get_version()}")
except ImportError as e:
    print(f"Import-Fehler: {e}")
    print("Linphone SDK nicht verfügbar!")
    LINPHONE_AVAILABLE = False
    sys.exit(1)

class LinphoneSDKDialer:
    def __init__(self, config_path="/etc/voip-dialer/config.yml"):
        self.config = self.load_config(config_path)
        self.core = None
        self.proxy_config = None
        self.current_call = None
        self.running = True
        
        # Logging konfigurieren
        self.setup_logging()
        self.logger.info("Linphone SDK VoIP Dialer wird gestartet...")
        self.logger.info(f"Linphone SDK Version: {linphone.Core.get_version()}")
        
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
        """Linphone Core aus SDK konfigurieren"""
        try:
            # Factory und Core erstellen
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
            
            # Adaptive Rate Control
            if audio_config.get('adaptive_rate_control', True):
                self.core.adaptive_rate_control_enabled = True
                
            # Noise Suppression (falls verfügbar)
            if audio_config.get('noise_suppression', True):
                try:
                    self.core.enable_noise_suppression(True)
                    self.logger.info("Noise Suppression aktiviert")
                except:
                    self.logger.info("Noise Suppression nicht verfügbar")
            
            # Audio-Codecs konfigurieren
            self.configure_audio_codecs()
            
            # SIP-Account konfigurieren
            self.configure_sip_account()
            
            self.logger.info("Linphone SDK erfolgreich konfiguriert")
            
        except Exception as e:
            self.logger.error(f"Fehler bei Linphone-Setup: {e}")
            raise
    
    def configure_audio_codecs(self):
        """Audio-Codecs konfigurieren"""
        # Alle Codecs erst deaktivieren
        for payload in self.core.audio_payload_types:
            self.core.enable_payload_type(payload, False)
        
        # Nur gewünschte Codecs aktivieren
        desired_codecs = ['PCMU', 'PCMA', 'speex']  # G.711 ulaw/alaw, Speex
        
        for payload in self.core.audio_payload_types:
            if payload.mime_type.lower() in [codec.lower() for codec in desired_codecs]:
                self.core.enable_payload_type(payload, True)
                self.logger.info(f"Codec aktiviert: {payload.mime_type}")
    
    def configure_sip_account(self):
        """SIP-Account konfigurieren"""
        sip_config = self.config['sip']
        
        # Account-Parameters erstellen
        account_params = self.core.create_account_params()
        
        # Identity setzen
        identity = f"sip:{sip_config['username']}@{sip_config['server']}"
        identity_address = self.core.interpret_url(identity)
        account_params.identity_address = identity_address
        
        # Server-Adresse setzen  
        server_addr = f"sip:{sip_config['server']}"
        server_address = self.core.interpret_url(server_addr)
        account_params.server_address = server_address
        
        # Registrierung aktivieren
        account_params.register_enabled = True
        
        # Account erstellen
        account = self.core.create_account(account_params)
        
        # Authentifizierung
        auth_info = linphone.Factory.get().create_auth_info(
            sip_config['username'],
            None,
            sip_config['password'],
            None,
            None,
            sip_config['server']
        )
        self.core.add_auth_info(auth_info)
        
        # Account hinzufügen
        self.core.add_account(account)
        self.core.default_account = account
        
        self.logger.info(f"SIP-Account konfiguriert für {sip_config['server']}")
    
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
        """VoIP-Anruf mit Linphone SDK"""
        if self.current_call and self.current_call.state in [
            linphone.Call.State.StreamsRunning,
            linphone.Call.State.Connected,
            linphone.Call.State.OutgoingProgress
        ]:
            self.logger.warning("Anruf bereits aktiv - neuer Anruf wird ignoriert")
            return
        
        try:
            sip_config = self.config['sip']
            call_uri = f"sip:{number}@{sip_config['server']}"
            
            # Remote-Adresse erstellen
            remote_addr = self.core.interpret_url(call_uri)
            
            # Call-Parameters erstellen
            call_params = self.core.create_call_params(None)
            
            # Anruf starten
            self.current_call = self.core.invite_address_with_params(remote_addr, call_params)
            
            if self.current_call:
                self.logger.info(f"Anruf zu {number} gestartet")
                
                # Automatisches Auflegen
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
                if self.core.default_account:
                    account_params = self.core.default_account.params.clone()
                    account_params.register_enabled = False
                    self.core.default_account.params = account_params
                    
                    # Kurz warten für Unregistrierung
                    for _ in range(20):
                        self.core.iterate()
                        time.sleep(0.1)
            except:
                pass
    
    def run(self):
        """Hauptschleife"""
        try:
            self.setup_gpio()
            self.setup_linphone()
            
            self.logger.info("Linphone SDK VoIP Dialer läuft - warte auf Tastendruck...")
            
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
    
    dialer = LinphoneSDKDialer(config_path)
    dialer.run()

if __name__ == "__main__":
    main()
LINPHONE_SDK_EOF

chmod +x /opt/voip-dialer/voip_dialer_linphone_sdk.py

# Konfigurationsdatei
echo "16. Konfigurationsdatei wird erstellt..."
mkdir -p /etc/voip-dialer

cat > /etc/voip-dialer/config.yml << 'CONFIG_EOF'
# VoIP Dialer mit Linphone SDK
# Kompiliert aus: https://github.com/BelledonneCommunications/linphone-sdk

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

# Audio-Konfiguration (Linphone SDK)
audio:
  echo_cancellation: true          # Echo-Unterdrückung aktivieren
  echo_tail_length: 250           # Echo-Tail in ms (100-800)
  adaptive_rate_control: true     # Adaptive Bitrate
  noise_suppression: true         # Rauschunterdrückung

# Logging
logging:
  level: "INFO"                    # DEBUG, INFO, WARNING, ERROR
  file: "/var/log/voip-dialer.log"

# System
system:
  technology: "linphone-sdk"       # Linphone SDK aus offiziellem Repository
CONFIG_EOF

chmod 600 /etc/voip-dialer/config.yml

# Systemd Service
echo "17. Systemd Service wird erstellt..."
cat > /etc/systemd/system/voip-dialer-linphone-sdk.service << 'SERVICE_EOF'
[Unit]
Description=VoIP Dialer with Linphone SDK
Documentation=https://github.com/BelledonneCommunications/linphone-sdk
After=network-online.target sound.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/opt/voip-dialer/venv/bin/python3 /opt/voip-dialer/voip_dialer_linphone_sdk.py
Restart=on-failure
RestartSec=5s
WorkingDirectory=/opt/voip-dialer

# Umgebungsvariablen
Environment=PYTHONPATH=/opt/voip-dialer:/opt/voip-dialer/venv/lib/python3.*/site-packages
Environment=PATH=/opt/voip-dialer/venv/bin:/usr/local/bin:/usr/bin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/lib
Environment=VIRTUAL_ENV=/opt/voip-dialer/venv

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=voip-dialer-linphone-sdk

[Install]
WantedBy=multi-user.target
SERVICE_EOF

# Service registrieren
systemctl daemon-reload
systemctl enable voip-dialer-linphone-sdk.service

echo
echo "=== Linphone SDK Installation abgeschlossen ==="
echo

if [ "$LINPHONE_PYTHON_OK" = true ]; then
    echo "🎉 Installation erfolgreich!"
    echo
    echo "✅ Installierte Komponenten:"
    echo "  ✓ Linphone SDK (aus offiziellem Repository)"
    echo "  ✓ Python-Bindings (kompiliert)"
    echo "  ✓ VoIP Dialer Anwendung"
    echo "  ✓ Virtual Environment"
    echo "  ✓ Systemd Service"
    
    INSTALL_SUCCESS=true
else
    echo "⚠ Installation mit Python-Bindings Problemen"
    INSTALL_SUCCESS=false
fi

echo
echo "=== Nächste Schritte ==="
echo "1. Konfiguration anpassen: sudo nano /etc/voip-dialer/config.yml"
echo "2. FreePBX-Server IP, Benutzername und Passwort eintragen"
echo "3. Zielrufnummern für GPIO-Tasten konfigurieren"

if [ "$INSTALL_SUCCESS" = true ]; then
    echo "4. Service starten: sudo systemctl start voip-dialer-linphone-sdk"
    echo "5. Status prüfen: sudo systemctl status voip-dialer-linphone-sdk"
    echo "6. Logs anzeigen: sudo journalctl -u voip-dialer-linphone-sdk -f"
else
    echo "4. ERST: Python-Bindings Problem beheben"
fi

echo
echo "=== Installationsdetails ==="
echo "- Linphone SDK: /usr/local/lib/"
echo "- Python-Bindings: /opt/voip-dialer/venv/lib/python*/site-packages/"
echo "- Programm: /opt/voip-dialer/voip_dialer_linphone_sdk.py"
echo "- Service: voip-dialer-linphone-sdk.service"
echo "- Konfiguration: /etc/voip-dialer/config.yml"

if [ "$LINPHONE_PYTHON_OK" = true ]; then
    LINPHONE_VERSION=$(/opt/voip-dialer/venv/bin/python3 -c "import linphone; print(linphone.Core.get_version())" 2>/dev/null || echo "Unbekannt")
    echo "- Linphone Version: $LINPHONE_VERSION"
fi

echo
echo "Test-Befehle:"
echo "- Python-Bindings testen: /opt/voip-dialer/venv/bin/python3 -c 'import linphone; print(linphone.Core.get_version())'"
echo "- Konfiguration testen: /opt/voip-dialer/venv/bin/python3 /opt/voip-dialer/voip_dialer_linphone_sdk.py"
echo "- Service testen: sudo systemctl start voip-dialer-linphone-sdk"

echo
echo "Kompilierungszeit: $(($(date +%s) - START_TIME)) Sekunden"

exit $([ "$INSTALL_SUCCESS" = true ] && echo 0 || echo 1)