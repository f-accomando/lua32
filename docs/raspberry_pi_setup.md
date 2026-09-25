# Verifica su Raspberry Pi reale — checklist

Prima verifica end-to-end del motore `lua32` sull'hardware target vero
(Raspberry Pi 1, ARMv6, HDMI). Vedi `docs/scheda_tecnica.md` per cosa
è già stato verificato solo in sandbox (x86) e resta da confermare qui.

## 0. Prerequisiti

- [ ] Raspberry Pi (1 o superiore) con Raspberry Pi OS, collegato via HDMI a uno schermo
- [ ] Accesso SSH o tastiera/schermo diretti sul Pi
- [ ] Il Pi è lo stesso già usato per il vecchio motore Python (quindi `vc4-kms-v3d` potrebbe essere già attivo da prima — lo script sotto lo rileva e non lo tocca se è già a posto)

## 1. Scaricare la repository

```sh
git clone <URL_REPO> lua32
cd lua32
```

*(`<URL_REPO>` — vedi sezione finale di questo documento non appena la repo è pubblicata)*

## 2. Installare le dipendenze

```sh
sudo sh tests/install_pi.sh
```

Installa `luajit` + `libsdl2-2.0-0` (+ le librerie GLES/EGL/GBM che
SDL2 usa sotto KMSDRM per il rendering accelerato), controlla/attiva
l'overlay `vc4-kms-v3d` in `config.txt`, e mette l'utente nei gruppi
`video`/`render` (servono per accedere a `/dev/dri` senza sudo).

- [ ] Script eseguito senza errori
- [ ] Se lo script segnala "RIAVVIO NECESSARIO": `sudo reboot`, poi ricollegarsi

## 3. Test automatici (nessuna finestra grafica reale richiesta)

```sh
luajit tests/test_cpu.lua
luajit tests/test_assembler.lua
luajit tests/test_ppu.lua
luajit tests/test_cart.lua
luajit tests/test_demo_program.lua
```

- [ ] Tutti e cinque stampano "Tutti i test passati."

Questi non toccano SDL2/KMSDRM — se falliscono qui il problema è nella
logica (CPU/PPU/formato cartuccia), non nel driver video.

## 3bis. Se `SDL_Init` fallisce con "kmsdrm not available"

Causa **confermata** su hardware reale (non era il sospetto iniziale
di un desktop grafico — su un'immagine Lite senza desktop non c'entra):
il **getty sulla console testuale** (`agetty` su tty1, anche quando i
suoi parametri sembrano quelli di una console seriale) tiene il
framebuffer via `fbcon` e questo basta a impedire a SDL2/KMSDRM di
diventare "DRM master". Non compare né in `ps aux | grep luajit` né in
`fuser /dev/dri/card0` — va cercato esplicitamente:

```sh
ps aux | grep getty
sudo systemctl stop getty@tty1
```

Su un Pi dedicato a fare solo da console s32 (nessun login testuale
locale serve davvero) ha senso disabilitarlo in modo permanente invece
di fermarlo ad ogni riavvio:

```sh
sudo systemctl disable getty@tty1
```

- [ ] `SDL_VIDEODRIVER=kmsdrm luajit tests/test_video.lua` passa dopo aver fermato/disabilitato il getty

## 4. Test SDL2/video reali (KMSDRM)

```sh
SDL_VIDEODRIVER=kmsdrm luajit tests/test_video.lua
SDL_VIDEODRIVER=kmsdrm luajit tests/test_input.lua
```

- [ ] `test_video.lua` passa (apre finestra/renderer accelerato per davvero, non il driver dummy della sandbox)
- [ ] `test_input.lua` passa

Se `test_video.lua` fallisce con *"Couldn't find matching render
driver"*: l'overlay KMS non è attivo per davvero (punto 2) o manca un
riavvio — non procedere oltre finché non passa.

## 5. OS (cart-picker) + demo giocabile end-to-end

```sh
luajit tests/pack_demo_cart.lua   # una tantum: crea cart/demo.cart
./run.sh
```

(equivalente a `SDL_VIDEODRIVER=kmsdrm luajit main.lua`)

`main.lua` ora mostra prima il cart-picker dell'OS (griglia delle
cartucce in `cart/`), non lancia piu' il demo direttamente:

