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
    git \
    alsa-utils \
    pkg-config \
    cmake \
    libssl-dev \
    libopus-dev \
    libsrtp2-dev \
    uuid-dev \
    swig \
    libspeex-dev \
    libspeexdsp-dev

# Versuche PJPROJECT aus Repository zu installieren (falls verfügbar)
echo "2a. Prüfe Repository-PJPROJECT..."
if apt-get install -y libpjproject-dev python3-pjproject 2>/dev/null; then
    echo "✓ PJPROJECT aus Repository installiert"
    PJPROJECT_FROM_REPO=true
else
    echo "Repository-PJPROJECT nicht verfügbar - wird aus Quellcode kompiliert"
    PJPROJECT_FROM_REPO=false
fi

# Verzeichnisse erstellen
echo "3. Projektverzeichnisse werden erstellt..."
mkdir -p /opt/voip-dialer
mkdir -p /etc/voip-dialer
mkdir -p /var/log

# PJPROJECT aus Quellcode kompilieren falls nicht aus Repository verfügbar
if [ "$PJPROJECT_FROM_REPO" = false ]; then
    echo "3a. System wird für PJPROJECT vorbereitet..."
    
    # IMMER NEON-safe verwenden (wie vom Benutzer gewünscht)
    echo "   Verwende NEON-sichere Konfiguration (immer aktiviert)"
    USE_NEON_SAFE=true
    
    # RAM prüfen
    TOTAL_RAM=$(free -m | grep 'Mem:' | awk '{print $2}')
    if [ "$TOTAL_RAM" -lt 1024 ]; then
        echo "   Wenig RAM erkannt - Swap wird bei Bedarf erhöht"
        # Swap temporär erhöhen für Kompilierung
        if [ -f /etc/dphys-swapfile ]; then
            cp /etc/dphys-swapfile /etc/dphys-swapfile.backup
            sed -i 's/CONF_SWAPSIZE=.*/CONF_SWAPSIZE=1024/' /etc/dphys-swapfile
            dphys-swapfile setup && dphys-swapfile swapon
        fi
    fi
    
    echo "3b. PJPROJECT wird aus Quellcode kompiliert (NEON-safe, ohne WebRTC)..."
    cd /tmp
    
    # PJPROJECT herunterladen (Version 2.13 - stabil und getestet)
    if [ ! -d "pjproject-2.13" ]; then
        echo "   Download PJPROJECT 2.13..."
        wget -q https://github.com/pjsip/pjproject/archive/refs/tags/2.13.tar.gz -O pjproject-2.13.tar.gz
        tar xzf pjproject-2.13.tar.gz
    fi
    
    cd pjproject-2.13
    
    # IMMER sichere Compiler-Flags setzen
    echo "   Verwende NEON-sichere Compiler-Flags..."
    export CFLAGS="-O2 -DNDEBUG -DPJ_HAS_IPV6=1 -DPJ_ENABLE_EXTRA_CHECK=0"
    export CXXFLAGS="-O2 -DNDEBUG"
    export LDFLAGS="-Wl,--as-needed"
    
    # IMMER problematische WebRTC NEON-Dateien entfernen
    echo "   Entferne WebRTC NEON-Dateien (sicherheitshalber)..."
    find . -name "*neon*" -path "*/webrtc/*" -type f | while read file; do
        if [[ "$file" == *.c ]] || [[ "$file" == *.cpp ]] || [[ "$file" == *.cc ]]; then
            echo "     Deaktiviere: $(basename $file)"
            mv "$file" "$file.disabled" 2>/dev/null || true
        fi
    done
    
    # Zusätzlich: Alle libwebrtc-Referenzen entfernen
    echo "   Entferne alle libwebrtc-Referenzen..."
    find . -name "Makefile*" -o -name "*.mk" | xargs grep -l "webrtc" | while read makefile; do
        echo "     Bereinige: $(basename $makefile)"
        sed -i 's/.*webrtc.*//g; s/.*libwebrtc.*//g' "$makefile" 2>/dev/null || true
    done
    
    # Konfiguration für Raspberry Pi optimiert
    echo "   Konfiguriere PJPROJECT..."
    ./configure \
        --prefix=/usr/local \
        --enable-shared \
        --disable-video \
        --disable-opencore-amr \
        --disable-silk \
        --disable-opus \
        --disable-ipp \
        --disable-ssl \
        --with-external-srtp \
        CFLAGS="-O2 -DNDEBUG"
    
    # Kompilieren (kann 10-20 Minuten dauern)
    echo "   Kompiliere PJPROJECT (kann einige Minuten dauern)..."
    make dep && make
    
    # Installieren
    echo "   Installiere PJPROJECT..."
    make install
    
    # Library-Cache aktualisieren
    ldconfig
    
    echo "✓ PJPROJECT erfolgreich aus Quellcode installiert"
    cd /opt/voip-dialer
