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

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
