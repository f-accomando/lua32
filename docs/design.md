# s32 — design del motore (lua32)

Questo documento raccoglie le decisioni prese ripensando da zero la
console **s32**, questa volta interamente in LuaJIT invece che in
Python. `lua32` è il nome del repository/codebase; **s32 resta il nome
della console**, la stessa identità di prima, solo con un motore nuovo.

Nessuna cartuccia, test o codice del vecchio progetto Python viene
portato qui: si riparte da zero, con l'esperienza raccolta ma senza
vincoli di compatibilità.

## Perché si riparte da zero

Il vecchio motore (Python + Cython) su Raspberry Pi 1 con un LCD SPI
era limitato dalla banda del bus SPI durante lo scroll (~3-9fps in
gioco). Due scoperte hanno cambiato il quadro:

1. **HDMI + GPU funziona davvero** su questo Pi 1 (driver `vc4-kms-v3d`,
   Mesa/EGL) — bypassando del tutto il collo di bottiglia SPI. Con
   `--gpu-renderer` il gioco vero è passato da 3-9fps a 35-45fps in
   gioco, 58-62fps a schermo fermo.
2. **LuaJIT è molto più veloce di Cython** per l'emulazione della CPU:
   misurato sul Raspberry Pi 1 vero, ~6.5x più veloce (24.10us/istruzione
   Cython `-O1` contro 3.72us/istruzione LuaJIT), verificato byte per
   byte identico a `cpu.py` prima di fidarsi del numero.

Con questi due margini, il vincolo di prestazioni che aveva spinto a
considerare un demake pesante (stile Pico-8, risoluzione minuscola) è
in gran parte sparito. Si è deciso comunque di **abbandonare Python
per Lua su tutti i fronti** (non solo la CPU) e di **ripartire da zero
sul design** (risoluzione, tile, memoria) visto che comunque si crea
un repository nuovo.

## Decisione architetturale di fondo: CPU/PPU custom, non scripting

Discusse due strade: (a) mantenere una CPU/PPU custom che emula
hardware vero (ISA, bus, registri — l'approccio di sempre), oppure
(b) passare a giochi scritti direttamente in Lua come script, stile
Pico-8 (nessuna CPU emulata, i giochi chiamano funzioni di libreria
direttamente).

**Decisione: (a), CPU/PPU custom.** È quello che rende questo progetto
unico rispetto a Pico-8 — un motore di scripting con estetica retro
esiste già (Pico-8 stesso); una console che emula hardware vero
(bus a 24-bit, registri a 16-bit, memoria mappata) è la cosa
distintiva di s32. Il motivo originale per considerare lo scripting
puro era la disperazione da prestazioni sul Pi 1 — con HDMI+GPU+LuaJIT
quel motivo è in gran parte sparito, quindi la scelta è tornata a
essere di identità/gusto, non di sopravvivenza.

**Nessun sistema a token** (a differenza di Pico-8): i token di Pico-8
sono comunque un limite sul CODICE sorgente a tempo di compilazione,
non un vero budget di prestazioni (un ciclo che itera 1000 volte
costa gli stessi token del corpo scritto una volta) — non aggiunge
garanzie reali, solo complessità. Il vincolo di prestazioni resta
quello vero e naturale: quanto ci mette la CPU emulata a eseguire le
istruzioni di un frame.

## Target hardware e video

- **Output di riferimento: HDMI + GPU** (KMSDRM/vc4) — l'LCD SPI non
  guida più le decisioni di design, resta al più un percorso
  opzionale futuro.
- **Due modalità: 30fps e 60fps**, 60 di default.
- **Risoluzione**: altezza fissa **224px**, due larghezze:
  - **4:3 → 320×224** (identica al Sega Genesis)
  - **16:9 → 384×224** (rapporto 1.714, vicino a 1.778 esatto)

  Divisibilità per le taglie di tile (vedi sotto): 320 e 384 sono
  entrambe multiple di 8/16/32/64. L'altezza 224 è pulita per 8/16/32
  ma non per 64 (224/64 = 3.5) — accettato: i tile da 64px saranno
  rari (elementi grandi/speciali), un mezzo tile tagliato sul bordo
  non è un problema pratico diverso da quelli che ogni gioco a tile
  già gestisce.
- **Nessun letterboxing**: l'immagine nativa viene RISCALATA per
  riempire lo schermo (non centrata con bordo nero) — con la GPU la
  scala è gratis, a differenza del vecchio vincolo SPI che imponeva
  di non toccare byte extra.

## Tile e sprite

- **Base 8×8**, taglie disponibili come **potenze di due: 8/16/32/64**,
  liberamente selezionabili per singolo tile/sprite.
- Ispirato a SNES (base 8×8, sprite fino a 64×64) e Pico-8 (base 8×8,
  composizione di celle) ma SENZA i vincoli artificiali di nessuno dei
  due: niente limite SNES di "una sola coppia di taglie attiva alla
  volta" (era un limite di silicio anni '90), niente "assemblaggio
  libero di celle contigue" di Pico-8 (più complesso da implementare
  nel PPU) — ogni tile/sprite dichiara semplicemente UNA taglia fissa
  tra le quattro disponibili.