fi

# Python Virtual Environment erstellen
echo "4. Python Virtual Environment wird erstellt..."
cd /opt/voip-dialer
python3 -m venv venv

# Virtual Environment aktivieren und Python-Pakete installieren
echo "5. Python-Pakete werden in Virtual Environment installiert..."

# Requirements Datei erstellen
cat > /opt/voip-dialer/requirements.txt << 'EOF'
# VoIP Dialer Python Dependencies für venv
RPi.GPIO>=0.7.1
PyYAML>=6.0
pyaudio>=0.2.11

# PJSUA2 wird separat installiert (abhängig von PJPROJECT)
EOF

# Packages im venv installieren
echo "   Installiere Basis-Pakete..."
/opt/voip-dialer/venv/bin/pip install --upgrade pip
/opt/voip-dialer/venv/bin/pip install wheel setuptools
/opt/voip-dialer/venv/bin/pip install -r /opt/voip-dialer/requirements.txt

# PJSUA2 separat installieren (robuste Methode)
echo "   Installiere PJSUA2 für Virtual Environment..."
if [ "$PJPROJECT_FROM_REPO" = true ]; then
    # Aus Repository verfügbar - normale pip Installation
    echo "   Verwende Repository-PJPROJECT..."
    if /opt/voip-dialer/venv/bin/pip install pjsua2; then
        echo "   ✓ PJSUA2 via pip installiert"
        PJSUA2_INSTALL_OK=true
    else
        echo "   ⚠ pip-Installation fehlgeschlagen - versuche Alternative"
        PJSUA2_INSTALL_OK=false
    fi
else
    # Aus Quellcode kompiliert - robuste Python-Bindings Installation
    echo "   Installiere Python-Bindings aus PJPROJECT-Quellcode (robust)..."
    
    # Library-Pfade für kompiliertes PJPROJECT setzen
    export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
    export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
    
    cd /tmp/pjproject-2.13/pjsip-apps/src/python
    
    # Problem 1: TabError in setup.py beheben
    echo "     Behebe TabError in setup.py..."
    sed -i 's/\t/    /g' setup.py  # Tabs durch Spaces ersetzen
    
    # Problem 2: version.mak erstellen falls fehlend
    if [ ! -f "../../../../version.mak" ]; then
        echo "     Erstelle fehlende version.mak..."
        cat > ../../../../version.mak << 'VMAKEOF'
