#!/bin/bash
# Manuelle PJPROJECT Installation für Raspberry Pi
# Verwenden Sie dieses Script falls die automatische Installation fehlschlägt

set -e

echo "=== Manuelle PJPROJECT Installation ==="
echo

# Root-Rechte prüfen
if [[ $EUID -ne 0 ]]; then
   echo "Fehler: Dieses Script muss als root ausgeführt werden (sudo ./install-pjproject-manual.sh)" 
   exit 1
fi

echo "1. Abhängigkeiten werden installiert..."
apt-get update
apt-get install -y \
    build-essential \
    libasound2-dev \
    libssl-dev \
    libopus-dev \
    libsrtp2-dev \
    uuid-dev \
    swig \
    python3-dev \
    wget \
    cmake \
    pkg-config

echo "2. PJPROJECT Quellcode wird heruntergeladen..."
cd /tmp

# Verschiedene Versionen zum Testen
PJPROJECT_VERSIONS=("2.13" "2.12.1" "2.11.1")

for VERSION in "${PJPROJECT_VERSIONS[@]}"; do
    echo "   Versuche PJPROJECT Version $VERSION..."
    
    # Cleanup vorheriger Versuche
    rm -rf pjproject-$VERSION*
    
    # Download
    if wget -q https://github.com/pjsip/pjproject/archive/refs/tags/$VERSION.tar.gz -O pjproject-$VERSION.tar.gz; then
        echo "   ✓ Download erfolgreich"
        tar xzf pjproject-$VERSION.tar.gz
        cd pjproject-$VERSION
        
        echo "3. PJPROJECT $VERSION wird konfiguriert..."
        
        # Konfiguration für Raspberry Pi
        if ./configure \
            --prefix=/usr/local \
            --enable-shared \
            --disable-video \
            --disable-opencore-amr \
            --disable-silk \
            --disable-opus \
            --disable-ipp \
            --with-external-srtp \
            --enable-python-bindings \
            CFLAGS="-O2 -DNDEBUG" \
            LDFLAGS="-Wl,--as-needed"; then
            
            echo "   ✓ Konfiguration erfolgreich"
            
            echo "4. PJPROJECT $VERSION wird kompiliert..."
            if make dep && make; then
                echo "   ✓ Kompilierung erfolgreich"
                
                echo "5. PJPROJECT $VERSION wird installiert..."
                if make install; then
                    echo "   ✓ Installation erfolgreich"
                    
                    # Library-Cache aktualisieren
                    ldconfig
                    
                    echo "6. Python-Bindings werden installiert..."
                    cd pjsip-apps/src/python
                    
                    # Für System-Python
                    if python3 setup.py build && python3 setup.py install; then
                        echo "   ✓ System Python-Bindings installiert"
                    fi
                    
                    # Für Virtual Environment (falls vorhanden)
                    if [ -f "/opt/voip-dialer/venv/bin/python3" ]; then
                        echo "   Installiere für Virtual Environment..."
                        if /opt/voip-dialer/venv/bin/python3 setup.py build && /opt/voip-dialer/venv/bin/python3 setup.py install; then
                            echo "   ✓ Virtual Environment Python-Bindings installiert"
                        fi
                    fi
                    
                    echo
                    echo "=== PJPROJECT $VERSION erfolgreich installiert ==="
                    echo
                    
                    # Test der Installation
                    echo "7. Installation wird getestet..."
                    
                    echo "   System Python Test:"
                    if python3 -c "import pjsua2; print('✓ PJSUA2 verfügbar:', pjsua2.Endpoint().libVersion().full)"; then
                        echo "   ✓ System-Installation funktioniert"
                    else
                        echo "   ✗ System-Installation fehlgeschlagen"
                    fi
                    
                    if [ -f "/opt/voip-dialer/venv/bin/python3" ]; then
                        echo "   Virtual Environment Test:"
                        if /opt/voip-dialer/venv/bin/python3 -c "import pjsua2; print('✓ PJSUA2 verfügbar:', pjsua2.Endpoint().libVersion().full)"; then
                            echo "   ✓ Virtual Environment-Installation funktioniert"
                        else
                            echo "   ✗ Virtual Environment-Installation fehlgeschlagen"
                        fi
                    fi
                    
                    echo
                    echo "Installation abgeschlossen!"
                    echo "Sie können jetzt den VoIP Dialer starten."
                    exit 0
                else
                    echo "   ✗ Installation von Version $VERSION fehlgeschlagen"
                fi
            else
                echo "   ✗ Kompilierung von Version $VERSION fehlgeschlagen"
            fi
        else
            echo "   ✗ Konfiguration von Version $VERSION fehlgeschlagen"
        fi
        
        cd /tmp
    else
        echo "   ✗ Download von Version $VERSION fehlgeschlagen"
    fi
done

echo
echo "✗ Alle PJPROJECT-Versionen fehlgeschlagen!"
echo
echo "Alternative Lösungen:"
echo "1. Verwenden Sie eine andere VoIP-Bibliothek (z.B. python-sipsimple)"
echo "2. Installieren Sie PJSUA2 über pip: pip install pjsua2"
echo "3. Prüfen Sie die Raspberry Pi OS Version und Updates"
echo
echo "Für Support erstellen Sie ein Issue mit folgenden Informationen:"
echo "- Raspberry Pi Modell: $(cat /proc/device-tree/model 2>/dev/null || echo 'Unbekannt')"
echo "- OS Version: $(cat /etc/os-release | grep PRETTY_NAME)"
echo "- Python Version: $(python3 --version)"
echo "- Architektur: $(uname -m)"
echo
echo "Debugging-Informationen:"
echo "- Build-Logs: /tmp/pjproject-*/config.log"
echo "- System-Pakete: apt list --installed | grep -E '(alsa|pulse|sip)'"