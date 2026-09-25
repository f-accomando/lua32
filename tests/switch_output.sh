#!/bin/sh
# switch_output.sh - passa s32 fra uscita digitale (HDMI video+audio) e
# analogica (RCA composito + jack audio 3.5mm), e fra WiFi ed Ethernet -
# per confrontare consumo/prestazioni delle due configurazioni senza
# doverselo ricordare a mano ogni volta (vedi la domanda in chat "cambia
# qualcosa a livello di consumo/prestazioni" - risposta breve: si',
# soprattutto togliere il dongle WiFi e spegnere l'HDMI attivo).
#
#     sudo sh tests/switch_output.sh --status    # stato attuale (video/audio/rete)
#     sudo sh tests/switch_output.sh --digital   # HDMI video+audio (richiede riavvio)
#     sudo sh tests/switch_output.sh --analog    # RCA + jack 3.5mm (richiede riavvio)
#     sudo sh tests/switch_output.sh --wifi      # WiFi attivo, Ethernet spenta (a caldo)
#     sudo sh tests/switch_output.sh --eth       # Ethernet attiva, WiFi spenta (a caldo)
#     sudo sh tests/switch_output.sh --confirm   # conferma l'ultimo switch --wifi/--eth
#
# ATTENZIONE rete: se sei collegato via SSH e spegni l'interfaccia che
# stai usando in quel momento resti fuori. Per questo --wifi e --eth
# NON sono definitivi da soli: si annullano da soli dopo 25s se non
# confermi con --confirm - utile apposta anche se la connessione cade
# PROPRIO per il cambio (non serve indovinare quale interfaccia stai
# usando adesso, si ripristina comunque se non rispondi in tempo).
#
# ATTENZIONE video: il parametro "composite" dell'overlay vc4-kms-v3d
# qui sotto NON e' stato verificato su un Pi reale (nessun accesso
# diretto da questa sessione, solo comandi che l'utente incolla) -
# stessa disciplina "mai fidarsi senza controllare sull'hardware vero"
# gia' seguita per KMSDRM/fbN/RGB565 in questo progetto. Per questo
# --digital/--analog stampano PRIMA l'estratto vero del README degli
# overlay di QUESTO Pi, cosi' si puo' controllare ad occhio che il nome
# del parametro coincida davvero prima di fidarsi e riavviare.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Serve sudo (modifica config.txt, audio, rete): sudo sh $0 $*"
    exit 1
fi

ACTION="$1"
FORCE=0
for a in "$@"; do
    [ "$a" = "--force" ] && FORCE=1
done

if [ -f /boot/firmware/config.txt ]; then
    CONFIG_TXT=/boot/firmware/config.txt       # Raspberry Pi OS Bookworm/Trixie+
    OVERLAY_README=/boot/firmware/overlays/README
else
    CONFIG_TXT=/boot/config.txt                 # Raspberry Pi OS Bullseye e precedenti
    OVERLAY_README=/boot/overlays/README
fi

REVERT_MARK=/tmp/s32_switch_confirm
REVERT_LOG=/tmp/s32_switch_revert.log