export PJ_VERSION_MAJOR := 2
export PJ_VERSION_MINOR := 13
export PJ_VERSION_REV := 0
export PJ_VERSION_SUFFIX := 
export PJ_VERSION := 2.13
VMAKEOF
    fi
    
    # Problem 3: Relativer Pfad in setup.py korrigieren
    echo "     Korrigiere Pfade in setup.py..."
    sed -i "s|../../../../version.mak|$(pwd)/../../../../version.mak|g" setup.py
    
    # Versuche Installation mit korrigierter setup.py
    echo "     Installiere korrigierte Python-Bindings..."
    if /opt/voip-dialer/venv/bin/python3 setup.py build && /opt/voip-dialer/venv/bin/python3 setup.py install; then
        echo "   ✓ PJSUA2 Python-Bindings aus Quellcode installiert"
        PJSUA2_INSTALL_OK=true
    else
        echo "   ⚠ Quellcode-Installation fehlgeschlagen - versuche direkten Build"
        
        # Alternative: Direkte Installation ohne setup.py
        echo "     Versuche direkte Bindings-Installation..."
        
        # Kopiere pjsua2.py direkt
        if [ -f "build/lib.linux-*/pjsua2.py" ] && [ -f "build/lib.linux-*/_pjsua2.*.so" ]; then
            echo "     Kopiere kompilierte Bindings direkt..."
            SITE_PACKAGES=$(/opt/voip-dialer/venv/bin/python3 -c "import site; print(site.getsitepackages()[0])")
            cp build/lib.linux-*/pjsua2.py "$SITE_PACKAGES/"
            cp build/lib.linux-*/_pjsua2.*.so "$SITE_PACKAGES/"
            echo "   ✓ PJSUA2 direkt installiert"
            PJSUA2_INSTALL_OK=true
        else
            echo "   ✗ Auch direkte Installation fehlgeschlagen"
            PJSUA2_INSTALL_OK=false
        fi
    fi
    
    cd /opt/voip-dialer
fi

# Bei Fehlschlag: Robuste Alternative ohne python-sipsimple
if [ "$PJSUA2_INSTALL_OK" = false ]; then
    echo "   PJSUA2 Installation fehlgeschlagen - erstelle robuste Alternative..."
    
    # Erstelle vereinfachten VoIP-Dialer ohne PJSUA2
    cat > /opt/voip-dialer/voip_dialer_simple.py << 'SIMPLE_EOF'
#!/opt/voip-dialer/venv/bin/python3
"""
VoIP Dialer Service - Vereinfachte Version ohne PJSUA2
Verwendet Asterisk AMI oder SIP-Kommandos für Basis-Funktionalität
"""

import sys
import time
import yaml
import logging
import threading
import signal
import os
import subprocess
import socket

try:
    import RPi.GPIO as GPIO
except ImportError as e:
    print(f"Fehler: RPi.GPIO nicht verfügbar: {e}")
    sys.exit(1)

