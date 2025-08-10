#!/usr/bin/env python3
"""
VoIP Dialer Service für Raspberry Pi
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
    print("Installieren Sie: pip install pjsua2 RPi.GPIO")
    sys.exit(1)

class VoipDialer:
    def __init__(self, config_path="config.yml"):
        self.config = self.load_config(config_path)
        self.endpoint = None
        self.account = None
        self.current_call = None
        self.running = True
        
        # Logging konfigurieren
        self.setup_logging()
        self.logger.info("VoIP Dialer wird gestartet...")
        
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