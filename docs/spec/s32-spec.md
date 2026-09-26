# Specifica della macchina s32 — v0.1

Questo documento è il **contratto comune** tra le implementazioni di s32:

- **lua32** (questo repository) — implementazione di riferimento in LuaJIT su Linux/SDL2;
- **bm33** (`f-accomando/bm33`) — implementazione nativa in C, bare metal su Raspberry Pi Zero.

Una cartuccia `.cart` che rispetta questa specifica deve comportarsi allo stesso modo su
entrambe: **stessi byte in memoria e stessi pixel a schermo, frame per frame**. Non è
richiesto che le implementazioni si assomiglino internamente (bm33 non emula lua32,
implementa la stessa macchina).

- Versione: **0.1** (bozza), ricavata dal codice di lua32 al commit `17cf723`.
- Fonte di verità: in caso di dubbio decide **lua32**; ogni differenza scoperta va
  risolta qui (aggiornando la specifica o il codice) e coperta da un vettore di
  conformità (§9).
- Le parole **deve / non deve** indicano requisiti; **indefinito** indica un
  comportamento su cui una cartuccia non può fare affidamento.

---

## 1. Parametri della macchina

| Parametro | Valore |
|---|---|
| Spazio di indirizzamento | 24 bit piatto, 16 MiB (`0x000000`–`0xFFFFFF`), tutto RAM |
| Registri | A, X, Y a 16 bit; FLAGS (Z, N, C, V); PC a 24 bit; SP |
| Endianness | little endian (valori a 16 bit su due byte consecutivi) |
| Risoluzione | 320×224 (4:3). Il modo 384×224 (16:9) è previsto ma non ancora selezionabile (§10) |
| Frequenza logica | 60 tick al secondo |
| Colore | RGB888; tile a 8 bit indicizzati su palette |

## 2. Mappa di memoria

| Regione | Base | Fine (esclusa) | Dimensione |
|---|---|---|---|
| WRAM | `0x000000` | `0x020000` | 128 KiB |
| VRAM | `0x020000` | `0x0AA000` | 565 248 B |
| ├ tilemap | `0x020000` | `0x028000` | 32 KiB (128×128 celle × 2 B) |
| ├ directory | `0x028000` | `0x02A000` | 8 KiB (2048 voci × 4 B) |
| └ archivio grafico | `0x02A000` | `0x0AA000` | 512 KiB |
| OAM | `0x0AA000` | `0x0AB000` | 4 KiB (512 slot × 8 B) |
| CGRAM | `0x0AB000` | `0x0AC800` | 6 KiB (8 palette × 256 colori × 3 B) |
| Porte | `0x0AC800` | `0x0AC900` | 256 B |
| APU | `0x0AC900` | `0x0AC980` | 128 B (8 canali × 16 B) |
| Libero | `0x0AC980` | `0x1000000` | RAM normale, riservata a estensioni |

Tutta la memoria, comprese VRAM/OAM/CGRAM/APU, è RAM ordinaria leggibile e scrivibile
dalla CPU. Le sole eccezioni sono le porte con effetti collaterali (§2.1).

### 2.1 Porte

| Indirizzo | Nome | Accesso | Comportamento |
|---|---|---|---|
| `0x0AC800` | `INPUT` | lettura 8 bit | input del giocatore 1 (§5) |
| `0x0AC801` | `STAGE_SELECT` | scrittura 16 bit | copia il banco stage N nella tilemap (§6.2) |
| `0x0AC802` | `SCROLL_X` | scrittura 16 bit | scroll orizzontale dello sfondo, in pixel |
| `0x0AC803` | `SCROLL_Y` | scrittura 16 bit | scroll verticale dello sfondo, in pixel |
| `0x0AC804` | — | — | libera (era `SOUND`) |
| `0x0AC805` | `GFX_BANK_SELECT` | scrittura 16 bit | copia il banco grafico N in directory + archivio (§6.2) |
| `0x0AC810`–`0x0AC816` | `INPUT2`–`INPUT8` | lettura 8 bit | input dei giocatori 2–8 |

