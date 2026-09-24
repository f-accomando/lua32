--[[
test_cpu.lua - test della CPU (82 opcode: 54 base + 28 indicizzati).

Programmi scritti come byte grezzi (niente assembler ancora) - stesso
approccio del vecchio test_cpu.py. Lancia da qualunque cartella:

    luajit tests/test_cpu.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local cpu_module = require("cpu")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local function u16(v) return {v % 256, math.floor(v / 256) % 256} end
local function u24(v) return {v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256} end

local function load_prog(cpu, addr, bytes)
    for i, b in ipairs(bytes) do
        cpu.mem[addr + i - 1] = b
    end
end

local function concat(...)
    local out = {}
    for _, t in ipairs({...}) do
        for _, v in ipairs(t) do out[#out + 1] = v end
    end
    return out
end

local PROG = 0x1000

-- ---------------------------------------------------------------
-- opcode base (campione rappresentativo, non tutti e 54 - il porting
-- e' riga per riga da cpu.py, gia' verificato in quel progetto)
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    local prog = concat({0x10}, u16(1000), {0x12}, u24(0x3000), {0x11}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("LDA#/STA/LDA addr: A finale", cpu.a, 1000)
end

do
    local cpu = cpu_module.new()
    local prog = concat({0x10}, u16(500), {0x30}, u16(250), {0x01})  -- LDA #500; ADD #250
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("ADD immediata", cpu.a, 750)
end

do
    local cpu = cpu_module.new()
    -- LDA #50; CMP #50 (Z=1); CMP #30 (Z=0,N=0); CMP #80 (Z=0,N=1)
    local prog = concat({0x10}, u16(50), {0x35}, u16(50), {0x35}, u16(30), {0x35}, u16(80), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("CMP: A non modificata da CMP", cpu.a, 50)
    check("CMP: N=1 dopo confronto con valore maggiore", cpu:flag(0x02), true)
end

do
    local cpu = cpu_module.new()
    -- JSR sub; STA 0x3000; HALT | sub: LDA #777; RTS
    -- JSR(1+3) + STA(1+3) + HALT(1) = 9 byte, la subroutine parte subito dopo
    local sub = PROG + 9
    local prog = concat({0x67}, u24(sub), {0x12}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    load_prog(cpu, sub, concat({0x10}, u16(777), {0x68}))
    cpu:run(PROG)
    check("JSR/RTS: valore tornato dalla subroutine", cpu:read16(0x3000), 777)
end

do
    local cpu = cpu_module.new()
    -- LDA #11; PHA; LDA #22; PHA; PLA; PLA -> A finale = 11 (LIFO)
    local prog = concat({0x10}, u16(11), {0x70}, {0x10}, u16(22), {0x70}, {0x71}, {0x71}, {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("PHA/PLA: ordine LIFO", cpu.a, 11)
end

-- ---------------------------------------------------------------
-- NUOVO: indirizzamento indicizzato ,X e ,Y - qui serve copertura
-- vera, e' logica mai esistita prima in questo progetto
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    cpu:write16(0x3005, 999)  -- valore in base+5
    -- LDX #5; LDA 0x3000,X ; HALT
    local prog = concat({0x13}, u16(5), {0xA0}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("LDA addr,X: legge base+X", cpu.a, 999)
end

do
    local cpu = cpu_module.new()
    -- LDY #7; LDA #321; STA 0x3000,Y ; HALT
    local prog = concat({0x16}, u16(7), {0x10}, u16(321), {0xA3}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("STA addr,Y: scrive a base+Y", cpu:read16(0x3007), 321)
end

do
    local cpu = cpu_module.new()
    cpu:write16(0x3003, 42)
    -- LDX #3; LDX 0x3000,X ; HALT  (auto-riferimento: legge base+X vecchio, poi sovrascrive X)
    local prog = concat({0x13}, u16(3), {0xA4}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("LDX addr,X: nessuna restrizione artificiale sull'auto-indicizzazione", cpu.x, 42)
end

do
    local cpu = cpu_module.new()
    cpu:write16(0x3004, 100)
    -- LDX #4; LDA #25; ADD 0x3000,X ; HALT  -> A = 25+100
    local prog = concat({0x13}, u16(4), {0x10}, u16(25), {0xB0}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("ADD addr,X", cpu.a, 125)
end

do
    local cpu = cpu_module.new()
    cpu:write16(0x3002, 9)
    -- LDY #2; CMP 0x3000,Y con A=9 -> Z=1
    local prog = concat({0x16}, u16(2), {0x10}, u16(9), {0xBB}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("CMP addr,Y: Z=1 quando uguali", cpu:flag(0x01), true)
end

do
    local cpu = cpu_module.new()
    cpu:write16(0x3006, 10)
    -- LDX #6; INC 0x3000,X ; INC 0x3000,X ; HALT -> valore 12
    local prog = concat({0x13}, u16(6), {0xBC}, u24(0x3000), {0xBC}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("INC addr,X: due incrementi", cpu:read16(0x3006), 12)
end

do
    local cpu = cpu_module.new()
    cpu:write16(0x3008, 5)
    -- LDY #8; DEC 0x3000,Y ; HALT -> valore 4
    local prog = concat({0x16}, u16(8), {0xBF}, u24(0x3000), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("DEC addr,Y", cpu:read16(0x3008), 4)
end

do
    local cpu = cpu_module.new()
    -- wraparound sul bus a 24-bit: base vicino al limite + indice sfora
    local near_top = 0xFFFFFE
    cpu:write16(0, 555)  -- l'indirizzo effettivo avvolge a 0 dopo il mascheramento
    -- LDX #2; LDA 0xFFFFFE,X -> effettivo = (0xFFFFFE+2) & 0xFFFFFF = 0
    local prog = concat({0x13}, u16(2), {0xA0}, u24(near_top), {0x01})
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("LDA addr,X: wraparound a 24-bit coerente col resto della CPU", cpu.a, 555)
end

do
    local cpu = cpu_module.new()
    -- ASL/LSR invariati - un test di continuita' rapido
    local prog = concat({0x10}, u16(0x05), {0x50}, {0x01})  -- LDA #5; ASL
    load_prog(cpu, PROG, prog)
    cpu:run(PROG)
    check("ASL: shift a sinistra invariato", cpu.a, 10)
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
