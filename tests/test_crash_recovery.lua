--[[
test_crash_recovery.lua - verifica che una cartuccia REALMENTE rotta
(opcode sconosciuto, 0xFF non e' definito in cpu.lua - vedi l'ultimo
opcode assegnato, 0xBF) faccia fallire cpu:run() con un errore Lua
catturabile via pcall, esattamente lo scenario che main.lua intercetta
per tornare al picker invece di far chiudere tutto s32 (vedi il commento
sul pcall nel tick loop). Copre anche il fix collegato: dopo il crash,
Session:on_closed() deve sgomberare "paused" anche se la cartuccia era
stata ripresa da una pausa precedente (altrimenti il picker offrirebbe
"resume" su una cartuccia che non esiste piu').

    luajit tests/test_crash_recovery.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local cart = require("cart")
local cpu_module = require("cpu")
local os_mod = require("s32_os")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

-- ---------------------------------------------------------------
-- 1) una cartuccia vera con un opcode inesistente fa fallire cpu:run()
-- ---------------------------------------------------------------
local tmp_path = os.tmpname()
cart.pack({
    meta = cart.new_meta("Cartuccia rotta", "test"),
    code = string.char(0xFF),  -- 0xFF non e' assegnato in cpu.lua (l'ultimo e' 0xBF)
}, tmp_path)

local loaded = cart.load(tmp_path)
local cpu = cpu_module.new()
local load_addr = cart.install(cpu, loaded, 0x1000)

local ok, err = pcall(function() cpu:run(load_addr, 0) end)
check("cpu:run() con opcode sconosciuto fallisce", ok, false)
check("l'errore menziona l'opcode sconosciuto", tostring(err):find("sconosciuto") ~= nil, true)

os.remove(tmp_path)

-- ---------------------------------------------------------------
-- 2) stesso pattern usato in main.lua: pcall attorno al tick, poi
-- session:on_closed() - la cartuccia non deve piu' risultare "in pausa"
-- anche se lo era (caso: pausa, ripresa, POI crash - vedi la
-- conversazione, e' esattamente il caso che aveva rotto la vecchia
-- logica prima di aggiungere on_closed())
-- ---------------------------------------------------------------
local entries = { { name = "rotta", kind = "play" } }
local session = os_mod.new_session()
session:confirm(entries)               -- lancio diretto
session:on_paused(entries[1])          -- ESC: pausa
session:confirm(entries)               -- riseleziona: action=resume (ripresa "dal vivo")

-- ...e ORA va in crash mentre gira di nuovo:
local crash_ok = pcall(function() error("Opcode sconosciuto: 0xFF a pc=0x001000") end)
check("simulazione crash: pcall lo cattura", crash_ok, false)
session:on_closed()
check("dopo il crash: nessuna cartuccia risulta piu' in pausa", session.paused, nil)
local next_action = session:confirm(entries)
check("dopo il crash: riselezionarla la rilancia da capo", next_action.action, "launch")

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