Regole precise (così come le implementa `cpu.lua`):

- Una **lettura a 16 bit** il cui indirizzo è esattamente una porta di input restituisce
  solo il byte della porta (parte alta = 0). Ogni altra lettura a 16 bit legge due byte
  consecutivi.
- Una **scrittura a 16 bit** il cui indirizzo è esattamente `STAGE_SELECT`,
  `GFX_BANK_SELECT`, `SCROLL_X` o `SCROLL_Y` esegue l'effetto della porta e **non scrive
  nulla in memoria**. Rileggere quegli indirizzi restituisce quindi il contenuto
  precedente della RAM, non il valore scritto.
- `STAGE_SELECT` / `GFX_BANK_SELECT` con un numero di banco inesistente: nessun effetto.
- I valori di scroll sono a 16 bit senza segno.

## 3. CPU

### 3.1 Stato

- `A`, `X`, `Y`: 16 bit senza segno.
- `FLAGS`: bit 0 = Z (zero), bit 1 = N (negativo, bit 15 del risultato), bit 2 = C
  (carry), bit 3 = V (overflow).
- `PC`: indirizzo a 24 bit dell'istruzione corrente.
- `SP`: punta al prossimo slot libero; parte da `0x01FFFE` e scende di 2 a ogni push.

### 3.2 Codifica

Un'istruzione è 1 byte di opcode seguito dagli operandi, little endian:

| Modo | Lunghezza | Operandi |
|---|---|---|
| nessuno | 1 | — |
| `#imm16` | 3 | valore a 16 bit |
| `addr24` | 4 | indirizzo a 24 bit |
| `addr24,X` / `addr24,Y` | 4 | indirizzo effettivo = `(addr24 + X) & 0xFFFFFF` |
| `clamp lo,hi` | 5 | due valori a 16 bit |

Gli accessi a 16 bit avvolgono ciascun byte su 24 bit (`addr+1` di `0xFFFFFF` è
`0x000000`). Un'istruzione i cui operandi superano `0xFFFFFF` ha comportamento indefinito.

### 3.3 Istruzioni

Notazione: `M[a]` = lettura a 16 bit con le regole delle porte (§2.1); `ZN(v)` = Z se
`v == 0`, N se il bit 15 di `v` è 1. I flag non elencati restano invariati.

| Opcode | Mnemonico | Effetto | Flag |
|---|---|---|---|
| `00` | NOP | — | — |
| `01` | HALT | fine del frame (§4); PC non avanza | — |
| `10`/`11` | LDA #imm / addr | `A = imm` / `A = M[addr]` | ZN(A) |
| `12` | STA addr | `M[addr] = A` | — |
| `13`/`14`/`15` | LDX #imm / LDX addr / STX addr | come LDA/STA su X | ZN(X) sui load |
| `16`/`17`/`18` | LDY #imm / LDY addr / STY addr | come LDA/STA su Y | ZN(Y) sui load |
| `20`–`25` | TAX TXA TAY TYA TXY TYX | copia tra registri | ZN(destinazione) |
| `30`/`40` | ADD #imm / addr | `r = A + op`; `A = r & 0xFFFF` | C = `r > 0xFFFF`; V = segni di A e op uguali e segno del risultato diverso; ZN |
| `31`/`41` | SUB #imm / addr | `A = (A - op) & 0xFFFF` | C = `A >= op` (senza segno, prima dell'operazione); V = segni di A e op diversi e segno del risultato diverso da A; ZN |
| `32`/`42` | AND | `A &= op` | ZN |
| `33`/`43` | OR | `A \|= op` | ZN |
| `34`/`44` | XOR | `A ^= op` | ZN |
| `35`/`45` | CMP #imm / addr | confronta senza modificare A | C = `A >= op`; ZN(`(A - op) & 0xFFFF`) |
| `50` | ASL | `A = (A << 1) & 0xFFFF` | C = vecchio bit 15; ZN |
| `51` | LSR | `A = A >> 1` | C = vecchio bit 0; ZN |
| `52`/`53` | INC / DEC addr | `M[addr] = (M[addr] ± 1) & 0xFFFF` | ZN |
| `54`–`57` | INX INY DEX DEY | `± 1` modulo 2¹⁶ | ZN |
| `60` | JMP addr | `PC = addr` | — |
| `61`/`62` | JZ / JNZ addr | salta se Z / se non Z | — |
| `63`/`64` | JLT / JGE addr | salta se N / se non N | — |
| `65`/`66` | JCS / JCC addr | salta se C / se non C | — |
| `67` | JSR addr | push((PC + 4) & 0xFFFF); `PC = addr` | — |
| `68` | RTS | `PC = pop()` (16 bit) | — |
| `70`–`75` | PHA PLA PHX PLX PHY PLY | push / pop del registro | ZN sui pull |
| `80` | IN | `A = byte(INPUT)` | nessuno |
| `90`/`91` | CLAMPX / CLAMPY lo,hi | se `R < lo` allora `R = lo`; se `R > hi` allora `R = hi` (senza segno) | nessuno |
| `A0`–`AB` | LDA/STA/LDX/STX/LDY/STY `addr,X` e `addr,Y` | come le versioni assolute; ordine: LDA,X LDA,Y STA,X STA,Y LDX,X LDX,Y STX,X STX,Y LDY,X LDY,Y STY,X STY,Y | come sopra |
| `B0`–`BF` | ADD SUB AND OR XOR CMP INC DEC `addr,X` e `addr,Y` | come le versioni assolute; ordine a coppie ,X / ,Y | come sopra |