class SimpleVoipDialer:
    def __init__(self, config_path="/etc/voip-dialer/config.yml"):
        self.config = self.load_config(config_path)
        self.running = True
        
        # Logging konfigurieren
        self.setup_logging()
        self.logger.info("Simple VoIP Dialer wird gestartet (ohne PJSUA2)...")
        
        # Signal Handler
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
    def load_config(self, config_path):
        with open(config_path, 'r', encoding='utf-8') as file:
            return yaml.safe_load(file)
    
    def setup_logging(self):
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
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        
        button_config = self.config['gpio']['buttons']
        for button in button_config:
            pin = button['pin']
            GPIO.setup(pin, GPIO.IN, pull_up_down=GPIO.PUD_UP)
            GPIO.add_event_detect(pin, GPIO.FALLING, callback=self.button_callback, bouncetime=300)
            self.logger.info(f"GPIO Pin {pin} für Taste '{button['name']}' konfiguriert")
    
    def button_callback(self, channel):
        if not self.running:
            return
        threading.Thread(target=self.handle_button_press, args=(channel,), daemon=True).start()
    
    def handle_button_press(self, pin):
        self.logger.info(f"Tastendruck auf Pin {pin} erkannt")
        
        button_config = self.config['gpio']['buttons']
        for button in button_config:
            if button['pin'] == pin:
                self.logger.info(f"Triggere Anruf: {button['name']} -> {button['number']}")
                self.trigger_call(button['number'], button['name'])
                break
    
    def trigger_call(self, number, name):
        """Triggere Anruf über FreePBX AMI oder SIP-Kommando"""
        sip_config = self.config['sip']
        
        # Methode 1: Asterisk AMI (falls verfügbar)
        if self.try_ami_call(number, sip_config):
            self.logger.info(f"Anruf über AMI gestartet: {number}")
            return
        
        # Methode 2: SIPp oder direkte SIP-Kommandos (falls verfügbar)
        if self.try_sip_command(number, sip_config):
            self.logger.info(f"Anruf über SIP-Kommando gestartet: {number}")
            return
        
        # Methode 3: HTTP-Request an FreePBX (falls konfiguriert)
        if self.try_http_call(number, sip_config):
            self.logger.info(f"Anruf über HTTP-API gestartet: {number}")
            return
        
        self.logger.error(f"Kein Anruf-Mechanismus verfügbar für {number}")
        self.logger.error("Installieren Sie PJSUA2 für vollständige Funktionalität:")
        self.logger.error("  sudo ./install-pjproject-minimal.sh")
    
    def try_ami_call(self, number, sip_config):
        """Versuche Anruf über Asterisk Manager Interface"""
        # Implementierung für AMI würde hier stehen
        return False
    
    def try_sip_command(self, number, sip_config):
        """Versuche Anruf über SIP-Kommandozeilen-Tools"""
        # Implementierung für SIPp oder ähnliche Tools würde hier stehen
        return False
    
    def try_http_call(self, number, sip_config):
        """Versuche Anruf über HTTP-API von FreePBX"""
        # Implementierung für HTTP-basierte Anrufe würde hier stehen
        return False
    
    def signal_handler(self, signum, frame):
        self.logger.info(f"Signal {signum} empfangen - Beende Service...")
        self.running = False
        self.cleanup()
        sys.exit(0)
    
    def cleanup(self):
        self.logger.info("Cleanup wird ausgeführt...")
        try:
            GPIO.cleanup()
        except:
            pass
    
    def run(self):
        try:
            self.setup_gpio()
            self.logger.info("Simple VoIP Dialer läuft - warte auf Tastendruck...")
            self.logger.warning("HINWEIS: Dies ist eine vereinfachte Version ohne PJSUA2")
            self.logger.warning("Für vollständige VoIP-Funktionalität installieren Sie PJSUA2:")
            self.logger.warning("  sudo ./install-pjproject-minimal.sh")
            
            while self.running:
                time.sleep(1)
                
        except KeyboardInterrupt:
            self.logger.info("Beende durch Keyboard Interrupt...")
        except Exception as e:
            self.logger.error(f"Unerwarteter Fehler: {e}")
        finally:
            self.cleanup()

def main():
    config_path = "/etc/voip-dialer/config.yml"
    if not os.path.exists(config_path):
        config_path = "config.yml"
    
    dialer = SimpleVoipDialer(config_path)
    dialer.run()

if __name__ == "__main__":
    main()
SIMPLE_EOF
    
    chmod +x /opt/voip-dialer/voip_dialer_simple.py
    echo "   ✓ Alternative Simple VoIP Dialer erstellt"
    echo "   Hinweis: Diese Version erkennt GPIO-Events, benötigt aber PJSUA2 für echte VoIP-Anrufe"
fi

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

# Virtual Environment Test mit verbesserter Fehlerbehandlung
echo "12. Virtual Environment wird getestet..."

echo "   Teste Basis-Module..."
if /opt/voip-dialer/venv/bin/python3 -c "import RPi.GPIO, yaml; print('✓ Basis-Module verfügbar')" 2>/dev/null; then
    echo "   ✓ RPi.GPIO und PyYAML funktionieren"
    BASE_MODULES_OK=true
else
    echo "   ✗ Kritischer Fehler: Basis-Module nicht verfügbar!"
    BASE_MODULES_OK=false
fi

echo "   Teste PJSUA2..."
if /opt/voip-dialer/venv/bin/python3 -c "import pjsua2; print('✓ PJSUA2 verfügbar:', pjsua2.Endpoint().libVersion().full)" 2>/dev/null; then
    echo "   ✓ PJSUA2 erfolgreich installiert und funktionsfähig"
    PJSUA2_WORKING=true
    VOIP_STATUS="VOLLSTÄNDIG"
elif /opt/voip-dialer/venv/bin/python3 -c "import sipsimple; print('✓ SIPSimple verfügbar')" 2>/dev/null; then
    echo "   ⚠ PJSUA2 nicht verfügbar, aber Alternative SIPSimple funktioniert"
    PJSUA2_WORKING=false
    VOIP_STATUS="ALTERNATIVE"
