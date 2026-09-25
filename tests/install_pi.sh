#!/bin/sh
# install_pi.sh - installa tutto il necessario per far girare s32 su
# Raspberry Pi (output HDMI via KMSDRM, vedi docs/design.md e
# docs/raspberry_pi_setup.md). Da lanciare SUL Pi, non in sandbox:
#
#     sudo sh tests/install_pi.sh
#
# Idempotente: si puo' rilanciare senza danni se qualcosa e' gia' a
# posto (pacchetti gia' installati, overlay gia' presente, utente gia'
# nei gruppi giusti - ognuno di questi passi lo controlla prima di
# agire).
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve sudo (deve modificare pacchetti di sistema e config.txt): sudo sh $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
echo "== s32: installazione dipendenze per Raspberry Pi (utente: $REAL_USER) =="

# -----------------------------------------------------------
# 1) pacchetti: niente da compilare, a differenza del vecchio motore
#    Python/Cython - LuaJIT e SDL2 sono gia' pacchetti pronti nei repo
#    Raspberry Pi OS.
# -----------------------------------------------------------
echo "-- Pacchetti (apt) --"
apt-get update
apt-get install -y \
    git \
    luajit \
    libsdl2-2.0-0 \
    libgles2 \
    libegl1 \
    libgbm1

# -----------------------------------------------------------
# 2) driver video: serve il KMS PIENO (vc4-kms-v3d), non il fake-KMS
#    di default su alcune immagini - e' quello che nella sessione di
#    sviluppo ha sbloccato le prestazioni GPU vere via HDMI (vedi
#    docs/design.md "Target hardware e video"). Modifica config.txt
#    solo se serve, con backup.
# -----------------------------------------------------------
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_TXT=/boot/firmware/config.txt   # Raspberry Pi OS Bookworm+
else
    CONFIG_TXT=/boot/config.txt            # Raspberry Pi OS Bullseye e precedenti
fi
echo "-- Driver video (config.txt: $CONFIG_TXT) --"

if grep -q '^dtoverlay=vc4-kms-v3d' "$CONFIG_TXT" 2>/dev/null; then
    echo "   vc4-kms-v3d gia' attivo, nessuna modifica."
else
    cp "$CONFIG_TXT" "$CONFIG_TXT.bak.$(date +%s)"
    echo "   backup salvato accanto a $CONFIG_TXT"
    if grep -q '^dtoverlay=vc4-fkms-v3d' "$CONFIG_TXT" 2>/dev/null; then
        sed -i 's/^dtoverlay=vc4-fkms-v3d/dtoverlay=vc4-kms-v3d/' "$CONFIG_TXT"
        echo "   sostituito vc4-fkms-v3d -> vc4-kms-v3d"
    else
        echo "dtoverlay=vc4-kms-v3d" >> "$CONFIG_TXT"
        echo "   aggiunto dtoverlay=vc4-kms-v3d"
    fi
    echo "   *** RIAVVIO NECESSARIO perche' questa modifica abbia effetto ***"
    REBOOT_NEEDED=1
fi

# -----------------------------------------------------------
# 3) permessi: accedere a /dev/dri (KMSDRM) senza sudo richiede
#    l'utente nei gruppi video/render.
# -----------------------------------------------------------
echo "-- Permessi utente ($REAL_USER) --"
NEEDS_REGROUP=0
for GRP in video render; do
    if id -nG "$REAL_USER" 2>/dev/null | grep -qw "$GRP"; then
        echo "   gia' nel gruppo $GRP"
    else
        usermod -aG "$GRP" "$REAL_USER"
        echo "   aggiunto al gruppo $GRP"
        NEEDS_REGROUP=1
    fi
done

# -----------------------------------------------------------
# 4) riepilogo
# -----------------------------------------------------------
echo
echo "== Fatto. =="
if [ "${REBOOT_NEEDED:-0}" = "1" ] || [ "$NEEDS_REGROUP" = "1" ]; then
    echo "Riavvia il Pi prima di continuare (sudo reboot) - servono sia"
    echo "l'overlay video sia il refresh dei gruppi utente."
else
    echo "Nessun riavvio necessario: gia' tutto pronto."
fi
echo "Poi vedi docs/raspberry_pi_setup.md per la checklist di verifica."
