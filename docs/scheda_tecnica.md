# s32 — scheda tecnica

Riferimento compatto delle caratteristiche tecniche attuali della
console **s32** (motore `lua32`, LuaJIT). Per il *perché* di ogni
scelta vedi [`design.md`](design.md) — questo documento è solo il
*cosa*, aggiornato allo stato di implementazione corrente.

Stato: motore in costruzione. Le sezioni CPU/Memoria/Video sono
implementate e testate (in sandbox x86; verifica sul Raspberry Pi 1 in
corso). Audio/OS/Editor/formato cartuccia sono ancora in progettazione
o non implementati — segnalato in ogni sezione.

---

## CPU

| Caratteristica | Valore |
|---|---|
| Bus indirizzi | 24-bit flat, **nessun banking** (16.777.216 byte indirizzabili) |
| Registri generali | A, X, Y — 16-bit ciascuno |
| Registro FLAG | Zero, Negative, Carry, Overflow |
| Stack | Hardware, in cima alla WRAM, valori a 16-bit |
| Set di istruzioni | **83 opcode** (55 base + 28 indicizzati `,X`/`,Y`) |
| Modalità di indirizzamento | Nessuna (impliciti), immediata (16-bit), assoluta (24-bit), indicizzata assoluta (`,X`/`,Y`), clamp (coppia lo/hi) |
| Opcode liberi per estensioni future | 173 / 256 |
| Implementazione | `cpu.lua`, LuaJIT, tabella di dispatch condivisa fra istanze |

**Famiglie di istruzioni**: trasferimento memoria (LDA/STA/LDX/STX/LDY/STY, immediata+assoluta+indicizzata), trasferimento registri (TAX/TXA/TAY/TYA/TXY/TYX), ALU (ADD/SUB/AND/OR/XOR/CMP, immediata+assoluta+indicizzata), shift (ASL/LSR), incremento/decremento (INC/DEC su memoria e registri, incl. indicizzati), salti (JMP/JZ/JNZ/JLT/JGE/JCS/JCC), chiamate (JSR/RTS), stack (PHA/PLA/PHX/PLX/PHY/PLY), input (IN), clamp (CLAMPX/CLAMPY).

Misurato su Raspberry Pi 1 vero (ARMv6): **3.72 µs/istruzione** (LuaJIT) contro 24.10 µs/istruzione del vecchio motore Python/Cython — verificato byte-per-byte identico prima di fidarsi del numero di velocità.

---

## Mappa di memoria

| Regione | Base | Dimensione | Note |
|---|---|---|---|
| WRAM | `0x000000` | 128 KB | Stato di gioco + stack hardware |
| VRAM | `0x020000` | 552 KB (565.248 B) | Vedi dettaglio sotto |
| OAM | `0x0AA000` | 4 KB | 512 sprite × 8 byte |
| CGRAM | `0x0AB000` | 6 KB | 8 palette × 256 colori × 3 byte |
| Porte | `0x0AC800` | 256 B | I/O memory-mapped |
| APU | `0x0AC900` | 128 B | 8 canali × 16 byte, vedi sezione Audio |
| Libero | `0x0AC980` | ~15,3 MB | Non assegnato — riservato per estensioni (formato cartuccia con banchi, eventuali coprocessori) |

### VRAM in dettaglio

| Sottoregione | Dimensione | Contenuto |
|---|---|---|
| Tilemap | 32 KB | Griglia densa 128×128 celle da 8×8px, 2 byte/cella |
| Directory | 8 KB | 2048 entry × 4 byte (offset 24-bit + classe di taglia) |
| Archivio grafico | 512 KB | Byte grezzi dei tile, allineati a 64 byte |

**Descrittore di tile** (16-bit, condiviso da tilemap e OAM): tile_index (11 bit, 0-2047) + palette (3 bit, 0-7) + 2 bit riservati. La taglia del tile **non** è nel descrittore — è nella directory, così un tile ha sempre la stessa taglia ovunque venga referenziato.

### Porte memory-mapped