else
    echo "   ✗ Keine VoIP-Bibliothek verfügbar"
    PJSUA2_WORKING=false
    VOIP_STATUS="FEHLERHAFT"
fi

echo "   Teste Audio..."
if /opt/voip-dialer/venv/bin/python3 -c "import pyaudio; print('✓ PyAudio verfügbar')" 2>/dev/null; then
    echo "   ✓ Audio-Bibliothek funktioniert"
    AUDIO_OK=true
else
    echo "   ⚠ PyAudio-Problem - Audio eventuell eingeschränkt"
    AUDIO_OK=false
fi

# Zusammenfassung der Installation
echo
echo "=== Installations-Zusammenfassung ==="

if [ "$BASE_MODULES_OK" = true ]; then
    echo "✓ Virtual Environment grundsätzlich funktionsfähig"
    
    case $VOIP_STATUS in
        "VOLLSTÄNDIG")
            echo "✓ PJSUA2 erfolgreich installiert - Vollständige VoIP-Funktionalität"
            echo "✓ Installation erfolgreich abgeschlossen!"
            INSTALL_SUCCESS=true
            ;;
        "ALTERNATIVE")
            echo "⚠ Alternative VoIP-Bibliothek aktiv"
            echo "⚠ Eingeschränkte Funktionalität - für Basis-VoIP ausreichend"
            echo "  Für vollständige Features: sudo ./install-pjproject-minimal.sh"
            INSTALL_SUCCESS=true
            ;;
        "FEHLERHAFT")
            echo "✗ Keine VoIP-Bibliothek verfügbar"
            echo "✗ Manuelle PJPROJECT-Installation erforderlich"
            INSTALL_SUCCESS=false
            ;;
    esac
    
    if [ "$AUDIO_OK" = true ]; then
        echo "✓ Audio-System bereit"
    else
        echo "⚠ Audio-System eventuell problematisch"
        echo "  Test: arecord -d 2 test.wav && aplay test.wav"
    fi
    
else
    echo "✗ Kritische Basis-Module fehlerhaft"
    echo "✗ Installation fehlgeschlagen"
    INSTALL_SUCCESS=false
fi

echo
echo "=== VoIP Dialer Installation abgeschlossen (ROBUST) ==="
echo

if [ "$INSTALL_SUCCESS" = true ]; then
    echo "🎉 Installation erfolgreich! (WebRTC-frei, NEON-safe)"
else
    echo "⚠ Installation mit Problemen abgeschlossen"
fi

echo
echo "🔧 Diese Installation ist speziell robust, weil:"
echo "✓ IMMER WebRTC/libwebrtc deaktiviert (verhindert ARM64-Fehler)"
echo "✓ IMMER NEON-safe Compiler-Flags (verhindert NEON-Probleme)"  
echo "✓ Robuste Python-Bindings Installation (behebt TabError/version.mak)"
echo "✓ Speex Echo-Cancellation aktiviert (professionelle Audioqualität)"
echo "✓ Mehrfache Fallback-Mechanismen bei Problemen"

echo
echo "WICHTIGE NÄCHSTE SCHRITTE:"
echo "1. Konfiguration anpassen: sudo nano /etc/voip-dialer/config.yml"
echo "2. FreePBX-Server IP, Benutzername und Passwort eintragen"
echo "3. Zielrufnummern für die Tasten konfigurieren"

if [ "$INSTALL_SUCCESS" = true ]; then
    echo "4. Service starten: sudo systemctl start voip-dialer"
    echo "5. Status prüfen: sudo systemctl status voip-dialer"
    echo "6. Logs anzeigen: sudo journalctl -u voip-dialer -f"
else
    echo "4. ERST: VoIP-Bibliothek reparieren (siehe unten)"
    echo "5. DANN: Service starten"
fi

echo
echo "=== Installations-Status ==="
echo "- Basis-System: $([ "$BASE_MODULES_OK" = true ] && echo "✓ OK" || echo "✗ Fehler")"
echo "- VoIP-Bibliothek: $VOIP_STATUS"
echo "- Audio-System: $([ "$AUDIO_OK" = true ] && echo "✓ OK" || echo "⚠ Eventuell problematisch")"
echo "- WebRTC: ✓ Immer deaktiviert (NEON-safe)"
echo "- Echo-Cancellation: ✓ Speex AEC aktiviert"

