--[[
test_assembler.lua - test dell'assemblatore, incluso un giro completo
etichette->byte->esecuzione vera con cpu.lua (la stessa classe di bug
che ci ha appena morso scrivendo test_cpu.lua a mano - un indirizzo di
subroutine calcolato male - qui e' impossibile per costruzione).

    luajit tests/test_assembler.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local assembler = require("assembler")
local cpu_module = require("cpu")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local CART_LOAD_ADDR = 0x1000

local function run_source(src, input_byte)
    local rom = assembler.assemble(src, CART_LOAD_ADDR)
    local cpu = cpu_module.new()
    for i, b in ipairs(rom) do
        cpu.mem[CART_LOAD_ADDR + i - 1] = b
    end
    local steps = cpu:run(CART_LOAD_ADDR, input_byte)
    return cpu, steps, rom
end

-- ---------------------------------------------------------------
-- assemblaggio base: dimensioni byte corrette
-- ---------------------------------------------------------------
do
    local rom = assembler.assemble("NOP\nHALT", 0)
    check("NOP+HALT: 2 byte totali", #rom, 2)
    check("NOP -> 0x00", rom[1], 0x00)
    check("HALT -> 0x01", rom[2], 0x01)
end

-- ---------------------------------------------------------------
-- etichette avanti e indietro, JSR/RTS - il caso che ci ha fatto
-- sbagliare i conti a mano nei test della CPU
-- ---------------------------------------------------------------
do
    local cpu = run_source([[
        JSR sub
        STA 0x3000
        HALT
    sub:
        LDA #777
        RTS
    ]])
    check("JSR/RTS con etichetta: indirizzo risolto correttamente", cpu:read16(0x3000), 777)
end

do
    -- salto ALL'INDIETRO: loop che conta da 3 a 0
    local cpu = run_source([[
        LDX #3
    loop:
        DEX
        JNZ loop
        STX 0x3000
        HALT
    ]])
    check("etichetta all'indietro (loop): valore finale", cpu:read16(0x3000), 0)
end

do
    -- salto IN AVANTI a un'etichetta non ancora vista
    local cpu = run_source([[
        LDA #0
        JZ skip
        LDA #999
    skip:
        STA 0x3000
        HALT
    ]])
    check("etichetta in avanti (salto preso)", cpu:read16(0x3000), 0)
end

-- ---------------------------------------------------------------
-- sintassi indicizzata ,X / ,Y
-- ---------------------------------------------------------------
do
    local cpu = run_source([[
        LDX #5
        LDA #42
        STA 0x3000,X
        LDA 0x3000,X
        HALT
    ]])
    check("STA/LDA addr,X: round-trip attraverso l'assemblatore", cpu.a, 42)
end

do
    local cpu = run_source([[
        LDY #4
        LDA #10
        ADD 0x3000,Y
        HALT
    ]])
    check("ADD addr,Y: opcode indicizzato assemblato correttamente", cpu.a, 10)
end

-- ---------------------------------------------------------------
-- errore su istruzione sconosciuta
-- ---------------------------------------------------------------
do
    local ok, err = pcall(function() assembler.assemble("PIPPO #1", 0) end)
    check("istruzione sconosciuta: solleva un errore", ok, false)
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
