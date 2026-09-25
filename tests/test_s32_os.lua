--[[
test_s32_os.lua - verifica os_config.lua (persistenza) e s32_os.lua
(scansione cart/dev, combo dev-mode) usando cartelle/file temporanei
veri, non mock - piu' vicino a cosa succede davvero su disco.

    luajit tests/test_s32_os.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local os_config = require("os_config")
local os_mod = require("s32_os")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local TMP = "/tmp/s32_test_os_" .. os.time()
os.execute("rm -rf " .. TMP .. " && mkdir -p " .. TMP .. "/cart " .. TMP .. "/dev")

-- ---------------------------------------------------------------
-- os_config: assente -> default; salva -> ricarica identico
-- ---------------------------------------------------------------
do
    local cfg_path = TMP .. "/nonexistent.cfg"
    local cfg = os_config.load(cfg_path)
    check("config assente: dev_mode default a false", cfg.dev_mode, false)

    cfg.dev_mode = true
    local ok = os_config.save(cfg, cfg_path)
    check("save() riesce", ok, true)

    local reloaded = os_config.load(cfg_path)
    check("dopo save+load: dev_mode persistito", reloaded.dev_mode, true)

    reloaded.dev_mode = false
    os_config.save(reloaded, cfg_path)
    local reloaded2 = os_config.load(cfg_path)
    check("save() sovrascrive, non accumula righe", reloaded2.dev_mode, false)
end

-- ---------------------------------------------------------------
-- scan_cart_dir: solo i *.cart, non altri file, ordinati
-- ---------------------------------------------------------------
do
    local dir = TMP .. "/cart"
    os.execute("touch " .. dir .. "/zeta.cart " .. dir .. "/alpha.cart " .. dir .. "/note.txt")
    local names = os_mod.scan_cart_dir(dir)
    check("scan_cart_dir: trova 2 .cart (non il .txt)", #names, 2)
    check("scan_cart_dir: ordinati per nome (alpha prima)", names[1], "alpha")
    check("scan_cart_dir: ordinati per nome (zeta dopo)", names[2], "zeta")
end

-- ---------------------------------------------------------------
-- scan_dev_dir: solo sottocartelle, rileva un .cart pre-impacchettato
-- ---------------------------------------------------------------
do
    local dir = TMP .. "/dev"
    os.execute("mkdir -p " .. dir .. "/progetto1 " .. dir .. "/progetto2")
    os.execute("touch " .. dir .. "/progetto1/progetto1.cart")
    os.execute("touch " .. dir .. "/nonunacartella.cart")  -- file, non directory: deve essere ignorato

    local entries = os_mod.scan_dev_dir(dir)
    check("scan_dev_dir: trova 2 sottocartelle (non il file)", #entries, 2)
    check("scan_dev_dir: ordinate per nome", entries[1].name, "progetto1")
    check("progetto1 ha un .cart pre-impacchettato rilevato", entries[1].cart_path ~= nil, true)
    check("progetto2 non ha ancora un .cart", entries[2].cart_path, nil)
end

-- ---------------------------------------------------------------
-- list_entries: cart/ sempre presente, dev/ solo se dev_mode
-- ---------------------------------------------------------------
do
    local old_cart, old_dev = os_mod.CART_DIR, os_mod.DEV_DIR
    os_mod.CART_DIR = TMP .. "/cart"
    os_mod.DEV_DIR = TMP .. "/dev"

    local entries_off = os_mod.list_entries(false)
    check("dev_mode off: solo le cartucce cart/ (2)", #entries_off, 2)
    for _, e in ipairs(entries_off) do
        check("dev_mode off: nessun ingresso di tipo dev (" .. e.name .. ")", e.kind, "play")
    end

    local entries_on = os_mod.list_entries(true)
    check("dev_mode on: cart/ (2) + dev/ (2) = 4", #entries_on, 4)

    os_mod.CART_DIR, os_mod.DEV_DIR = old_cart, old_dev
end

-- ---------------------------------------------------------------
-- new_dev_toggle_tracker: solo il fronte di salita, non ripetuto
-- ---------------------------------------------------------------
do
    local t = os_mod.new_dev_toggle_tracker()
    check("combo non premuta: nessun fronte", t:update(false), false)
    check("combo premuta: fronte rilevato", t:update(true), true)
    check("combo ancora tenuta: nessun altro fronte", t:update(true), false)
    check("combo rilasciata: nessun fronte", t:update(false), false)
    check("combo ripremuta: nuovo fronte", t:update(true), true)
end

-- ---------------------------------------------------------------
-- toggle_dev_mode: inverte e persiste
-- ---------------------------------------------------------------
do
    local cfg_path = TMP .. "/toggle.cfg"
    local cfg = os_config.load(cfg_path)
    check("stato iniziale: dev_mode off", cfg.dev_mode, false)

    local new_state = os_mod.toggle_dev_mode(cfg, cfg_path, os_config)
    check("toggle_dev_mode: ritorna true", new_state, true)

    local reloaded = os_config.load(cfg_path)
    check("toggle_dev_mode: persistito su disco", reloaded.dev_mode, true)
end

os.execute("rm -rf " .. TMP)

-- ---------------------------------------------------------------
-- new_edge_tracker: fronte di salita indipendente per piu' tasti
-- ---------------------------------------------------------------
do
    local t = os_mod.new_edge_tracker()
    local e1 = t:update({ up = true, down = false })
    check("edge_tracker: su scatta al primo frame", e1.up, true)
    check("edge_tracker: giu' non scatta (non premuto)", e1.down, false)

    local e2 = t:update({ up = true, down = false })
    check("edge_tracker: su NON riscatta mentre resta premuto", e2.up, false)

    local e3 = t:update({ up = false, down = true })
    check("edge_tracker: su rilasciato non scatta", e3.up, false)
    check("edge_tracker: giu' scatta al fronte di salita", e3.down, true)
end

-- ---------------------------------------------------------------
-- Session: navigazione a griglia
-- ---------------------------------------------------------------
do
    local entries = { {name="a"}, {name="b"}, {name="c"}, {name="d"}, {name="e"} }
    local cols = 2  -- griglia 2 colonne: [a b] [c d] [e]
    local s = os_mod.new_session()
    check("session: cursore iniziale a 1", s.cursor, 1)

    s:move(1, 0, entries, cols)  -- destra: a(1,1) -> b
    check("move destra: da a a b", s.cursor, 2)

    s:move(1, 0, entries, cols)  -- destra oltre il bordo: resta su b (2 colonne)
    check("move destra oltre il bordo: resta fermo", s.cursor, 2)

    s:move(0, 1, entries, cols)  -- giu': da b(riga0,col1) a d(riga1,col1)
    check("move giu': da b a d", s.cursor, 4)

    s:move(0, 1, entries, cols)  -- giu' ancora: riga2 avrebbe solo "e" (col0) - col1 non esiste, si ferma sull'ultima voce
    check("move giu' su riga incompleta: si ferma sull'ultima voce", s.cursor, 5)

    s:move(0, -1, entries, cols)  -- su: torna verso la riga1 (indice colonna quello richiesto, non quello "visivo" di e)
    -- e sta a riga2/col0 "virtuale" (idx5 -> row=floor(4/2)=2,col=0), su -> row1,col0 -> idx3 = "c"
    check("move su: torna alla riga sopra", s.cursor, 3)

    local s2 = os_mod.new_session()
    s2:move(-1, 0, entries, cols)
    check("move sinistra dal bordo sinistro: resta fermo", s2.cursor, 1)
    s2:move(0, -1, entries, cols)
    check("move su dalla riga superiore: resta fermo", s2.cursor, 1)

    local s3 = os_mod.new_session()
    s3:move(1, 1, {}, cols)  -- elenco vuoto: nessun crash, cursore invariato
    check("move su elenco vuoto: nessun crash, cursore invariato", s3.cursor, 1)
end

-- ---------------------------------------------------------------
-- Session: confirm/pausa/switch/conferma
-- ---------------------------------------------------------------
do
    local entries = {
        { name = "demo", kind = "play" },
        { name = "puzzle", kind = "play" },
    }
    local s = os_mod.new_session()

    check("mode iniziale: picker", s:mode(), "picker")

    -- prima cartuccia: nessuna in pausa -> lancio diretto
    local a1 = s:confirm(entries)
    check("confirm senza pausa: action=launch", a1.action, "launch")
    check("confirm senza pausa: entry giusta", a1.entry.name, "demo")

    -- il gioco parte, poi l'utente preme ESC -> in pausa
    s:on_paused({ name = "demo", kind = "play" })

    -- riseleziona la STESSA cartuccia -> resume, non un nuovo dialogo
    local a2 = s:confirm(entries)
    check("confirm stessa cartuccia in pausa: action=resume", a2.action, "resume")
    check("mode dopo resume: resta picker (nessun dialogo)", s:mode(), "picker")

    -- seleziona un'ALTRA cartuccia mentre demo e' in pausa -> serve conferma
    s.cursor = 2
    local a3 = s:confirm(entries)
    check("confirm altra cartuccia con una in pausa: action=ask_confirm", a3.action, "ask_confirm")
    check("mode durante il dialogo: confirm_switch", s:mode(), "confirm_switch")

    -- annulla: si resta nel picker, "demo" e' ANCORA in pausa
    s:confirm_switch_no()
    check("dopo annulla: mode torna a picker", s:mode(), "picker")
    s.cursor = 1
    local a4 = s:confirm(entries)
    check("dopo annulla: demo e' ancora in pausa (resume, non launch)", a4.action, "resume")

    -- stavolta conferma per davvero
    s.cursor = 2
    s:confirm(entries)  -- rientra in confirm_switch
    local launched = s:confirm_switch_yes()
    check("confirm_switch_yes: ritorna la nuova voce", launched.name, "puzzle")
    check("dopo confirm_switch_yes: mode torna a picker", s:mode(), "picker")

    -- demo non e' piu' in pausa (e' stata chiusa) - selezionarla ora
    -- landerebbe "puzzle" in pausa una volta lanciata, ma qui puzzle
    -- non e' ancora "in pausa" finche' main.lua non chiama on_paused()
    s.cursor = 1
    local a5 = s:confirm(entries)
    check("dopo lo switch: nessuna cartuccia in pausa finche' non arriva ESC", a5.action, "launch")
end

-- ---------------------------------------------------------------
-- Session:on_closed - usato da main.lua quando una cartuccia va in
-- crash (vedi il pcall attorno al tick loop): deve "dimenticare" la
-- pausa anche se la cartuccia era stata ripresa da pausa e POI e'
-- andata in crash (altrimenti il picker continuerebbe a offrire
-- "resume" su una cartuccia che non esiste piu', vedi la conversazione)
-- ---------------------------------------------------------------
do
    local entries = { { name = "demo", kind = "play" } }
    local s = os_mod.new_session()

    s:confirm(entries)              -- lancio diretto (nessuna pausa)
    s:on_paused(entries[1])         -- ESC: demo va in pausa
    s:confirm(entries)              -- riseleziona demo: action=resume, ma paused NON viene sgomberato da confirm()
    check("dopo resume: risulta ancora 'in pausa' (main.lua non l'ha ancora chiuso)", s.paused ~= nil, true)

    s:on_closed()                   -- demo e' andata in crash mentre girava di nuovo
    check("dopo on_closed: nessuna cartuccia risulta piu' in pausa", s.paused, nil)

    local a = s:confirm(entries)
    check("dopo on_closed: riselezionarla la rilancia da capo, non 'resume' a vuoto", a.action, "launch")
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
