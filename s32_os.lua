--[[
s32_os.lua - selezione cartucce, sospensione/ripresa, dev-mode.

Chiamato "s32_os.lua" e non "os.lua" (come diceva ancora design.md)
per una collisione scoperta scrivendolo: "os" e' gia' il nome della
libreria standard di Lua, precaricata in package.loaded PRIMA che
require() guardi il filesystem - un file locale os.lua non verrebbe
MAI raggiunto da require("os"), tornerebbe sempre la libreria
standard. Non un problema di stile, proprio irraggiungibile.

Stato di questa prima release: solo la parte "logica" (scansione
cart/dev, combo dev-mode con persistenza) - funzioni pure, testabili
senza aprire una finestra SDL2 (vedi tests/test_s32_os.lua). La grafica del
cart-picker (griglia di sprite stile icona "SD tagliata", vedi
design.md "Icona cartuccia nell'OS") e il loop di pausa/ripresa in RAM
sono il passo successivo, da integrare in main.lua - qui c'e' solo cio'
che serve per arrivarci senza dover ancora decidere i dettagli grafici.

Cartelle (vedi design.md "Struttura cartelle"):
  cart/<nome>.cart   - cartucce finite, sempre visibili nel picker
  dev/<nome>/        - cartucce in lavorazione (quelle che l'editor
                       apre/modifica come sorgenti PNG/JSON) - visibili
                       SOLO in dev-mode. La pipeline sorgente -> .cart
                       dipende dall'editor (non ancora costruito): per
                       ora una cartuccia dev e' "lanciabile" solo se la
                       cartella contiene gia' un .cart pre-impacchettato
                       con lo stesso nome (dev/foo/foo.cart) - altrimenti
                       "esegui" restituisce un messaggio onesto invece
                       di fingere che funzioni.

Elenco cartelle via shell (`ls`, come sysinfo.lua fa gia' per
vcgencmd) invece di FFI diretto su opendir/readdir: struct dirent ha
layout diverso fra ARM 32-bit (il Pi) e x86_64 (la sandbox) - lo stesso
tipo di trappola gia' vista con SDL_AudioSpec, e qui non ne vale la
pena: elencare una cartella succede solo quando si apre il menu, non a
ogni frame, quindi non serve la velocita' di una chiamata FFI diretta.
]]
local M = {}

M.CART_DIR = "cart"
M.DEV_DIR = "dev"

-- quota un argomento per la shell POSIX (racchiude in apici singoli,
-- raddoppia eventuali apici singoli interni) - evita di dover fidarsi
-- che i nomi di cartella non contengano mai caratteri speciali
local function shell_quote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function popen_lines(cmd)
    local lines = {}
    local p = io.popen(cmd)
    if not p then return lines end
    for line in p:lines() do table.insert(lines, line) end
    p:close()
    return lines
end

-- scan_cart_dir(dir): nomi dei file *.cart direttamente dentro dir (non
-- ricorsivo), senza estensione, ordinati per nome - l'ordine deve
-- essere deterministico (non quello di readdir del filesystem, che non
-- e' garantito) perche' il picker lo mostra cosi' com'e'.
function M.scan_cart_dir(dir)
    local names = {}
    for _, line in ipairs(popen_lines("ls -1 -- " .. shell_quote(dir) .. " 2>/dev/null")) do
        local name = line:match("^(.+)%.cart$")
        if name then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

-- scan_dev_dir(dir): nomi delle SOTTOCARTELLE dentro dir (non i file -
-- "ls -1p" aggiunge "/" alle directory, i file restano senza), ordinati
-- per nome. Per ciascuna dice anche se esiste gia' dev/<nome>/<nome>.cart
-- (impacchettamento manuale di comodo finche' l'editor non c'e').
function M.scan_dev_dir(dir)
    local entries = {}
    for _, line in ipairs(popen_lines("ls -1p -- " .. shell_quote(dir) .. " 2>/dev/null")) do
        local name = line:match("^(.+)/$")
        if name then
            local cart_path = dir .. "/" .. name .. "/" .. name .. ".cart"
            local f = io.open(cart_path, "rb")
            local packaged = f ~= nil
            if f then f:close() end
            table.insert(entries, { name = name, cart_path = packaged and cart_path or nil })
        end
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries
end

-- list_entries(dev_mode): l'elenco unificato che il picker deve
-- mostrare - cart/ sempre, dev/ solo se dev_mode e' vero. Ogni
-- ingresso: {name=, kind="play"|"dev", cart_path=}. kind="dev" e'
-- quello che decide, nel picker, se offrire "esegui"+"modifica" invece
-- del solo "esegui" (vedi commento in testa sui pulsanti diversi).
function M.list_entries(dev_mode)
    local out = {}
    for _, name in ipairs(M.scan_cart_dir(M.CART_DIR)) do
        table.insert(out, { name = name, kind = "play", cart_path = M.CART_DIR .. "/" .. name .. ".cart" })
    end
    if dev_mode then
        for _, e in ipairs(M.scan_dev_dir(M.DEV_DIR)) do
            table.insert(out, { name = e.name, kind = "dev", cart_path = e.cart_path })
        end
    end
    return out
end

-- new_dev_toggle_tracker(): rileva SOLO il fronte di salita della combo
-- dev-mode (non ripetutamente finche' resta premuta) - stesso pattern
-- di debounce gia' usato in main.lua per il bottone azione (prev_action),
-- qui incapsulato cosi' e' testabile senza SDL2 vero (vedi
-- tests/test_os.lua: passa semplicemente true/false a mano a update()
-- invece di leggere una tastiera reale).
function M.new_dev_toggle_tracker()
    local held_prev = false
    return {
        -- update(held_now): ritorna true SOLO nel frame in cui la combo
        -- passa da non-premuta a premuta.
        update = function(_, held_now)
            local edge = held_now and not held_prev
            held_prev = held_now
            return edge
        end,
    }
end

-- toggle_dev_mode(cfg, config_path): inverte cfg.dev_mode, lo salva su
-- disco (permanente, come chiesto - non solo per la sessione corrente)
-- e stampa un messaggio cosi' e' chiaro sul terminale cosa e' successo.
-- Ritorna il nuovo valore di dev_mode.
function M.toggle_dev_mode(cfg, config_path, os_config)
    os_config = os_config or require("os_config")
    cfg.dev_mode = not cfg.dev_mode
    local ok, err = os_config.save(cfg, config_path)
    if not ok then
        print("s32: impossibile salvare os_config (" .. tostring(err) .. ") - il cambio vale solo per questa sessione")
    end
    print("s32: dev-mode " .. (cfg.dev_mode and "ATTIVATA" or "DISATTIVATA") .. " (permanente)")
    return cfg.dev_mode
end

return M