detect_wifi_if() {
    for d in /sys/class/net/*; do
        [ -d "$d/wireless" ] && basename "$d" && return 0
    done
    return 1
}

detect_eth_if() {
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        [ "$n" = "lo" ] && continue
        [ -d "$d/wireless" ] && continue
        case "$n" in docker*|veth*|br-*) continue ;; esac
        echo "$n"
        return 0
    done
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

case "$ACTION" in
--status)
    echo "== Video (da $CONFIG_TXT) =="
    grep '^dtoverlay=vc4-kms-v3d' "$CONFIG_TXT" 2>/dev/null || echo "   (nessuna riga vc4-kms-v3d trovata)"

    echo
    echo "== Audio (route ALSA, se leggibile) =="
    BCM_CARD=$(have aplay && aplay -l 2>/dev/null | awk '/bcm2835/{gsub(":","",$2); print $2; exit}' || true)
    if [ -n "$BCM_CARD" ]; then
        amixer -c "$BCM_CARD" cget numid=3 2>/dev/null | grep -- '- ' || echo "   (scheda bcm2835 trovata ma numid=3 non leggibile)"
        echo "   (0=auto, 1=jack 3.5mm, 2=HDMI)"
    else
        echo "   (scheda bcm2835 non trovata da 'aplay -l' - controlla ad orecchio)"
    fi

    echo
    echo "== Rete =="
    WIFI_IF=$(detect_wifi_if || true)
    ETH_IF=$(detect_eth_if || true)
    [ -n "$WIFI_IF" ] && echo "   WiFi ($WIFI_IF): $(cat "/sys/class/net/$WIFI_IF/operstate" 2>/dev/null)"
    [ -n "$ETH_IF" ] && echo "   Ethernet ($ETH_IF): $(cat "/sys/class/net/$ETH_IF/operstate" 2>/dev/null)"
    [ -f "$REVERT_MARK" ] || echo "   (nessun auto-revert di rete in sospeso al momento)"
    exit 0
    ;;

--confirm)
    touch "$REVERT_MARK"
    echo "Confermato: l'ultimo switch di rete resta attivo, l'auto-revert e' annullato."
    exit 0
    ;;

--digital|--analog)
    if [ -f "$OVERLAY_README" ]; then
        echo "-- Estratto vero del README overlay di QUESTO Pi (verifica il nome del parametro 'composite' prima di fidarti) --"
        sed -n '/^Name:[ \t]*vc4-kms-v3d$/,/^Name:/p' "$OVERLAY_README" 2>/dev/null | sed '$d'
        echo "--"
    else
        echo "ATTENZIONE: $OVERLAY_README non trovato, non posso mostrarti la documentazione reale - procedo comunque, ma verifica a mano se dopo il riavvio qualcosa non torna."
    fi

    if [ "$FORCE" != "1" ]; then
        printf '%s' "Procedo con la modifica a $CONFIG_TXT (poi serve un riavvio manuale)? Scrivi SI per confermare: "
        read -r ans
        [ "$ans" = "SI" ] || { echo "Annullato."; exit 1; }
    fi

    cp "$CONFIG_TXT" "$CONFIG_TXT.bak.$(date +%s)"
    echo "Backup salvato accanto a $CONFIG_TXT"

    # rimuove qualunque riga vc4-kms-v3d esistente (con o senza
    # parametri, es. quella messa da install_pi.sh) e la riscrive
    # pulita - cosi' digital/analog restano idempotenti, non si
    # accumulano righe duplicate/contrastanti a furia di rilanciare
    grep -v '^dtoverlay=vc4-kms-v3d' "$CONFIG_TXT" > "$CONFIG_TXT.tmp"
    if [ "$ACTION" = "--analog" ]; then
        echo "dtoverlay=vc4-kms-v3d,composite=1" >> "$CONFIG_TXT.tmp"
    else
        echo "dtoverlay=vc4-kms-v3d" >> "$CONFIG_TXT.tmp"
    fi
    mv "$CONFIG_TXT.tmp" "$CONFIG_TXT"

    if have raspi-config; then
        if [ "$ACTION" = "--analog" ]; then
            raspi-config nonint do_audio 1   # forza il jack 3.5mm
            echo "Audio instradato sul jack 3.5mm (a caldo, nessun riavvio necessario per questo)."
        else
            raspi-config nonint do_audio 2   # forza HDMI
            echo "Audio instradato su HDMI (a caldo, nessun riavvio necessario per questo)."
        fi
    else
        echo "raspi-config non trovato: instrada l'audio a mano (raspi-config -> System Options -> Audio, o amixer)."
    fi

    echo
    echo "*** Riavvia per applicare il cambio video: sudo reboot ***"
    echo "Dopo il riavvio, verifica con S32_LCD_STATUS=1 ./run.sh che il video esca dove atteso."
    ;;

--wifi|--eth)
    WIFI_IF=$(detect_wifi_if || true)
    ETH_IF=$(detect_eth_if || true)
    if [ "$ACTION" = "--wifi" ] && [ -z "$WIFI_IF" ]; then echo "Nessuna interfaccia WiFi trovata."; exit 1; fi
    if [ "$ACTION" = "--eth" ] && [ -z "$ETH_IF" ]; then echo "Nessuna interfaccia Ethernet trovata."; exit 1; fi

    rm -f "$REVERT_MARK"

    # accende prima l'interfaccia nuova, aspetta che si assesti, POI
    # spegne la vecchia - se stai usando SSH proprio su quella che sta
    # per sparire preferiamo un attimo di doppia connessione a uno
    # zero secco
    if [ "$ACTION" = "--wifi" ]; then
        echo "Accendo WiFi, poi spengo Ethernet..."
        if have nmcli; then nmcli radio wifi on; else rfkill unblock wifi 2>/dev/null || true; ip link set "$WIFI_IF" up 2>/dev/null || true; fi
        sleep 2
        if have nmcli; then nmcli device disconnect "$ETH_IF" 2>/dev/null || true; else ip link set "$ETH_IF" down 2>/dev/null || true; fi
    else
        echo "Accendo Ethernet, poi spengo WiFi..."
        if have nmcli; then nmcli device connect "$ETH_IF" 2>/dev/null || true; else ip link set "$ETH_IF" up 2>/dev/null || true; have dhclient && dhclient "$ETH_IF" 2>/dev/null || true; fi
        sleep 3
        if have nmcli; then nmcli radio wifi off; else rfkill block wifi 2>/dev/null || true; ip link set "$WIFI_IF" down 2>/dev/null || true; fi
    fi

    echo "Fatto. Se non confermi entro 25s con:  sudo sh $0 --confirm"
    echo "(o se la connessione cade proprio per questo cambio), si annulla da sola."

    nohup sh -c "
        sleep 25
        if [ ! -f '$REVERT_MARK' ]; then
            if command -v nmcli >/dev/null 2>&1; then
                if [ '$ACTION' = '--wifi' ]; then
                    nmcli device connect '$ETH_IF' 2>/dev/null
                    nmcli radio wifi off 2>/dev/null
                else
                    nmcli radio wifi on 2>/dev/null
                    nmcli device disconnect '$ETH_IF' 2>/dev/null
                fi
            else
                if [ '$ACTION' = '--wifi' ]; then
                    ip link set '$ETH_IF' up 2>/dev/null
                    ip link set '$WIFI_IF' down 2>/dev/null
                else
                    ip link set '$WIFI_IF' up 2>/dev/null
                    ip link set '$ETH_IF' down 2>/dev/null
                fi
            fi
        fi
    " >"$REVERT_LOG" 2>&1 &
    ;;

*)
    echo "Uso: sudo sh $0 --status|--digital|--analog|--wifi|--eth|--confirm [--force]"
    exit 1
    ;;
esac