Ogni altro opcode è **invalido** e causa un crash della cartuccia (§4).

### 3.4 Stack

- `push(v)`: scrive `v` a 16 bit in `SP`, poi `SP -= 2`; se `SP < 0` → crash (overflow).
- `pop()`: `SP += 2`; se `SP > 0x01FFFE` → crash (underflow); altrimenti legge 16 bit da `SP`.

## 4. Modello di esecuzione

1. **Installazione** della cartuccia (§6.2): memoria tutta a zero, `A = X = Y = FLAGS = 0`,
   `SP = 0x01FFFE`; il codice va copiato a **`0x001000`** (dentro la WRAM).
2. **Ogni tick** (60 al secondo):
   1. si scrive il byte di input di ogni giocatore nella sua porta (§5);
   2. `PC = 0x001000`; si eseguono istruzioni fino a `HALT`;
   3. si genera il frame (§7) e l'audio del tick (§8).
3. Tra un tick e l'altro **persistono** la memoria e i registri `A`, `X`, `Y`, `FLAGS`,
   `SP` (solo `PC` viene reimpostato). Una cartuccia normalmente usa un flag in WRAM per
   eseguire la propria inizializzazione solo al primo tick.
4. **Limite di sicurezza**: se un tick esegue più di **200 000** istruzioni (HALT
   compreso) senza arrivare a `HALT`, la cartuccia va in crash.
5. **Crash** (opcode invalido, stack overflow/underflow, limite superato): l'esecuzione
   della cartuccia si interrompe e il sistema torna al menu. Lo stato della cartuccia
   non va riutilizzato.

La velocità reale della CPU non fa parte della specifica: un tick deve dare lo stesso
risultato indipendentemente da quanto tempo impiega.

## 5. Input

Un byte per giocatore, scritto nella porta prima di ogni tick:

| Bit | Significato |
|---|---|
| 0 | su |
| 1 | giù |
| 2 | sinistra |
| 3 | destra |
| 4 | azione |
| 5–7 | riservati (0) |

## 6. Cartuccia `.cart`

### 6.1 Header (versione 1)

L'header occupa **264 byte** (non 256: lo struct C/FFI non è packed e contiene padding).
Tutti gli interi sono little endian. Offset:

