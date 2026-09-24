--[[
assembler.lua - assemblatore per cpu.lua. Stessa filosofia del vecchio
assembler.py: testo leggibile (un'istruzione per riga, "NOME arg",
";" per i commenti, "ETICHETTA:" per le etichette), due passaggi
(prima le etichette, poi i byte veri).

NUOVO rispetto al vecchio assembler.py: sintassi indicizzata ",X"/",Y"
per le istruzioni che la supportano (vedi cpu.lua, opcode 0xA0-0xBF) -
es. "LDA 0x2000,X" invece di dover calcolare un indirizzo a mano.
]]
local M = {}

local MNEMONIC_TABLE = {
    -- mnemonico interno: {opcode, modalita' ('none'|'imm16'|'addr24'|'clamp')}
    NOP =  {0x00, "none"},
    HALT = {0x01, "none"},

    LDA_IMM = {0x10, "imm16"}, LDA_ADDR = {0x11, "addr24"},
    STA =     {0x12, "addr24"},
    LDX_IMM = {0x13, "imm16"}, LDX_ADDR = {0x14, "addr24"},
    STX =     {0x15, "addr24"},
    LDY_IMM = {0x16, "imm16"}, LDY_ADDR = {0x17, "addr24"},
    STY =     {0x18, "addr24"},

    TAX = {0x20, "none"}, TXA = {0x21, "none"},
    TAY = {0x22, "none"}, TYA = {0x23, "none"},
    TXY = {0x24, "none"}, TYX = {0x25, "none"},

    ADD_IMM = {0x30, "imm16"}, SUB_IMM = {0x31, "imm16"},
    AND_IMM = {0x32, "imm16"}, OR_IMM  = {0x33, "imm16"},
    XOR_IMM = {0x34, "imm16"}, CMP_IMM = {0x35, "imm16"},

    ADD_ADDR = {0x40, "addr24"}, SUB_ADDR = {0x41, "addr24"},
    AND_ADDR = {0x42, "addr24"}, OR_ADDR  = {0x43, "addr24"},
    XOR_ADDR = {0x44, "addr24"}, CMP_ADDR = {0x45, "addr24"},

    ASL = {0x50, "none"}, LSR = {0x51, "none"},
    INC = {0x52, "addr24"}, DEC = {0x53, "addr24"},
    INX = {0x54, "none"}, INY = {0x55, "none"},
    DEX = {0x56, "none"}, DEY = {0x57, "none"},

    JMP = {0x60, "addr24"}, JZ  = {0x61, "addr24"},
    JNZ = {0x62, "addr24"}, JLT = {0x63, "addr24"},
    JGE = {0x64, "addr24"}, JCS = {0x65, "addr24"},
    JCC = {0x66, "addr24"}, JSR = {0x67, "addr24"},
    RTS = {0x68, "none"},

    PHA = {0x70, "none"}, PLA = {0x71, "none"},
    PHX = {0x72, "none"}, PLX = {0x73, "none"},
    PHY = {0x74, "none"}, PLY = {0x75, "none"},

    IN = {0x80, "none"},

    CLAMPX = {0x90, "clamp"}, CLAMPY = {0x91, "clamp"},

    -- indicizzati ,X/,Y - vedi cpu.lua per la stessa numerazione
    LDA_ADDR_X = {0xA0, "addr24"}, LDA_ADDR_Y = {0xA1, "addr24"},
    STA_ADDR_X = {0xA2, "addr24"}, STA_ADDR_Y = {0xA3, "addr24"},
    LDX_ADDR_X = {0xA4, "addr24"}, LDX_ADDR_Y = {0xA5, "addr24"},
    STX_ADDR_X = {0xA6, "addr24"}, STX_ADDR_Y = {0xA7, "addr24"},
    LDY_ADDR_X = {0xA8, "addr24"}, LDY_ADDR_Y = {0xA9, "addr24"},
    STY_ADDR_X = {0xAA, "addr24"}, STY_ADDR_Y = {0xAB, "addr24"},

    ADD_ADDR_X = {0xB0, "addr24"}, ADD_ADDR_Y = {0xB1, "addr24"},
    SUB_ADDR_X = {0xB2, "addr24"}, SUB_ADDR_Y = {0xB3, "addr24"},
    AND_ADDR_X = {0xB4, "addr24"}, AND_ADDR_Y = {0xB5, "addr24"},
    OR_ADDR_X  = {0xB6, "addr24"}, OR_ADDR_Y  = {0xB7, "addr24"},
    XOR_ADDR_X = {0xB8, "addr24"}, XOR_ADDR_Y = {0xB9, "addr24"},
    CMP_ADDR_X = {0xBA, "addr24"}, CMP_ADDR_Y = {0xBB, "addr24"},
    INC_ADDR_X = {0xBC, "addr24"}, INC_ADDR_Y = {0xBD, "addr24"},
    DEC_ADDR_X = {0xBE, "addr24"}, DEC_ADDR_Y = {0xBF, "addr24"},
}

local SIZE_BY_MODE = {none = 1, imm16 = 3, addr24 = 4, clamp = 5}

-- mnemonici con anche una forma immediata (arg che inizia con "#")
local HAS_IMMEDIATE = {LDA = true, LDX = true, LDY = true, ADD = true,
                        SUB = true, AND = true, OR = true, XOR = true, CMP = true}
-- mnemonici che supportano ANCHE l'indicizzazione ,X/,Y (in aggiunta
-- alla forma indirizzo assoluto semplice)
local INDEXABLE = {LDA = true, STA = true, LDX = true, STX = true,
                    LDY = true, STY = true, ADD = true, SUB = true,
                    AND = true, OR = true, XOR = true, CMP = true,
                    INC = true, DEC = true}

