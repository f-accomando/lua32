--[[
cpu.lua - nucleo CPU di s32. LuaJIT, 83 opcode (55 base + 28
indicizzati ,X/,Y aggiunti nel redesign - vedi docs/design.md "CPU").

Stessa filosofia del vecchio motore Python: registri A/X/Y a 16-bit,
bus a 24-bit flat senza banking, registro FLAG vero (Z/N/C/V), stack
hardware in cima alla WRAM. La CPU non disegna pixel ne' produce
audio - scrive solo in memoria/porte, il resto (PPU/APU) legge da li'
(stesso pattern DMA-like del vecchio motore).

Indirizzamento indicizzato (,X / ,Y): aggiunto perche' senza di esso
accedere a un array (slot OAM, righe di tilemap) richiede costruire
l'indirizzo a mano ogni volta. Sia X che Y indicizzano qualunque
istruzione indirizzo, senza le asimmetrie del 6502 vero (limiti di
silicio anni '80, non hanno motivo di esistere qui).
]]
local ffi = require("ffi")
local bit = require("bit")
local mm = require("memory_map")

local M = {}

local ADDRESS_MASK = mm.ADDRESS_MASK
local WRAM_BASE = mm.WRAM_BASE
local WRAM_END = mm.WRAM_END
local VRAM_BASE = mm.VRAM_BASE
local TILEMAP_VRAM_OFFSET = mm.TILEMAP_VRAM_OFFSET
local TILEMAP_BYTES = mm.TILEMAP_BYTES
local DIRECTORY_VRAM_OFFSET = mm.DIRECTORY_VRAM_OFFSET
local GFX_BANK_BYTES = mm.DIRECTORY_BYTES + mm.GRAPHICS_POOL_BYTES

local FLAG_ZERO = mm.FLAG_ZERO
local FLAG_NEGATIVE = mm.FLAG_NEGATIVE
local FLAG_CARRY = mm.FLAG_CARRY
local FLAG_OVERFLOW = mm.FLAG_OVERFLOW

local PORT_INPUT = mm.PORT_INPUT
local PORT_STAGE_SELECT = mm.PORT_STAGE_SELECT
local PORT_SCROLL_X = mm.PORT_SCROLL_X
local PORT_SCROLL_Y = mm.PORT_SCROLL_Y
local PORT_SOUND = mm.PORT_SOUND
local PORT_GFX_BANK_SELECT = mm.PORT_GFX_BANK_SELECT

local IS_INPUT_PORT = {[PORT_INPUT] = true}
for _, p in ipairs(mm.EXTRA_INPUT_PORTS) do IS_INPUT_PORT[p] = true end

-- ---------------------------------------------------------------
-- CPU
-- ---------------------------------------------------------------
local CPU = {}
CPU.__index = CPU
M.CPU = CPU

function M.new()
    local self = setmetatable({}, CPU)
    self.mem = ffi.new("uint8_t[?]", mm.ADDRESS_SPACE)
    self.a, self.x, self.y, self.pc, self.flags = 0, 0, 0, 0, 0
    self.sp = WRAM_END - 2  -- stack hardware, cresce verso il basso
    self.stages = {}        -- popolato dall'host prima di avviare il
                              -- ciclo di gioco - vedi PORT_STAGE_SELECT
    self.current_stage = 0
    self.gfx_banks = {}     -- popolato dall'host - vedi PORT_GFX_BANK_SELECT
    self.current_gfx_bank = 0
    self.scroll_x, self.scroll_y = 0, 0
    self.sound_queue = {}   -- ID suoni richiesti in questo frame - il
                              -- motore la svuota dopo ogni run()
    return self
end

-- -----------------------------------------------------------
-- accesso memoria a 16-bit (little-endian su 2 byte)
-- -----------------------------------------------------------
function CPU:read16(addr)
    addr = bit.band(addr, ADDRESS_MASK)
    local lo = self.mem[addr]
    local hi = self.mem[bit.band(addr + 1, ADDRESS_MASK)]
    return bit.bor(lo, bit.lshift(hi, 8))
end

function CPU:write16(addr, value)
    addr = bit.band(addr, ADDRESS_MASK)
    value = bit.band(value, 0xffff)
    if addr == PORT_STAGE_SELECT then
        local data = self.stages[value]
        if data ~= nil then
            ffi.copy(self.mem + VRAM_BASE + TILEMAP_VRAM_OFFSET, data, TILEMAP_BYTES)
            self.current_stage = value
        end
        return
    end
    if addr == PORT_GFX_BANK_SELECT then
        local data = self.gfx_banks[value]
        if data ~= nil then
            ffi.copy(self.mem + VRAM_BASE + DIRECTORY_VRAM_OFFSET, data, GFX_BANK_BYTES)
            self.current_gfx_bank = value
        end
        return
    end
    if addr == PORT_SCROLL_X then self.scroll_x = value; return end
    if addr == PORT_SCROLL_Y then self.scroll_y = value; return end
    if addr == PORT_SOUND then self.sound_queue[#self.sound_queue + 1] = value; return end
    self.mem[addr] = bit.band(value, 0xff)
    self.mem[bit.band(addr + 1, ADDRESS_MASK)] = bit.band(bit.rshift(value, 8), 0xff)
end

function CPU:read_mem(addr)
    if IS_INPUT_PORT[addr] then
        return self.mem[addr]
    end
    return self:read16(addr)
end

function CPU:write_mem(addr, value)
    self:write16(addr, value)
end

-- -----------------------------------------------------------
-- flag
-- -----------------------------------------------------------
function CPU:set_flag(flag_bit, condition)
    if condition then
        self.flags = bit.bor(self.flags, flag_bit)
    else
        self.flags = bit.band(self.flags, bit.bnot(flag_bit))
    end
end

function CPU:update_zn(value)
    self:set_flag(FLAG_ZERO, value == 0)
    self:set_flag(FLAG_NEGATIVE, bit.band(value, 0x8000) ~= 0)
end

function CPU:flag(f)
    return bit.band(self.flags, f) ~= 0
end

-- -----------------------------------------------------------
-- stack (16 bit per valore)
-- -----------------------------------------------------------
function CPU:push(value)
    self:write16(self.sp, value)
    self.sp = self.sp - 2
    if self.sp < WRAM_BASE then
        error("Stack overflow (sceso sotto WRAM_BASE)")
    end
end

function CPU:pop()
    self.sp = self.sp + 2
    if self.sp > WRAM_END - 2 then
        error("Stack underflow (nessun valore da togliere)")
    end
    return self:read16(self.sp)
end

-- -----------------------------------------------------------
-- ALU
-- -----------------------------------------------------------
function CPU:_add(operand)
    local raw = self.a + operand
    self:set_flag(FLAG_CARRY, raw > 0xffff)
    local result = bit.band(raw, 0xffff)
    local a_sign, op_sign, r_sign = bit.band(self.a, 0x8000), bit.band(operand, 0x8000), bit.band(result, 0x8000)
    self:set_flag(FLAG_OVERFLOW, (a_sign == op_sign) and (r_sign ~= a_sign))
    self:update_zn(result)
    self.a = result
end

function CPU:_sub(operand)
    local raw = self.a - operand
    self:set_flag(FLAG_CARRY, self.a >= operand)
    local result = bit.band(raw, 0xffff)
    local a_sign, op_sign, r_sign = bit.band(self.a, 0x8000), bit.band(operand, 0x8000), bit.band(result, 0x8000)
    self:set_flag(FLAG_OVERFLOW, (a_sign ~= op_sign) and (r_sign ~= a_sign))
    self:update_zn(result)
    self.a = result
end

function CPU:_and(operand) self.a = bit.band(self.a, operand); self:update_zn(self.a) end
function CPU:_or(operand) self.a = bit.bor(self.a, operand); self:update_zn(self.a) end
function CPU:_xor(operand) self.a = bit.bxor(self.a, operand); self:update_zn(self.a) end

function CPU:_cmp(operand)
    local result = bit.band(self.a - operand, 0xffff)
    self:set_flag(FLAG_CARRY, self.a >= operand)
    self:update_zn(result)
end

-- -----------------------------------------------------------
-- helper di lettura operandi
-- -----------------------------------------------------------
function CPU:_imm16()
    return bit.bor(self.mem[self.pc + 1], bit.lshift(self.mem[self.pc + 2], 8))
end

function CPU:_addr24()
    return bit.bor(self.mem[self.pc + 1], bit.lshift(self.mem[self.pc + 2], 8), bit.lshift(self.mem[self.pc + 3], 16))
end

-- indirizzo effettivo per le nuove modalita' indicizzate: addr24()
-- dell'istruzione + il registro scelto, mascherato sul bus a 24-bit
-- (stesso wraparound usato ovunque nella CPU)
function CPU:_addr24_x() return bit.band(self:_addr24() + self.x, ADDRESS_MASK) end
function CPU:_addr24_y() return bit.band(self:_addr24() + self.y, ADDRESS_MASK) end

-- -----------------------------------------------------------
-- opcode - tabella condivisa fra tutte le istanze
-- -----------------------------------------------------------
local OPCODES = {}
M.OPCODES = OPCODES

-- --- controllo (0x00-0x01) ---
OPCODES[0x00] = function(c) c.pc = c.pc + 1; return true end  -- NOP
OPCODES[0x01] = function(c) return false end  -- HALT

-- --- LD/ST immediata + indirizzo assoluto (0x10-0x18) ---
OPCODES[0x10] = function(c) c.a = c:_imm16(); c:update_zn(c.a); c.pc = c.pc + 3; return true end  -- LDA #imm
OPCODES[0x11] = function(c) c.a = c:read_mem(c:_addr24()); c:update_zn(c.a); c.pc = c.pc + 4; return true end  -- LDA addr
OPCODES[0x12] = function(c) c:write_mem(c:_addr24(), c.a); c.pc = c.pc + 4; return true end  -- STA addr
OPCODES[0x13] = function(c) c.x = c:_imm16(); c:update_zn(c.x); c.pc = c.pc + 3; return true end  -- LDX #imm
OPCODES[0x14] = function(c) c.x = c:read_mem(c:_addr24()); c:update_zn(c.x); c.pc = c.pc + 4; return true end  -- LDX addr
OPCODES[0x15] = function(c) c:write_mem(c:_addr24(), c.x); c.pc = c.pc + 4; return true end  -- STX addr
OPCODES[0x16] = function(c) c.y = c:_imm16(); c:update_zn(c.y); c.pc = c.pc + 3; return true end  -- LDY #imm
OPCODES[0x17] = function(c) c.y = c:read_mem(c:_addr24()); c:update_zn(c.y); c.pc = c.pc + 4; return true end  -- LDY addr
OPCODES[0x18] = function(c) c:write_mem(c:_addr24(), c.y); c.pc = c.pc + 4; return true end  -- STY addr

-- --- transfer fra registri (0x20-0x25) ---
OPCODES[0x20] = function(c) c.x = c.a; c:update_zn(c.x); c.pc = c.pc + 1; return true end  -- TAX
OPCODES[0x21] = function(c) c.a = c.x; c:update_zn(c.a); c.pc = c.pc + 1; return true end  -- TXA
OPCODES[0x22] = function(c) c.y = c.a; c:update_zn(c.y); c.pc = c.pc + 1; return true end  -- TAY
OPCODES[0x23] = function(c) c.a = c.y; c:update_zn(c.a); c.pc = c.pc + 1; return true end  -- TYA
OPCODES[0x24] = function(c) c.y = c.x; c:update_zn(c.y); c.pc = c.pc + 1; return true end  -- TXY
OPCODES[0x25] = function(c) c.x = c.y; c:update_zn(c.x); c.pc = c.pc + 1; return true end  -- TYX

-- --- ALU immediata (0x30-0x35) ---
OPCODES[0x30] = function(c) c:_add(c:_imm16()); c.pc = c.pc + 3; return true end  -- ADD #imm
OPCODES[0x31] = function(c) c:_sub(c:_imm16()); c.pc = c.pc + 3; return true end  -- SUB #imm
OPCODES[0x32] = function(c) c:_and(c:_imm16()); c.pc = c.pc + 3; return true end  -- AND #imm
OPCODES[0x33] = function(c) c:_or(c:_imm16()); c.pc = c.pc + 3; return true end   -- OR  #imm
OPCODES[0x34] = function(c) c:_xor(c:_imm16()); c.pc = c.pc + 3; return true end  -- XOR #imm
OPCODES[0x35] = function(c) c:_cmp(c:_imm16()); c.pc = c.pc + 3; return true end  -- CMP #imm

-- --- ALU indirizzo assoluto (0x40-0x45) ---
OPCODES[0x40] = function(c) c:_add(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end  -- ADD addr
OPCODES[0x41] = function(c) c:_sub(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end  -- SUB addr
OPCODES[0x42] = function(c) c:_and(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end  -- AND addr
OPCODES[0x43] = function(c) c:_or(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end   -- OR  addr
OPCODES[0x44] = function(c) c:_xor(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end  -- XOR addr
OPCODES[0x45] = function(c) c:_cmp(c:read_mem(c:_addr24())); c.pc = c.pc + 4; return true end  -- CMP addr

-- --- shift/inc/dec (0x50-0x57) ---
OPCODES[0x50] = function(c)  -- ASL
    local carry_out = bit.band(c.a, 0x8000) ~= 0
    c.a = bit.band(bit.lshift(c.a, 1), 0xffff)
    c:set_flag(FLAG_CARRY, carry_out); c:update_zn(c.a); c.pc = c.pc + 1; return true
end
OPCODES[0x51] = function(c)  -- LSR
    local carry_out = bit.band(c.a, 0x0001) ~= 0
    c.a = bit.rshift(c.a, 1)
    c:set_flag(FLAG_CARRY, carry_out); c:update_zn(c.a); c.pc = c.pc + 1; return true
end
OPCODES[0x52] = function(c)  -- INC addr
    local addr = c:_addr24(); local v = bit.band(c:read_mem(addr) + 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end
OPCODES[0x53] = function(c)  -- DEC addr
    local addr = c:_addr24(); local v = bit.band(c:read_mem(addr) - 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end
OPCODES[0x54] = function(c) c.x = bit.band(c.x + 1, 0xffff); c:update_zn(c.x); c.pc = c.pc + 1; return true end  -- INX
OPCODES[0x55] = function(c) c.y = bit.band(c.y + 1, 0xffff); c:update_zn(c.y); c.pc = c.pc + 1; return true end  -- INY
OPCODES[0x56] = function(c) c.x = bit.band(c.x - 1, 0xffff); c:update_zn(c.x); c.pc = c.pc + 1; return true end  -- DEX
OPCODES[0x57] = function(c) c.y = bit.band(c.y - 1, 0xffff); c:update_zn(c.y); c.pc = c.pc + 1; return true end  -- DEY

-- --- salti/JSR/RTS (0x60-0x68) ---
OPCODES[0x60] = function(c) c.pc = c:_addr24(); return true end  -- JMP
OPCODES[0x61] = function(c) c.pc = c:flag(FLAG_ZERO) and c:_addr24() or c.pc + 4; return true end  -- JZ
OPCODES[0x62] = function(c) c.pc = (not c:flag(FLAG_ZERO)) and c:_addr24() or c.pc + 4; return true end  -- JNZ
OPCODES[0x63] = function(c) c.pc = c:flag(FLAG_NEGATIVE) and c:_addr24() or c.pc + 4; return true end  -- JLT
OPCODES[0x64] = function(c) c.pc = (not c:flag(FLAG_NEGATIVE)) and c:_addr24() or c.pc + 4; return true end  -- JGE
OPCODES[0x65] = function(c) c.pc = c:flag(FLAG_CARRY) and c:_addr24() or c.pc + 4; return true end  -- JCS
OPCODES[0x66] = function(c) c.pc = (not c:flag(FLAG_CARRY)) and c:_addr24() or c.pc + 4; return true end  -- JCC
OPCODES[0x67] = function(c)  -- JSR
    local target = c:_addr24()
    c:push(c.pc + 4)
    c.pc = target
    return true
end
OPCODES[0x68] = function(c) c.pc = c:pop(); return true end  -- RTS

-- --- stack PHA/PLA/PHX/PLX/PHY/PLY (0x70-0x75) ---
OPCODES[0x70] = function(c) c:push(c.a); c.pc = c.pc + 1; return true end  -- PHA
OPCODES[0x71] = function(c) c.a = c:pop(); c:update_zn(c.a); c.pc = c.pc + 1; return true end  -- PLA
OPCODES[0x72] = function(c) c:push(c.x); c.pc = c.pc + 1; return true end  -- PHX
OPCODES[0x73] = function(c) c.x = c:pop(); c:update_zn(c.x); c.pc = c.pc + 1; return true end  -- PLX
OPCODES[0x74] = function(c) c:push(c.y); c.pc = c.pc + 1; return true end  -- PHY
OPCODES[0x75] = function(c) c.y = c:pop(); c:update_zn(c.y); c.pc = c.pc + 1; return true end  -- PLY

-- --- input (0x80) ---
OPCODES[0x80] = function(c) c.a = c.mem[PORT_INPUT]; c.pc = c.pc + 1; return true end  -- IN

-- --- clamp (0x90-0x91) ---
OPCODES[0x90] = function(c)  -- CLAMPX lo,hi
    local lo = c:_imm16(); local hi = bit.bor(c.mem[c.pc + 3], bit.lshift(c.mem[c.pc + 4], 8))
    if c.x < lo then c.x = lo end
    if c.x > hi then c.x = hi end
    c.pc = c.pc + 5; return true
end
OPCODES[0x91] = function(c)  -- CLAMPY lo,hi
    local lo = c:_imm16(); local hi = bit.bor(c.mem[c.pc + 3], bit.lshift(c.mem[c.pc + 4], 8))
    if c.y < lo then c.y = lo end
    if c.y > hi then c.y = hi end
    c.pc = c.pc + 5; return true
end

-- --- NUOVO: LD/ST indicizzati ,X e ,Y (0xA0-0xAB) - 12 opcode ---
OPCODES[0xA0] = function(c) c.a = c:read_mem(c:_addr24_x()); c:update_zn(c.a); c.pc = c.pc + 4; return true end  -- LDA addr,X
OPCODES[0xA1] = function(c) c.a = c:read_mem(c:_addr24_y()); c:update_zn(c.a); c.pc = c.pc + 4; return true end  -- LDA addr,Y
OPCODES[0xA2] = function(c) c:write_mem(c:_addr24_x(), c.a); c.pc = c.pc + 4; return true end  -- STA addr,X
OPCODES[0xA3] = function(c) c:write_mem(c:_addr24_y(), c.a); c.pc = c.pc + 4; return true end  -- STA addr,Y
OPCODES[0xA4] = function(c) c.x = c:read_mem(c:_addr24_x()); c:update_zn(c.x); c.pc = c.pc + 4; return true end  -- LDX addr,X
OPCODES[0xA5] = function(c) c.x = c:read_mem(c:_addr24_y()); c:update_zn(c.x); c.pc = c.pc + 4; return true end  -- LDX addr,Y
OPCODES[0xA6] = function(c) c:write_mem(c:_addr24_x(), c.x); c.pc = c.pc + 4; return true end  -- STX addr,X
OPCODES[0xA7] = function(c) c:write_mem(c:_addr24_y(), c.x); c.pc = c.pc + 4; return true end  -- STX addr,Y
OPCODES[0xA8] = function(c) c.y = c:read_mem(c:_addr24_x()); c:update_zn(c.y); c.pc = c.pc + 4; return true end  -- LDY addr,X
OPCODES[0xA9] = function(c) c.y = c:read_mem(c:_addr24_y()); c:update_zn(c.y); c.pc = c.pc + 4; return true end  -- LDY addr,Y
OPCODES[0xAA] = function(c) c:write_mem(c:_addr24_x(), c.y); c.pc = c.pc + 4; return true end  -- STY addr,X
OPCODES[0xAB] = function(c) c:write_mem(c:_addr24_y(), c.y); c.pc = c.pc + 4; return true end  -- STY addr,Y

-- --- NUOVO: ALU/INC/DEC indicizzati ,X e ,Y (0xB0-0xBF) - 16 opcode ---
OPCODES[0xB0] = function(c) c:_add(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end  -- ADD addr,X
OPCODES[0xB1] = function(c) c:_add(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end  -- ADD addr,Y
OPCODES[0xB2] = function(c) c:_sub(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end  -- SUB addr,X
OPCODES[0xB3] = function(c) c:_sub(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end  -- SUB addr,Y
OPCODES[0xB4] = function(c) c:_and(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end  -- AND addr,X
OPCODES[0xB5] = function(c) c:_and(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end  -- AND addr,Y
OPCODES[0xB6] = function(c) c:_or(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end   -- OR  addr,X
OPCODES[0xB7] = function(c) c:_or(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end   -- OR  addr,Y
OPCODES[0xB8] = function(c) c:_xor(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end  -- XOR addr,X
OPCODES[0xB9] = function(c) c:_xor(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end  -- XOR addr,Y
OPCODES[0xBA] = function(c) c:_cmp(c:read_mem(c:_addr24_x())); c.pc = c.pc + 4; return true end  -- CMP addr,X
OPCODES[0xBB] = function(c) c:_cmp(c:read_mem(c:_addr24_y())); c.pc = c.pc + 4; return true end  -- CMP addr,Y
OPCODES[0xBC] = function(c)  -- INC addr,X
    local addr = c:_addr24_x(); local v = bit.band(c:read_mem(addr) + 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end
OPCODES[0xBD] = function(c)  -- INC addr,Y
    local addr = c:_addr24_y(); local v = bit.band(c:read_mem(addr) + 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end
OPCODES[0xBE] = function(c)  -- DEC addr,X
    local addr = c:_addr24_x(); local v = bit.band(c:read_mem(addr) - 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end
OPCODES[0xBF] = function(c)  -- DEC addr,Y
    local addr = c:_addr24_y(); local v = bit.band(c:read_mem(addr) - 1, 0xffff)
    c:write_mem(addr, v); c:update_zn(v); c.pc = c.pc + 4; return true
end

-- -----------------------------------------------------------
-- esecuzione
-- -----------------------------------------------------------
function CPU:step()
    local op = self.mem[self.pc]
    local handler = OPCODES[op]
    if not handler then
        error(string.format("Opcode sconosciuto: 0x%02X a pc=0x%06X", op, self.pc))
    end
    return handler(self)
end

function CPU:run(start_pc, input_byte, extra_inputs, max_steps)
    input_byte = input_byte or 0
    max_steps = max_steps or 200000
    self.pc = start_pc
    self.mem[PORT_INPUT] = bit.band(input_byte, 0xff)
    if extra_inputs then
        for i, port in ipairs(mm.EXTRA_INPUT_PORTS) do
            if extra_inputs[i] == nil then break end
            self.mem[port] = bit.band(extra_inputs[i], 0xff)
        end
    end
    local steps = 0
    while steps < max_steps do
        steps = steps + 1
        if not self:step() then
            return steps
        end
    end
    error(string.format("Superato il limite di sicurezza di %d passi (loop infinito?)", max_steps))
end

return M