| Offset | Tipo | Campo |
|---|---|---|
| 0 | char[8] | `magic` = `"S32CART1"` |
| 8 | u8 | `version` = 1 |
| 9 | u8[3] | `reserved0` (vedi §11 per `code_type`) |
| 12 | u8[16] | `uid` |
| 28 | char[64] | `title` (terminato da zero) |
| 92 | char[32] | `author` (terminato da zero) |
| 124 | u32 | `created_unix` |
| 128 | u32 | `code_offset` |
| 132 | u32 | `code_size` |
| 136 | u16 (+2 di padding) | `stage_bank_count` |
| 140 | u32 | `stage_bank_size` (= 32 768) |
| 144 | u32 | `stage_bank_offset` |
| 148 | u16 (+2 di padding) | `gfx_bank_count` |
| 152 | u32 | `gfx_bank_size` (= 532 480: directory + archivio) |
| 156 | u32 | `gfx_bank_offset` |
| 160 | u32 | `cgram_offset` |
| 164 | u8 (+3 di padding) | `cgram_present` |
| 168 | u32 | `content_crc32` |
| 172 | u8[32] | `content_sha256` (riservato, oggi tutto zero) |
| 204 | u8[59] (+1 di padding) | `reserved1` |

Tutti i byte di padding e riservati devono essere scritti a zero.

Il **corpo** segue l'header: codice, poi i banchi stage, poi i banchi grafici, poi la
CGRAM se presente. `content_crc32` è il CRC-32 IEEE 802.3 (lo stesso di zlib) di
**tutto il corpo**, cioè dal byte 264 alla fine del file. Una cartuccia con magic,
versione o CRC errati va rifiutata.

### 6.2 Installazione e banchi

- Il codice viene copiato a `0x001000`.
- Se `cgram_present` ≠ 0, i 6144 byte di CGRAM vengono copiati a `0x0AB000`.
- Se esiste lo stage 0 viene selezionato (come una scrittura di 0 su `STAGE_SELECT`); se
  esiste il banco grafico 0 viene selezionato (come una scrittura di 0 su `GFX_BANK_SELECT`).
- `STAGE_SELECT N`: copia i 32 768 byte del banco stage N a `0x020000`.
- `GFX_BANK_SELECT N`: copia i 532 480 byte del banco grafico N a `0x028000`
  (directory seguita dall'archivio grafico).

## 7. PPU

Il frame è una matrice 320×224 di pixel RGB888 che parte **tutta nera** `(0,0,0)`
(non il colore 0 di una palette). Si disegna prima lo sfondo, poi gli sprite.

### 7.1 Formati

- **Descrittore di tile** (16 bit, usato da tilemap e OAM): bit 0–10 = indice del tile
  (0–2047); bit 11–13 = palette (0–7); bit 14–15 = riservati.
- **Voce di directory** (4 byte, indice = numero del tile): byte 0–2 = offset a 24 bit
  nell'archivio grafico; byte 3 = classe di taglia (0 = 8, 1 = 16, 2 = 32, 3 = 64 px;
  classi > 3 indefinite).
- **Pixel di un tile**: `size × size` byte a partire da `0x02A000 + offset`, riga per
  riga; ogni byte è un indice di colore; **0 = trasparente**. Leggere oltre l'archivio è
  indefinito.
- **Colore**: palette `p`, indice `i` → 3 byte R, G, B a `0x0AB000 + (p × 256 + i) × 3`.

### 7.2 Sfondo

- Tilemap di 128×128 celle da 8×8 px (1024×1024 px) che si **ripete** in entrambe le
  direzioni. La cella `(cx, cy)` sta a `0x020000 + ((cy mod 128) × 128 + (cx mod 128)) × 2`.
- Il pixel di mondo `(wx, wy)` compare a schermo in `(wx − SCROLL_X, wy − SCROLL_Y)`.
- Una cella con indice di tile **0 è vuota** e non disegna nulla.
- Un tile di taglia `s` posto nella cella `(cx, cy)` disegna `s×s` pixel a partire dal
  pixel di mondo `(cx × 8, cy × 8)` e **copre** le `(s/8)²` celle del blocco che parte da
  lì. Le celle vengono visitate **per righe, dall'alto in basso e da sinistra a destra**,
  a partire da 8 celle prima della prima cella visibile (in x e in y); una cella già
  coperta da un tile visitato prima viene saltata anche se contiene un proprio tile.