- **Tilemap: griglia densa a 8×8** (opzione A, scelta rispetto a una
  lista sparsa di posizionamenti stile-OAM): un tile più grande si
  piazza nella cella "origine" e occupa per convenzione il blocco di
  celle successive (es. un tile 32×32 copre 4×4 celle) — il PPU lo
  disegna sopra, le celle "coperte" sotto non servono. Evoluzione
  naturale del motore attuale, non uno stravolgimento.
- **Indirizzamento VRAM**: dato che tile di taglie diverse occupano
  byte diversi (8×8=64B, 16×16=256B, 32×32=1024B, 64×64=4096B), non
  si può più calcolare l'indirizzo per moltiplicazione fissa come
  prima. Nuovo schema: un **archivio piatto di byte** (i tile
  convivono, allineati a 64 byte — mcd tra le dimensioni delle 4
  taglie) più una **tabella "directory"** che per ogni tile-ID
  registra dove inizia e quanto è grande.

## Colore

- **CGRAM a 24-bit (RGB888)**, non più 15-bit come nel vecchio motore
  — la giustificazione per il 15-bit (formato nativo RGB565 dell'LCD)
  non esiste più con HDMI truecolor come target, e l'implementazione
  a 24-bit è anche più semplice (nessun bit-packing 5-5-5).
- **8 palette da 256 colori**, indice 0 sempre trasparente — invariato
  rispetto a prima.
- I dati grafici dei tile in VRAM restano indici a 8 bit verso una
  palette (mai colori diretti) — questo significa che il formato
  della CGRAM è completamente disaccoppiato dal formato dei tile:
  cambiare precisione colore non tocca mai gli asset grafici.
- **Editor con palette curata** (limitata, colori specifici da
  scegliere quando si costruisce l'editor vero) come guida creativa di
  default — ma la capacità di storage resta piena a 24-bit, quindi
  **import esterno (PNG e simili) può usare qualunque colore**, senza
  la restrizione della palette curata dell'editor.

## CPU

- **83 opcode**: i 55 esistenti (LDA/STA/LDX/STX/LDY/STY, TAX/TXA/TAY/
  TYA/TXY/TYX, ADD/SUB/AND/OR/XOR/CMP in immediata+indirizzo, ASL/LSR,
  INC/DEC/INX/INY/DEX/DEY, JMP/JZ/JNZ/JLT/JGE/JCS/JCC/JSR/RTS,
  PHA/PLA/PHX/PLX/PHY/PLY, IN, CLAMPX/CLAMPY) **più 28 nuovi opcode
  indicizzati**: varianti `,X` e `,Y` per le 14 istruzioni che oggi
  leggono/scrivono un indirizzo assoluto fisso (LDA/STA/LDX/STX/LDY/
  STY, ADD/SUB/AND/OR/XOR/CMP, INC/DEC). (Il vecchio commento nel
  progetto Python parlava di "54 istruzioni" ma la tabella di dispatch
  vera ne contava 55 - contate qui per davvero, non copiate dal
  commento.)
- Motivazione dell'indicizzazione: senza di essa, accedere a un array
  (slot OAM, righe di tilemap, tabelle di stato) richiede costruire
  l'indirizzo a mano ogni volta — esattamente il tipo di lavoro che un
  motore di gioco fa in continuazione.
- Sia X che Y possono indicizzare qualunque istruzione indirizzo —
  niente delle asimmetrie del 6502 vero (limiti di silicio, non hanno
  motivo di esistere qui).
- Per confronto: il 65816 vero dello SNES ha ~92 istruzioni × ~24
  modalità di indirizzamento = tutti i 256 valori di un byte opcode
  occupati. 83 resta volutamente più snello — niente indiretto,
  niente stack-relative, un solo formato a 24-bit per gli indirizzi.
  Restano 173/256 opcode liberi per estensioni future SE emerge un
  bisogno concreto scrivendo giochi veri (mai aggiungere per
  simmetria astratta, come dice giustamente `memory_map.py` del
  vecchio progetto sullo spazio libero non assegnato).

## Audio

- **Sintesi procedurale**, non campioni PCM — parametri (tipo onda,
  frequenza, durata, inviluppo) invece di audio pre-registrato, come
  un vero APU NES/Genesis (canali pulse/triangle/noise generati da
  oscillatori, non sample). Footprint minuscolo, coerente con
  l'autenticità hardware del resto del progetto.
- **Dentro la mappa di memoria** (non più un asset Python/Lua esterno
  come il vecchio `sound_bank.py`) — una regione dedicata, stesso
  pattern di VRAM/OAM/CGRAM. `PORT_SOUND` (scrivi un ID, parte il
  suono) resta concettualmente uguale, ma l'ID ora punta a una
  definizione dentro la mappa di memoria.

## Cartucce

- **Nessun limite dichiarato aggiuntivo**: dato che codice, grafica E
  audio sono tutti memory-mapped, "quanto è grande una cartuccia" =
  "quanto spazio occupa nella mappa di memoria indirizzabile" — lo
  stesso vincolo naturale che già esiste, nessun tetto artificiale
  in più (coerente con l'aver scartato i token).

- **IMPORTANTE — correzione rispetto a una prima idea**: una cartuccia
  grande NON significa che tutto il suo contenuto debba stare
  residente in VRAM/APU contemporaneamente. Il bus a 24-bit flat
  garantisce solo che l'indirizzamento sia unico e senza banking — non
  impone che i 552KB di VRAM (o la futura regione APU) debbano
  contenere OGNI asset della cartuccia insieme. Le vere console
  funzionavano così: lo SNES vero aveva solo 64KB di VRAM fisica anche
  con cartucce da 6MB — il gioco copiava (DMA) solo la grafica della
  scena ATTUALE, sostituendola ai cambi di livello/mondo.

  Abbiamo già questo esatto meccanismo per un solo tipo di dato:
  `PORT_STAGE_SELECT` copia istantaneamente la tilemap di uno stage
  dentro la (piccola, fissa) VRAM attiva — i dati di TUTTI gli stage
  vivono nel file della cartuccia (`cpu.stages`, sul filesystem host),
  non tutti in memoria emulata insieme. La stessa idea si estende
  naturalmente a banchi di grafica (e potenzialmente audio): la
  cartuccia su disco può essere molto più grande di 552KB (un
  riferimento comodo per confronto è l'intervallo dei cartucce SNES
  veri, 256KB-6MB), mentre l'archivio grafico ATTIVO resta piccolo e
  fisso — il gioco (o il motore per suo conto) fa lo swap quando
  serve, invece di richiedere una VRAM residente enorme. Il formato
  cartuccia vero (banchi + meccanismo di swap) è ancora da progettare
  — vedi "punti ancora aperti" in fondo.

- **Distinto dai coprocessori**: il vecchio progetto aveva riservato
  spazio ("roadmap punto 1", mai implementato) per eventuali chip
  coprocessori aggiuntivi (come il SuperFX dello SNES vero) — registri
  memory-mapped per parlare con hardware di calcolo EXTRA che alcune
  cartucce potrebbero portarsi dietro. È un concetto ORTOGONALE allo
  swap di banchi sopra: quello è spazio per più CONTENUTO (asset),
  questo è capacità di CALCOLO in più — non competono per lo stesso
  spazio, sono due regioni diverse ritagliate dai ~15MB liberi che il
  bus a 24-bit lascia comunque disponibili.

- **Perché l'archivio grafico è 512KB e non i vecchi 96-128KB**: la
  tabella "directory" (8KB, vedi sopra) è un costo strutturalmente
  necessario del passaggio a tile a taglia variabile (l'indirizzamento
  a moltiplicazione fissa del vecchio motore non funziona più quando i
  tile hanno byte-size diversi) — non negoziabile una volta decise le
  taglie variabili. La crescita dell'archivio vero e proprio
  (96KB→512KB, da 96 a 2048 tile indirizzabili) è invece stata una
  scelta discrezionale (filosofia "meglio generosi" già del vecchio
  progetto), confermata con l'utente e non più in discussione.

### Formato cartuccia (implementato)

Un file `.cart` è un contenitore binario (`cart.lua`) con un header a
dimensione fissa (256 byte, packed) seguito dai contenuti veri:

- **Header**: magic (`S32CART1`), versione, **uid** (16 byte,
  identificatore della cartuccia), titolo, autore, data di creazione,
  offset/dimensione di ciascuna sezione, **content_crc32** (integrità:
  rileva corruzione accidentale del file) e **content_sha256** (32
  byte, riservato ma non ancora calcolato — vedi "Autenticità/NFT"
  sotto).
- **Codice**: i byte assemblati (oggi prodotti da `assembler.lua`, in
  futuro anche da un eventuale ConsoleLang).
- **Banchi di stage** (tilemap, 32KB l'uno): stesso identico
  meccanismo già in uso per `PORT_STAGE_SELECT`, solo ora popolato dal
  contenuto del file invece che da dati scritti a mano in `main.lua`.
- **Banchi grafici** (directory+archivio, ~520KB l'uno): stessa idea
  estesa alla grafica, via la nuova porta `PORT_GFX_BANK_SELECT`
  (`memory_map.lua`) — scrivere un numero di banco copia
  istantaneamente quella directory+archivio dentro la VRAM attiva
  (`cpu.gfx_banks[n]`, popolato dal loader). Questo è il meccanismo di
  swap discusso sopra: la cartuccia su disco può avere N banchi
  grafici, la VRAM ne tiene sempre e solo uno attivo.
- **Palette iniziale** (CGRAM, 6KB, opzionale): se presente viene
  copiata in CGRAM al caricamento.

`cart.pack(spec, path)` scrive il file da bytes già pronti (codice +
banchi), `cart.load(path)` lo rilegge e verifica il CRC32,
`cart.install(cpu, cart, load_addr)` lo installa in una CPU (copia il
codice, registra `cpu.stages`/`cpu.gfx_banks`, fa lo swap iniziale a
banco 0). Verificato con `tests/test_cart.lua` (round-trip
byte-per-byte, esecuzione del codice caricato, rilevamento di un file
corrotto).

**Cosa NON fa ancora, deliberatamente**: non esiste una pipeline
`dev/<cartuccia>/` (cartella sorgente con PNG/JSON) → `.cart` — non ha
senso costruirla prima che esista l'editor stesso (è l'editor che
produrrebbe quei sorgenti). Oggi `cart.pack()` lavora al livello che
`main.lua` già usa (bytes pronti), che è il livello giusto finché
l'editor non esiste.

### Autenticità cartuccia / possibili NFT (futuro, deliberatamente aperto)

Interesse futuro dell'utente: poter distribuire cartucce come NFT, per
dare la possibilità di riconoscere/scambiare cartucce "originali" e
dare ai developer un token di apprezzamento/vendita. Il motore stesso
resta agnostico rispetto a blockchain/NFT — quel livello vive
interamente fuori dall'engine (in una eventuale registry/marketplace
esterno). Quello che il **formato cartuccia** già prepara, per non
dover rompere compatibilità in futuro:

- **`uid`** (16 byte, nell'header): identificatore univoco della
  cartuccia, generato una volta al pack (`cart.new_uid()`), stabile
  per tutta la vita del file — il "numero seriale" richiesto.
- **`content_sha256`** (32 byte, riservato): hash crittografico del
  contenuto, per legare univocamente un file a un record esterno
  (NFT/registry). Oggi zero-riempito — l'integrità del file è comunque
  garantita da CRC32, l'hash crittografico si implementa quando esiste
  un uso reale a valle (nessuna libreria SHA-256 nel progetto ancora,
  aggiunta prematura altrimenti).

Tutto il resto (mint, marketplace, verifica on-chain) resta
esplicitamente non progettato.

### Icona cartuccia nell'OS (futuro, solo visivo)

Idea dell'utente: dare all'icona di una cartuccia, nella griglia di
selezione dell'OS (cart-picker), una forma che richiami le schede SD
grandi — **angolo inferiore sinistro tagliato**. Chiarito esplicitamente
che è **solo la forma dell'icona/asset visivo nell'interfaccia**, NON
un fattore di forma hardware fisico (nessuna cartuccia fisica reale è
in programma). Riguarda l'OS/cart-picker, non ancora costruito — nessun
asset o codice creato per questo, solo annotato qui come nota di
design per quando si costruisce l'OS.

## Libreria grafica/input/audio

- **LuaJIT nudo + FFI + SDL2 diretto** (NON LÖVE2D o altro framework).
- Motivazione: il progetto ha già il proprio PPU che compone un intero
  frame di pixel — quello che serve dall'ambiente ospite è stretto e
  già ben definito (spingere un buffer di pixel sullo schermo via
  texture GPU, spingere un buffer audio generato dalla sintesi
  procedurale, leggere input, caricare file), non un'API di disegno
  2D generica. Un framework completo porterebbe dietro molto che non
  verrebbe mai usato, e piegherebbe il modello "frame già composto"
  dentro astrazioni pensate per "disegna cosa serve ogni frame".
- Verificato in sessione con `fbtest.lua` (scrittura diretta su
  framebuffer via mmap) e `cpu.lua`/`bench_cpu.lua` (FFI per
  `clock_gettime`, lettura file binari) — lo stesso approccio si
  estende naturalmente a SDL2 per finestra/GPU/input/audio.
- Costo accettato: bisogna scrivere a mano i binding FFI per SDL2
  (finestra, renderer, texture, eventi, audio) e per il caricamento
  immagini — nessun gamepad/audio-device management già pronto come
  darebbe un framework.

## OS

- **Selezione cartuccia + lancio diretto** — nessun sottomenu
  modalità/rete come nel vecchio menu (Locale/Ospita/Unisciti): si
  sceglie la cartuccia e si gioca.
- **Sospensione persistente, stile Nintendo Switch**: lanciare una
  cartuccia non "chiude" l'OS — resta viva in memoria. Il pulsante
  menu/ESC SOSPENDE la cartuccia (stato CPU/PPU preservato) invece di
  interromperla, e tornando si riprende esattamente da dove si era.
- **Flag dev-mode**: decide dove porta il pulsante menu mentre una
  cartuccia gira — **salto diretto**, nessun overlay di pausa
  intermedio:
  - dev spento → Home (selezione cartucce)
  - dev acceso → Editor, aperto sulla cartuccia corrente
- **Editor unico a tab**: Codice / Grafica / Suoni, stile Pico-8 (un
  solo ambiente, non tre strumenti separati). Grafica e Suoni possono
  partire come placeholder vuoti, sviluppati in seguito — Codice
  funzionante da subito.
- **Profilo giocatore** (nickname + avatar, salvato su disco) —
  mantenuto dal vecchio progetto.
- **Rendering**: l'OS gira attraverso la STESSA pipeline nativa bassa
  risoluzione + rescale GPU dei giochi (stile "system cart" — grafica
  a tile, non una finestra desktop separata con font di sistema come
  il vecchio `os_menu.py` a 520px di altezza). Le vere console a
  cartuccia (SNES/Genesis/NES) non avevano comunque un simile "menu
  multi-cartuccia" — è un'invenzione da flashcart moderna, quindi non
  c'è un vincolo di fedeltà storica da rispettare qui, solo coerenza
  visiva interna.
- **L'OS non è una cartuccia**: gira come codice Lua nativo del motore
  (scrive direttamente su PPU/VRAM), non compilato/eseguito dalla CPU
  emulata — è firmware, non contenuto di un gioco, quindi non è
  soggetto al budget di istruzioni. Da confermare in dettaglio quando
  si costruisce l'OS per davvero.
- **Rete/multiplayer**: NESSUNA gestione a livello OS — se una
  cartuccia vuole il multiplayer, se lo implementa da sola (l'OS non
  sa nulla di host/join/scansione LAN).
- **Download cartucce**: menzionato esplicitamente dall'utente come
  interesse futuro, deliberatamente lasciato sospeso — nessun design
  fatto qui.

## Struttura del repository

```
/                    <- solo elementi della console (motore)
  cpu.lua            <- CPU (83 opcode)
  ppu.lua            <- PPU (compositing tile/sprite)
  apu.lua            <- sintesi audio procedurale
  memory_map.lua     <- mappa indirizzi, unica fonte di verità
  assembler.lua      <- assembler ASM
  consolelang.lua    <- compilatore ConsoleLang (se mantenuto)
  os.lua             <- OS: selezione cartucce, sospensione/ripresa, dev-mode
  editor.lua         <- editor unico a tab (Codice/Grafica/Suoni)
  profile.lua        <- profilo giocatore
  video.lua / input.lua / audio_out.lua  <- binding FFI diretti a SDL2
  main.lua           <- punto di ingresso, loop principale

cart/                <- cartucce SOLO gioco (finite, giocabili)
dev/                 <- cartucce in lavorazione (quelle che l'editor apre/modifica)
docs/                <- documentazione (questo file e altri)
tests/               <- test automatici + altri script di supporto (benchmark, tool)
```

## Punti ancora aperti / da decidere durante la costruzione

- Se mantenere ConsoleLang come linguaggio di alto livello sopra
  l'assembler, o ripensarlo/rifarlo.
- Dettagli dell'editor (Grafica/Suoni) — palette curata esatta,
  formato dei livelli editabili.
- Se/come l'OS gestisce il salvataggio dello stato (save state) dato
  che ora sospende invece di chiudere.
- Download cartucce (deliberatamente sospeso).
- ~~Formato cartuccia vero, con banchi di grafica/audio e un
  meccanismo di swap~~ — **fatto**: contenitore binario `.cart`
  (`cart.lua`) con banchi di stage e grafica swappabili via
  `PORT_GFX_BANK_SELECT`, vedi "Cartucce" sopra. Ancora aperto: banco
  audio (quando esiste `apu.lua`), e la pipeline sorgente
  `dev/<cartuccia>/` → `.cart` (dipende dall'editor, non ancora
  costruito).
- Eventuale regione per coprocessori (concetto separato dallo swap di
  banchi, vedi "Cartucce" sopra) — non ancora progettata.
- Hash crittografico reale (`content_sha256`) nell'header cartuccia —
  campo riservato, non ancora calcolato (vedi "Autenticità/NFT").
- Icona cartuccia nel cart-picker dell'OS (forma "SD tagliata") — solo
  annotato, nessun asset/codice ancora.