| Porta | Offset | Funzione |
|---|---|---|
| INPUT | +0 | Input giocatore 1 |
| STAGE_SELECT | +1 | Scrivere un numero copia la tilemap di quello stage in VRAM |
| SCROLL_X / SCROLL_Y | +2 / +3 | Registri di scroll dello sfondo |
| (libera) | +4 | Era SOUND (accoda un ID) — superata dal controllo esplicito per canale dell'APU, vedi sotto |
| GFX_BANK_SELECT | +5 | Scrivere un numero copia directory+archivio grafico di quel banco in VRAM (formato cartuccia, vedi sotto) |
| INPUT giocatore 2-8 | +0x10…+0x16 | Multiplayer locale |

---

## Video (PPU)

| Caratteristica | Valore |
|---|---|
| Risoluzioni native | 320×224 (4:3) · 384×224 (16:9) — altezza fissa |
| Framerate | 60fps (default) o 30fps |
| Tile/sprite | Base 8×8, taglie 8/16/32/64px selezionabili liberamente per singolo tile |
| Tile indirizzabili | 2048 |
| Sprite simultanei | 512 |
| Colore | 8bpp indicizzato (256 colori/tile: 1 trasparente + 255 veri) |
| Palette | 8 × 256 colori, **24-bit (RGB888)** |
| Compositing sfondo | Griglia densa 8×8, un solo passaggio con tracking "celle coperte" per i tile >8×8 |
| Priorità sprite | Sempre sopra lo sfondo, ordine di slot OAM (slot più alto = sopra) |
| Trasparenza | Indice di palette 0 |
| Flip sprite | Orizzontale e verticale (per-sprite, via attributi OAM) |
| Output | Rescale a piena finestra/schermo via GPU (no letterbox) |
| Implementazione | `ppu.lua` (compositing) + `video.lua` (FFI SDL2, texture accelerata) |

Prestazioni misurate in sandbox x86 (**non** rappresentative del Pi — vedi `tests/bench.lua`): sfondo pieno 320×224 ≈ 0,63 ms/frame; +50 sprite ≈ 0,64 ms/frame (il costo scala coi pixel disegnati, non col numero di sprite); tile 64×64 misti a 8×8 ≈ 0,41 ms/frame (più veloce del pieno 8×8: meno celle scansionate).

---

## Audio (implementato, testato e collegato al gameplay - verificato sul Pi reale)