- Si disegnano solo i pixel con indice ≠ 0 che cadono nello schermo.

### 7.3 Sprite

- 512 slot da 8 byte a `0x0AA000 + n × 8`: `x` (16 bit con segno), `y` (16 bit con
  segno), descrittore di tile (16 bit), attributi (16 bit).
- Attributi: bit 0 = visibile, bit 1 = flip orizzontale, bit 2 = flip verticale.
- Gli sprite usano **coordinate di schermo** (lo scroll non li sposta) e sono disegnati
  in ordine di slot da 0 a 511: uno slot più alto copre quelli più bassi.
- A differenza dello sfondo, uno sprite con indice di tile 0 **viene disegnato** (usa la
  voce 0 della directory).
- Con il flip il pixel `(lx, ly)` dello sprite prende il colore del pixel
  `(s−1−lx, ly)` / `(lx, s−1−ly)` del tile.
- Si disegnano solo i pixel con indice ≠ 0 che cadono nello schermo.

## 8. APU

Otto canali da 16 byte a `0x0AC900 + n × 16`:

| Offset | Registro | Significato |
|---|---|---|
| 0–1 | `FREQ` | frequenza in Hz, 16 bit |
| 2 | `WAVEFORM` | 0 quadra, 1 triangolo, 2 dente di sega, 3 rumore |
| 3 | `DUTY` | duty della quadra, 0–255 |
| 4 | `VOLUME` | 0–255, moltiplicato per l'inviluppo |
| 5–8 | `ATTACK`, `DECAY`, `SUSTAIN`, `RELEASE` | inviluppo ADSR (0–255; SUSTAIN è un livello) |
| 9 | `CONTROL` | bit 0 = GATE (1 nota accesa, 0 rilascio) |
| 10–15 | — | riservati |

Il riferimento per la sintesi è `apu.lua`. La conformità audio è **"all'orecchio"**:
gli stessi registri devono produrre la stessa nota, forma d'onda e inviluppo, ma non è
richiesta l'identità campione per campione (frequenza di campionamento, filtri e uscita
dipendono dall'hardware).

## 9. Conformità

- I vettori stanno in `docs/spec/conformance/` e sono generati da
  `tests/gen_conformance.lua` usando i moduli di lua32 (`cpu.lua`, `ppu.lua`,
  `cart.lua`) senza SDL.
- Ogni vettore è una cartuccia `.cart` più un file `.vec` di testo; ogni riga descrive un
  tick:

  ```
  <tick> <input_hex> <crc32 WRAM> <crc32 VRAM+OAM+CGRAM+porte+APU> <crc32 frame RGB> <A> <X> <Y> <FLAGS> <SP>
  ```

  Le CRC sono CRC-32 IEEE in esadecimale; il frame è la sequenza di 320×224×3 byte R, G,
  B per righe. La riga `crash` indica che il tick deve andare in crash.
- Un'implementazione è conforme alla versione 0.1 se riproduce **tutte** le righe di
  tutti i vettori.
- Il frame di riferimento usa i registri di scroll della macchina
  (`render_frame(mem, scroll_x, scroll_y, ...)`, vedi §10.1).

| Vettore | Cosa copre |
|---|---|
| `demo` | la `cart/demo.cart` di lua32 con 470 tick di input (frecce, azione, combinazioni, clamp ai bordi) |
| `cpu_ops` | un test per tick: flag Z/N/C/V di ogni operazione, AND/OR/XOR, shift, INC/DEC con avvolgimento, trasferimenti, stack, JSR/RTS annidati, indicizzati ,X/,Y, avvolgimento a 24 bit, porta di input a 8 bit, CLAMP, porte STAGE/GFX/SCROLL (anche con banco inesistente), CGRAM e APU scritte dalla CPU, flag persistenti, ciclo da ~100k istruzioni |
| `ppu` | 64 tick: tile 8/16/32/64 sovrapposti e celle coperte, trasparenza, 8 palette, scroll con avvolgimento della tilemap e a 16 bit, cambio di stage e di banco grafico, sprite con flip x/y, coordinate negative, fuori schermo, invisibili, tile 0, priorità fino allo slot 511 |
| `crash_opcode`, `crash_underflow`, `crash_overflow`, `crash_limit` | i quattro tipi di crash di §4.5 |
| `stack_smash` | lo stack scende fino a sovrascrivere il codice a `0x1000` (automodifica deterministica, nessun crash) |

