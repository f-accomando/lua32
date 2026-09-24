--[[
test_demo_program.lua - verifica la LOGICA del programma demo di
main.lua (movimento/clamp dello sprite) senza aprire una finestra vera
- main.lua espone setup_demo_assets/build_demo_program come modulo
quando richiesto (invece che lanciato direttamente), vedi in fondo a
quel file.

    luajit tests/test_demo_program.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local cpu_module = require("cpu")
local mm = require("memory_map")
local demo = require("main")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local function new_cpu_with_demo()
    local cpu = cpu_module.new()
    local oam_base = demo.setup_demo_assets(cpu)
    local rom = demo.build_demo_program(oam_base)
    for i, b in ipairs(rom) do cpu.mem[demo.CART_LOAD_ADDR + i - 1] = b end
    return cpu, oam_base
end

local function oam_x(cpu, oam_base) return cpu:read16(oam_base) end
local function oam_y(cpu, oam_base) return cpu:read16(oam_base + 2) end

-- ---------------------------------------------------------------
-- primo frame: posizione iniziale (150,100) scritta in OAM
-- ---------------------------------------------------------------
do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    check("posizione iniziale X in OAM", oam_x(cpu, oam_base), 150)
    check("posizione iniziale Y in OAM", oam_y(cpu, oam_base), 100)
end

-- ---------------------------------------------------------------
-- movimento: destra (bit3=0x08) sposta X di +2 a frame
-- ---------------------------------------------------------------
do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)  -- inizializza
    cpu:run(demo.CART_LOAD_ADDR, 0x08)
    check("destra: X aumenta di 2", oam_x(cpu, oam_base), 152)
    cpu:run(demo.CART_LOAD_ADDR, 0x08)
    check("destra: X continua ad aumentare", oam_x(cpu, oam_base), 154)
end

do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    cpu:run(demo.CART_LOAD_ADDR, 0x01)  -- su
    check("su: Y diminuisce di 2", oam_y(cpu, oam_base), 98)
end

do
    -- su+destra insieme (bit0 | bit3)
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    cpu:run(demo.CART_LOAD_ADDR, 0x09)
    check("su+destra insieme: X aumenta", oam_x(cpu, oam_base), 152)
    check("su+destra insieme: Y diminuisce", oam_y(cpu, oam_base), 98)
end

-- ---------------------------------------------------------------
-- clamp ai bordi: spingendo a destra molte volte non deve mai
-- superare SCREEN_W - 16 (dimensione dello sprite)
-- ---------------------------------------------------------------
do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    for _ = 1, 200 do
        cpu:run(demo.CART_LOAD_ADDR, 0x08)  -- destra
    end
    check("clamp destro: X non supera SCREEN_W-16", oam_x(cpu, oam_base), demo.SCREEN_W - 16)
end

do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    for _ = 1, 200 do
        cpu:run(demo.CART_LOAD_ADDR, 0x01)  -- su
    end
    check("clamp superiore: Y non scende sotto 0", oam_y(cpu, oam_base), 0)
end

do
    local cpu, oam_base = new_cpu_with_demo()
    cpu:run(demo.CART_LOAD_ADDR, 0)
    for _ = 1, 200 do
        cpu:run(demo.CART_LOAD_ADDR, 0x04)  -- sinistra
    end
    check("clamp sinistro: X non scende sotto 0 (stesso bug di underflow, corretto anche qui)",
          oam_x(cpu, oam_base), 0)
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
