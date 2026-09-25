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

## 5. Demo giocabile end-to-end

```sh
./run.sh
```

(equivalente a `SDL_VIDEODRIVER=kmsdrm luajit main.lua`)

- [ ] Si vede lo sfondo blu scuro + il quadrato giallo su schermo, via HDMI
- [ ] Frecce/WASD muovono lo sprite, si ferma ai bordi (clamp)
- [ ] ESC chiude pulitamente
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
for t in cpu assembler ppu cart demo_program; do luajit tests/test_$t.lua; done
SDL_VIDEODRIVER=kmsdrm luajit tests/test_video.lua
SDL_VIDEODRIVER=kmsdrm luajit tests/test_input.lua
./run.sh
luajit tests/bench.lua 2000
```