Per rigenerarli: `luajit tests/gen_conformance.lua` (i file devono risultare identici,
la generazione è deterministica).

## 10. Problemi aperti e differenze trovate

1. **Scroll ignorato dal ciclo principale**: `main.lua` chiama
   `ppu.render_frame(mem, 0, 0, ...)` invece di usare `cpu.scroll_x/scroll_y`, quindi le
   porte `SCROLL_X/Y` non avevano effetto visibile. La specifica (§7.2) segue il design
   (lo scroll si applica); `main.lua` è stato allineato insieme a questa specifica.
2. **Modo 16:9 (384×224)**: descritto nel design ma non selezionabile. Serve un campo
   nell'header (proposta: un byte di `reserved0`) prima di usarlo.
3. **Header da 264 byte**: la scheda tecnica parla di 256 byte "packed"; il layout reale
   è quello di §6.1. D'ora in poi gli offset sono fissati qui, non dal compilatore.
4. **Sprite con tile 0** disegnati, a differenza delle celle di sfondo: comportamento
   documentato così com'è; da confermare se è voluto.
5. **Registri persistenti tra i tick**: documentato (§4.3). Da confermare se è voluto o se
   i registri vanno azzerati a ogni tick.
6. **JSR salva solo 16 bit**: lo stack è a 16 bit, quindi l'indirizzo di ritorno perde il
   byte alto e `RTS` torna sotto `0x010000`. Oggi il codice sta a `0x001000`, quindi non
   succede nulla; una subroutine chiamata da codice sopra `0x00FFFF` tornerebbe
   all'indirizzo sbagliato. Da decidere: documentarlo come limite (codice sotto 64 KiB) o
   salvare 24 bit (due push).

## 11. Proposta: cartucce Lua (non ancora implementata)

Obiettivo: cartucce scritte in Lua che girano sia su lua32 (LuaJIT, Lua 5.1) sia su bm33
(Lua 5.4), usando la **stessa macchina** (stessa VRAM, OAM, CGRAM, APU, input, stessi
limiti) al posto della CPU s32.

- **Tipo di codice**: `reserved0[0]` diventa `code_type`: `0` = codice macchina s32
  (tutte le cartucce esistenti), `1` = sorgente Lua in UTF-8 nella sezione codice.
- **Dialetto**: la parte comune di Lua 5.1 e 5.4. Vietati `//`, gli operatori
  `& | ~ << >>`, `goto`, `<const>`/`<close>`, `utf8`; per i bit si usa il modulo `bit` con
  l'API di LuaJIT (`bit.band`, `bit.bor`, `bit.bxor`, `bit.lshift`, `bit.rshift`, ...),
  che bm33 fornisce identico. Non si deve dipendere dalla differenza intero/decimale
  (`tostring(2^10)` dà `1024` su 5.1 e `1024.0` su 5.4).
- **Ciclo**: lo script viene eseguito una volta all'installazione; poi a ogni tick,
  dopo aver scritto le porte di input, si chiama la funzione globale `_update()`, poi la
  PPU genera il frame come per le cartucce s32.
- **API minima**: `peek(a)`, `poke(a, v)` (8 bit), `peek16(a)`, `poke16(a, v)` (16 bit con
  le stesse regole delle porte di §2.1), `btn(b [, player])`. Tutto il resto (tile, sprite,
  palette, suono) passa dalla mappa di memoria, esattamente come per il codice s32.
- **Da decidere**: limite di tempo per tick (es. numero massimo di istruzioni della VM
  tramite hook), gestione degli errori (equivalente al crash di §4.5), sandbox (niente
  `io`, `os`, `require`).
