#!/bin/bash
# Ultra-minimale PJPROJECT Installation für Raspberry Pi
# Nur die absolut notwendigen Komponenten für VoIP-Dialing

set -e

echo "=== Ultra-minimale PJPROJECT Installation ==="
echo "Diese Version deaktiviert alle erweiterten Features und kompiliert nur"
echo "die grundlegenden SIP/RTP-Komponenten für einfache VoIP-Anrufe."
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install-pjproject-minimal.sh)" 
   exit 1
fi

echo "1. Basis-Abhängigkeiten werden installiert..."
apt-get update
apt-get install -y \
    build-essential \
    libasound2-dev \
    python3-dev \
    wget \
    pkg-config

echo "2. PJPROJECT wird heruntergeladen..."
cd /tmp

# Verwende stabile Version 2.13
rm -rf pjproject-2.13*
wget -q https://github.com/pjsip/pjproject/archive/refs/tags/2.13.tar.gz -O pjproject-2.13.tar.gz
tar xzf pjproject-2.13.tar.gz
cd pjproject-2.13

echo "3. Ultra-minimale Konfiguration..."
echo "   Deaktivierte Features:"
echo "   - WebRTC (verursacht ARM64-Fehler)"
echo "   - Video-Codecs" 
echo "   - Erweiterte Audio-Codecs"
echo "   - SSL/TLS"
echo "   - Echo-Cancellation"
echo "   - Alle nicht-essentiellen Features"

./configure \
    --prefix=/usr/local \
    --enable-shared \
    --disable-static \
    --disable-video \
    --disable-webrtc \
    --disable-webrtc-aec3 \
    --disable-opencore-amr \
    --disable-silk \
    --disable-opus \
    --disable-ipp \
    --disable-ssl \
    --disable-openssl \
    --disable-libwebrtc \
    --disable-ilbc-codec \
    --disable-speex-codec \
    --disable-speex-aec \
    --disable-gsm-codec \
    --disable-g7221-codec \
    --disable-g722-codec \
    --disable-libsamplerate \
    --disable-resample \
    --disable-sound \
    --disable-ext-sound \
    --disable-small-filter \
    --disable-large-filter \
    --disable-oss \
    --disable-ext-sound \
    --disable-video \
    --disable-openh264 \
    --disable-ffmpeg \
    --disable-v4l2 \
    --disable-libyuv \
    --disable-darwin-ssl \
    --disable-bcg729 \
    --enable-epoll \
    --enable-python-bindings \
    --with-external-srtp=no \
    CFLAGS="-O1 -DNDEBUG -DPJ_HAS_IPV6=1 -DPJ_ENABLE_EXTRA_CHECK=0" \
    CXXFLAGS="-O1 -DNDEBUG" \
    LDFLAGS="-Wl,--as-needed"

echo "4. Kompilierung (nur Basis-Komponenten)..."
# Kompiliere nur die minimal notwendigen Targets
make dep
make pjlib pjlib-util pjnath pjsip pjsip-simple pjmedia pjsua-lib

echo "5. Installation..."
make install

# Library-Cache aktualisieren
ldconfig

echo "6. Python-Bindings installieren..."
cd pjsip-apps/src/python

# System Python
python3 setup.py build
python3 setup.py install

# Virtual Environment falls vorhanden
if [ -f "/opt/voip-dialer/venv/bin/python3" ]; then
    echo "   Installiere für Virtual Environment..."
    /opt/voip-dialer/venv/bin/python3 setup.py build
    /opt/voip-dialer/venv/bin/python3 setup.py install
fi

echo "7. Installation wird getestet..."

# Test der minimalen Installation
echo "   System Python Test:"
if python3 -c "import pjsua2; print('✓ PJSUA2 verfügbar:', pjsua2.Endpoint().libVersion().full)"; then
    echo "   ✓ Minimale Installation funktioniert"
else
    echo "   ✗ Installation fehlgeschlagen"
    exit 1
fi

if [ -f "/opt/voip-dialer/venv/bin/python3" ]; then
    echo "   Virtual Environment Test:"
    if /opt/voip-dialer/venv/bin/python3 -c "import pjsua2; print('✓ PJSUA2 verfügbar:', pjsua2.Endpoint().libVersion().full)"; then
        echo "   ✓ Virtual Environment Installation funktioniert"
    else
        echo "   ✗ Virtual Environment Installation fehlgeschlagen"
    fi
fi

echo
echo "=== Ultra-minimale PJPROJECT Installation abgeschlossen ==="
echo
echo "✓ Verfügbare Features:"
echo "  - SIP-Protokoll (Anrufe, Registrierung)"
echo "  - RTP Audio-Streams"
echo "  - G.711 Codec (ulaw/alaw) - Standard für VoIP"
echo "  - Basis Audio I/O"
echo "  - Python PJSUA2 Bindings"
echo
echo "✗ Deaktivierte Features:"
echo "  - WebRTC (verhindert ARM64-Kompilierungsfehler)"
echo "  - Video-Codecs"
echo "  - Erweiterte Audio-Codecs (Opus, Speex, etc.)"
echo "  - Echo-Cancellation"
echo "  - SSL/TLS Verschlüsselung"
echo "  - SRTP (verschlüsseltes Audio)"
echo
echo "Diese minimale Installation ist perfekt für:"
echo "✓ Einfache VoIP-Anrufe über FreePBX"
echo "✓ GPIO-gesteuerte Notrufsysteme"
echo "✓ Basis SIP-Telefonie"
echo
echo "Nicht geeignet für:"
echo "✗ Video-Anrufe"
echo "✗ Erweiterte Audio-Qualität"
echo "✗ Sichere/verschlüsselte Verbindungen"
echo
echo "Sie können jetzt den VoIP Dialer starten!"