- [ ] Si vede la griglia "S32 - CARTUCCE" con l'icona di "demo"
- [ ] Frecce/WASD spostano il cursore, Invio/X avvia "demo"
- [ ] Si vede lo sfondo blu scuro + il quadrato giallo su schermo, via HDMI
- [ ] Frecce/WASD muovono lo sprite, si ferma ai bordi (clamp)
- [ ] ESC durante il gioco torna al picker (pausa, non chiude) - l'icona di "demo" si marca con un "*" verde
- [ ] Riselezionando "demo" si riprende esattamente da dove si era (posizione dello sprite invariata)
- [ ] ESC nel picker senza nulla in pausa chiude pulitamente
- [ ] Framerate visivamente fluido (non a scatti) — se sembra lento, non fidarsi dell'impressione: passare al benchmark sotto

## 6. Benchmark reale (il numero che conta davvero)

```sh
luajit tests/bench.lua 2000
```

- [ ] Eseguito, numeri annotati (µs/istruzione CPU, ms/frame PPU nei tre scenari)
- [ ] Confrontati con la cifra già nota **3.72 µs/istruzione** (misurata
      sullo stesso Pi con `bench_cpu.lua` del vecchio prototipo standalone,
      vedi `docs/scheda_tecnica.md`) — devono essere nello stesso ordine
      di grandezza, non serve identici

## 6bis. Pannello di stato sull'LCD SPI (opzionale)

Ora che HDMI è l'unico output del gioco, l'LCD SPI (verificato `/dev/fb0`
sul tuo Pi — `fb_ili9486`, 480x320, RGB565, *non più* `/dev/fb1`: quel
numero è cambiato da quando HDMI è passato a KMSDRM) è libero per un
pannello diagnostico invece che restare spento.

```sh
python3 tests/shinchan_to_bin.py /home/pi/shinchan.png shinchan_565.bin   # una tantum
S32_LCD_STATUS=1 ./run.sh
```

- [ ] Il disegno appare sull'LCD con sopra una fascia di statistiche live (CPU µs/istr, PPU ms, GPU/blit ms, banco grafica/stage, FPS)
- [ ] Nessun rallentamento percepibile su HDMI (l'aggiornamento LCD è a bassa frequenza, ~2 volte al secondo, non ogni frame)

Variabili opzionali: `S32_LCD_FB` (default `/dev/fb0`), `S32_LCD_BG`
(default `shinchan_565.bin`, cercato nella directory corrente).

## 6.1 Uscita analogica (RCA + jack) vs digitale (HDMI), WiFi vs Ethernet

Per confrontare consumo/prestazioni fra le due configurazioni senza
modificare `config.txt`/rete a mano ogni volta:

```sh
sudo sh tests/switch_output.sh --status    # stato attuale (video/audio/rete)
sudo sh tests/switch_output.sh --analog    # RCA + jack 3.5mm (richiede riavvio)
sudo sh tests/switch_output.sh --digital   # HDMI video+audio (richiede riavvio)
sudo sh tests/switch_output.sh --eth       # Ethernet attiva, WiFi spenta (a caldo)
sudo sh tests/switch_output.sh --wifi      # WiFi attivo, Ethernet spenta (a caldo)
```

`--wifi`/`--eth` si auto-annullano dopo 25s se non confermi con
`sudo sh tests/switch_output.sh --confirm` - pensato apposta per non
restare tagliati fuori se si spegne l'interfaccia usata dalla sessione
SSH corrente. `--analog`/`--digital` stampano prima l'estratto vero del
README degli overlay di questo Pi (il parametro `composite` non è mai
stato verificato su hardware reale da questa sessione di sviluppo,
verificalo ad occhio prima di riavviare) - vedi i commenti in testa a
`tests/switch_output.sh` per i dettagli.

## 6.2 RCA/composito - stato sperimentale (IN PAUSA, non finito)

Verificato sul Pi reale: **funziona** (`main.lua` gira su schermo
collegato via RCA, FPS anche migliori dell'HDMI - 37.5 medio contro
31-32), ma con tre problemi aperti, nessuno risolto. Non è ancora un
output di seconda classe utilizzabile, solo dimostrato possibile -
ripreso da qui quando servirà, per ora si torna alla roadmap (OS).

**1. Il connettore composito non è mai "connected" di default.** Il
connettore DRM `Composite-1` (VEC, id 53 in `modetest`) non ha
rilevamento hotplug come l'HDMI - il suo stato resta sempre `unknown`
in `/sys/class/drm/*/status`, mai `connected`, e SDL2 (backend KMSDRM)
sceglie solo fra i connettori `connected`: senza forzarlo, `SDL_Init`
fallisce con "kmsdrm not available" anche con l'overlay giusto attivo
(`dtoverlay=vc4-kms-v3d,composite=1` - il parametro è confermato reale,
visto nel README overlay di questo Pi) e anche se `modetest` dimostra
che il connettore funziona benissimo a livello DRM (4 mode validi,
pattern visibile fisicamente sulla TV con `modetest -M vc4 -s
53:720x480i`). Workaround che FUNZIONA ma non è permanente:

```sh
echo on | sudo tee /sys/kernel/debug/dri/0/Composite-1/force
```

Va rilanciato ad OGNI riavvio (`/sys/kernel/debug` non è persistente
per natura, torna a `unspecified` al riavvio). **TODO non fatto**: un
servizio systemd oneshot che lo riapplica all'avvio (o integrarlo in
`tests/switch_output.sh --analog`), verificando anche il nome esatto
della cartella (`Composite-1`) perché non è garantito che l'indice del
connettore (`53`) o il nome restino identici su un Pi diverso.