| Caratteristica | Valore |
|---|---|
| Tipo | Sintesi procedurale — oscillatori (quadra/triangolo/sawtooth/rumore), non campioni PCM |
| Canali | 8, **controllo esplicito** (il programma scrive nei registri del canale scelto — niente allocazione automatica) |
| Inviluppo | ADSR vero (attack/decay/sustain/release), rampe lineari |
| Mixing | Somma diretta dei canali attivi, clippata a piena scala (non divisa per 8 — un canale solo suona a piena scala) |
| Collocazione | Memory-mapped, `APU_BASE` (dopo le porte) — 16 byte/canale × 8 = 128 byte totali |
| Registri per canale | FREQ (16-bit Hz), WAVEFORM, DUTY, VOLUME, ATTACK, DECAY, SUSTAIN, RELEASE, CONTROL (bit0=GATE) — 6 byte riservati per estensioni |
| Implementazione | `apu.lua`, verificato con `tests/test_apu.lua` (forme d'onda, inviluppo, indipendenza canali, rumore) |
| Uscita audio reale | **Fatta** (`audio_out.lua`, SDL2 verso ALSA/HDMI) e verificata sul Pi reale — collegata al gameplay (SFX su bottone azione, canale 7) |
| Controller | SDL_GameController (PS4 testato) — D-pad/azione in OR con la tastiera, riconoscimento anche a caldo |
| Confronto Pico-8 | Pico-8: 4 canali, niente ADSR vero (solo effetti tipo fade). Noi: 8 canali, ADSR vero |
| Confronto SNES vero | SNES: campioni BRR compressi + CPU SPC700 dedicata + eco/riverbero hardware. Noi: solo oscillatori (niente campioni), niente CPU dedicata, eco/riverbero rimandato a estensione futura |
| Estensione futura possibile | Eco/riverbero (buffer di delay + filtro, stile SNES); campioni PCM veri in aggiunta al procedurale (non al posto) |

---

## Formato cartuccia

| Caratteristica | Valore |
|---|---|
| Contenitore | File binario `.cart`, header a **264 byte** (non 256: lo struct FFI non è packed e contiene padding — offset espliciti in `docs/spec/s32-spec.md` §6.1) + sezioni |
| Header | Magic, versione, **uid** (16B), titolo, autore, data, offset/dimensione sezioni, **CRC32** (integrità), **SHA-256** (32B, riservato per autenticità/NFT future, non ancora calcolato) |
| Sezioni | Codice · banchi di stage (32KB, tilemap) · banchi grafici (~520KB, directory+archivio) · palette iniziale (CGRAM, opzionale) |
| Swap grafico | Porta `PORT_GFX_BANK_SELECT` — stesso meccanismo di `PORT_STAGE_SELECT`, esteso alla grafica |
| Implementazione | `cart.lua` — `pack()`/`load()`/`install()`, verificato con `tests/test_cart.lua` (round-trip, esecuzione, rilevamento corruzione) |
| Specifica formale | `docs/spec/s32-spec.md` — contratto comune con `bm33` (implementazione bare metal), vedi anche `docs/spec/s32-bm33.md` per il registro delle decisioni condivise |
| Non ancora fatto | Banco audio swappabile (dipende da `apu.lua`); pipeline sorgente `dev/<cartuccia>/` (PNG/JSON) → `.cart` (dipende dall'editor) |

---

## Input

| Caratteristica | Valore |
|---|---|
| Tastiera | SDL2 diretto (`SDL_GetKeyboardState`) — finestra reale con focus reale, nessun bypass necessario |
| Controller | SDL_GameController — riconosce PS4/PS5/Xbox e altri automaticamente (SDL li normalizza tutti allo stesso layout astratto), collegamento a caldo supportato |
| Mappatura base | Su/giù/sinistra/destra + azione (estendibile) — tastiera e controller in OR, indifferente quale si usi |
| Multiplayer locale | Fino a 8 porte input separate nella mappa di memoria |
| Implementazione | `input.lua`, FFI diretto, costanti verificate contro l'header SDL2 reale |

---

## Target hardware

| Caratteristica | Valore |
|---|---|
| Output di riferimento | HDMI + GPU (driver `vc4-kms-v3d`, KMSDRM) |
| Libreria grafica/audio/input | LuaJIT nudo + FFI + SDL2 diretto — **nessun framework** (no LÖVE2D) |
| Piattaforma di sviluppo primaria | Raspberry Pi 1 (ARMv6) — lo stesso hardware del vecchio motore, ora sbloccato dal collo di bottiglia SPI/LCD passando a HDMI |
| Requisiti sistema | `luajit`, `libsdl2-2.0-0`, driver KMS attivo |

---

## Cosa manca ancora

- ~~Audio~~ — **fatto**: motore (`apu.lua`), uscita (`audio_out.lua`), collegato al gameplay, tutto verificato sul Pi reale. Resta aperta solo l'eco/riverbero (estensione futura, mai pianificata per la v1)
- **OS** (`s32_os.lua`) — selezione cartucce, sospensione/ripresa, dev-mode: **in costruzione**. Fatto finora: font 8x8 maiuscole/minuscole (`font8x8.lua`), config persistente (`os_config.lua`), scansione `cart/`+`dev/`, combo dev-mode (Ctrl+D / L1+R1). Non ancora fatto: grafica del cart-picker (griglia di sprite), loop di pausa/ripresa in RAM, prompt di conferma cambio cartuccia
- **Editor** (`editor.lua`) — tab Codice/Grafica/Suoni: progettato, non costruito
- ~~Formato cartuccia reale~~ — **fatto** (`cart.lua`): resta la pipeline sorgente `dev/` → `.cart` (dipende dall'editor) e un eventuale banco audio swappabile (ora possibile, l'uscita audio è pronta - non ancora fatto perché non serve finché non esiste un editor/cartuccia vera con più suoni)
- **ConsoleLang** — da decidere se portare o ripensare
- **Salvataggio persistente** (save state) — non progettato
- ~~Verifica completa su Raspberry Pi 1 reale~~ — **fatto** per CPU/PPU/video/input/cartuccia/LCD; PPU ottimizzata (~2x); ~38-40fps medi, minimo ~15fps
- **Output RCA/composito** — dimostrato possibile sul Pi reale (funziona, FPS anche migliori dell'HDMI) ma sospeso a metà: serve rendere permanente il forzamento del connettore, sistemare l'audio jack (bug preesistente in `config.txt`) e correggere lo stretch verticale. Dettagli in `docs/raspberry_pi_setup.md` § 6.2