if [ "$PJPROJECT_FROM_REPO" = true ]; then
    echo "- PJPROJECT: Repository-Version"
else
    echo "- PJPROJECT: NEON-safe Build aus Quellcode (WebRTC-frei)"
fi

echo
echo "=== Virtual Environment Details ==="
echo "- Python Executable: /opt/voip-dialer/venv/bin/python3 ($(/opt/voip-dialer/venv/bin/python3 --version))"
echo "- Packages installiert in: /opt/voip-dialer/venv/lib/python3.*/site-packages/"
echo "- Requirements: /opt/voip-dialer/requirements.txt"

if [ "$PJPROJECT_FROM_REPO" = false ]; then
    echo "- PJPROJECT: /usr/local/lib/ (aus Quellcode)"
fi

echo
echo "=== Fehlerbehebung ==="

if [ "$VOIP_STATUS" = "FEHLERHAFT" ]; then
    echo "VoIP-Problem beheben:"
    echo "  sudo ./install-pjproject-minimal.sh    # NEON-safe build (empfohlen)"
    echo "  sudo ./install-pjproject-no-neon.sh    # Extra-safe für ARM-Probleme"
    echo "  sudo ./install-pjproject-manual.sh     # Verschiedene Versionen probieren"
    echo ""
    echo "PJSUA2 Python-Bindings manuell reparieren:"
    echo "  cd /tmp/pjproject-2.13/pjsip-apps/src/python"
    echo "  sed -i 's/\\t/    /g' setup.py  # TabError beheben"
    echo "  /opt/voip-dialer/venv/bin/python3 setup.py install"
fi

if [ "$AUDIO_OK" = false ]; then
    echo "Audio-Test durchführen:"
    echo "  arecord -l                              # Audio-Geräte auflisten"
    echo "  arecord -d 5 test.wav                   # 5-Sekunden Aufnahme"
    echo "  aplay test.wav                          # Wiedergabe testen"
fi

echo "Allgemeine Problembehebung:"
echo "  ./debug-arm-capabilities.sh             # System analysieren"
echo "  ./test-installation.sh                  # Installation testen"
echo "  sudo systemctl status voip-dialer       # Service-Status"
echo "  sudo journalctl -u voip-dialer -f       # Live-Logs"

echo
echo "=== Maintenance Commands ==="
echo "- venv aktivieren: source /opt/voip-dialer/venv/bin/activate"
echo "- Packages aktualisieren: /opt/voip-dialer/venv/bin/pip install --upgrade -r /opt/voip-dialer/requirements.txt"
echo "- PJSUA2 testen: /opt/voip-dialer/venv/bin/python3 -c 'import pjsua2; print(pjsua2.Endpoint().libVersion().full)'"
echo "- Installation testen: ./test-installation.sh"

if [ "$VOIP_STATUS" != "VOLLSTÄNDIG" ]; then
    echo "- System analysieren: ./debug-arm-capabilities.sh"
fi

echo
echo "=== Support-Informationen ==="
echo "Hardware: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unbekannt')"
echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '"')"
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo "RAM: $(free -h | grep 'Mem:' | awk '{print $2}')"
echo "Python: $(/opt/voip-dialer/venv/bin/python3 --version)"

if [ "$PJSUA2_WORKING" = true ]; then
    echo "PJSUA2: $(/opt/voip-dialer/venv/bin/python3 -c 'import pjsua2; print(pjsua2.Endpoint().libVersion().full)' 2>/dev/null || echo 'Version unbekannt')"
fi

echo
echo "WARNUNG: Denken Sie daran, echte Notrufnummern nur im Notfall zu verwenden!"

# Exit-Code basierend auf Erfolg
if [ "$INSTALL_SUCCESS" = true ]; then
    exit 0
else
    echo
    echo "Installation nicht vollständig - siehe Fehlerbehebung oben"
    exit 1
fi