local AssemblerError = {}
AssemblerError.__index = AssemblerError
AssemblerError.__tostring = function(self) return self.message end
local function assembler_error(msg)
    error(setmetatable({message = msg}, AssemblerError))
end
M.AssemblerError = AssemblerError

-- Risolve "LDA"/arg nel nome interno giusto nella MNEMONIC_TABLE:
-- "#..." -> immediata, "...,X"/"...,Y" -> indicizzata, altrimenti
-- indirizzo assoluto semplice (bare per gli op che non hanno mai
-- avuto un suffisso _ADDR, es. STA/INC).
local function resolve_mnemonic(op, arg)
    if HAS_IMMEDIATE[op] and arg:sub(1, 1) == "#" then
        return op .. "_IMM"
    end
    if INDEXABLE[op] then
        local suffix = arg:sub(-2):upper()
        if suffix == ",X" then return op .. "_ADDR_X" end
        if suffix == ",Y" then return op .. "_ADDR_Y" end
        if HAS_IMMEDIATE[op] then return op .. "_ADDR" end
        return op  -- STA/STX/STY/INC/DEC: la forma indirizzo semplice non ha suffisso
    end
    return op
end

local function parse_lines(src)
    local lines = {}
    for raw in (src .. "\n"):gmatch("(.-)\n") do
        local line = raw:gsub(";.*$", ""):match("^%s*(.-)%s*$")
        if line ~= "" then lines[#lines + 1] = line end
    end
    return lines
end

local function first_pass(lines, base_addr)
    local labels = {}
    local addr = base_addr
    local parsed = {}
    for _, line in ipairs(lines) do
        local label = line:match("^(.+):$")
        if label then
            if labels[label] then
                assembler_error(string.format('Etichetta duplicata: "%s"', label))
            end
            labels[label] = addr
        else
            local op, arg = line:match("^(%S+)%s+(.-)%s*$")
            if not op then
                op, arg = line:match("^(%S+)$"), ""
            end
            local internal = resolve_mnemonic(op, arg or "")
            local entry = MNEMONIC_TABLE[internal]
            if not entry then
                assembler_error(string.format('Istruzione sconosciuta: "%s"', op))
            end
            local opcode, mode = entry[1], entry[2]
            local size = SIZE_BY_MODE[mode]
            parsed[#parsed + 1] = {internal, opcode, mode, arg, addr}
            addr = addr + size
        end
    end
    return parsed, labels
end

-- toglie un eventuale suffisso ",X"/",Y" dall'argomento prima di
-- interpretarlo come numero/etichetta (la modalita' e' gia' stata
-- decisa in resolve_mnemonic, qui serve solo il valore indirizzo)
local function strip_index_suffix(arg)
    local suffix = arg:sub(-2):upper()
    if suffix == ",X" or suffix == ",Y" then
        return arg:sub(1, -3)
    end
    return arg
end

local function emit_operand(mode, arg, labels)
    if mode == "none" then
        return {}
    end
    if mode == "imm16" then
        if arg:sub(1, 1) ~= "#" then
            assembler_error(string.format('Operando immediato atteso (con "#"): "%s"', arg))
        end
        local val = tonumber(arg:sub(2)) % 65536
        return {val % 256, math.floor(val / 256) % 256}
    end
    if mode == "addr24" then
        local clean = strip_index_suffix(arg)
        local val = labels[clean]
        if val == nil then val = tonumber(clean) end
        if val == nil then
            assembler_error(string.format('Etichetta o numero non valido: "%s"', arg))
        end
        val = val % 16777216
        return {val % 256, math.floor(val / 256) % 256, math.floor(val / 65536) % 256}
    end
    if mode == "clamp" then
        local lo_str, hi_str = arg:match("^(.-)%s*,%s*(.-)$")
        local lo = tonumber(lo_str) % 65536
        local hi = tonumber(hi_str) % 65536
        return {lo % 256, math.floor(lo / 256) % 256, hi % 256, math.floor(hi / 256) % 256}
    end
    assembler_error("Modalita' sconosciuta: " .. tostring(mode))
end

-- assemble(src, base_addr) -> array di byte (1-indicizzato, Lua style)
function M.assemble(src, base_addr)
    base_addr = base_addr or 0
    local lines = parse_lines(src)
    local parsed, labels = first_pass(lines, base_addr)
    local out = {}
    for _, instr in ipairs(parsed) do
        local internal, opcode, mode, arg = instr[1], instr[2], instr[3], instr[4]
        out[#out + 1] = opcode
        for _, b in ipairs(emit_operand(mode, arg, labels)) do
            out[#out + 1] = b
        end
    end
    return out
end

return M