**2. Audio jack disabilitato in `config.txt` - bug preesistente, non
introdotto in questa sessione.** `config.txt` contiene DUE righe in
conflitto:

```
dtparam=audio=on
dtparam=audio=off
```

Vince l'ultima (`dtparam=audio=off`): il jack 3.5mm risulta
completamente disabilitato a livello hardware. `aplay -l` non mostra
nessuna scheda per l'audio analogico (solo `vc4hdmi` e il controller
USB collegato). Per questo `raspi-config nonint do_audio 1` (chiamato
da `switch_output.sh --analog`) fallisce silenziosamente - prova a
instradare verso una scheda che non esiste - e `audio_out.lua` riceve
poi un errore ALSA anomalo (524, non uno storico errno) quando prova
ad aprire il device. **TODO non fatto**: rimuovere/commentare la riga
`dtparam=audio=off` da `config.txt` (chi l'ha messa e perché non è
chiaro - non è stata aggiunta in questa sessione, era già lì prima di
qualunque nostra modifica), poi riverificare con `aplay -l` che compaia
una scheda per il jack.

**3. Immagine stretchata in verticale sul composito.** 720×480 (NTSC)
usa pixel NON quadrati, a differenza dell'HDMI. Il renderer attuale
(`video.lua`) fa uno stretch pieno del frame senza tenerne conto
(scelta "niente letterbox" documentata in `scheda_tecnica.md`, che
funzionava bene finché l'unico output era HDMI a pixel quadrati). Sul
composito servirebbe un pillarbox di circa l'11% in larghezza (mappare
l'aspect ratio 4:3 corretto dentro i 720px raw invece di riempirli
tutti). **TODO non fatto**: nessuna correzione implementata.

## 7. Dopo la verifica

- [ ] Aggiornare `docs/scheda_tecnica.md`: sostituire "verifica in corso"
      con i numeri reali del Pi (sezione CPU + sezione Video/PPU)
- [ ] Segnare in `docs/design.md` → "Punti ancora aperti" che la verifica
      hardware è chiusa

## Comandi rapidi (riepilogo copia-incolla)

```sh
git clone <URL_REPO> lua32 && cd lua32
sudo sh tests/install_pi.sh
# (riavviare se richiesto, poi ricollegarsi)
for t in cpu assembler ppu cart apu demo_program s32_os; do luajit tests/test_$t.lua; done
SDL_VIDEODRIVER=kmsdrm luajit tests/test_video.lua
SDL_VIDEODRIVER=kmsdrm luajit tests/test_input.lua
luajit tests/pack_demo_cart.lua   # una tantum: crea cart/demo.cart
./run.sh
luajit tests/bench.lua 2000
```
