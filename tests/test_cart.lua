--[[
test_cart.lua - verifica il formato cartuccia (cart.lua): pack -> load
round-trip byte-per-byte, install() dentro una CPU vera (compresi gli
swap PORT_STAGE_SELECT/PORT_GFX_BANK_SELECT), e rilevamento corruzione
via CRC32.

    luajit tests/test_cart.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local mm = require("memory_map")
local cpu_module = require("cpu")
local assembler = require("assembler")
local ppu = require("ppu")
local cart = require("cart")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL",
        label, tostring(expected), tostring(got)))
end

-- come check(), ma per blob binari: non stampa MAI il contenuto (anche
-- in caso di fallimento sarebbe centinaia di KB di byte grezzi sullo
-- stdout) - solo lunghezza ed esito
local function check_bytes(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: %d byte, %s", ok and "OK  " or "FAIL",
        label, #expected, ok and "identico" or string.format("DIVERSO (ottenuto %d byte)", #got)))
end

local CART_LOAD_ADDR = 0x1000
local RESULT_ADDR = 0x3000

-- ---------------------------------------------------------------
-- 1) costruisci gli asset "a mano" in una CPU scratch (esattamente
--    come farebbe un packager: componi in VRAM, poi fotografa le
--    regioni in stringhe di byte da mettere nel file)
-- ---------------------------------------------------------------
local scratch = cpu_module.new()
local mem = scratch.mem

ppu.set_color(mem, 0, 1, 10, 20, 30)
ppu.set_directory_entry(mem, 5, 0, 0)  -- tile_index 5, offset 0, 8x8
local pool_base = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET
for i = 0, 63 do mem[pool_base + i] = 1 end

local word = ppu.encode_tile_descriptor(5, 0)
local tm_addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET
mem[tm_addr] = word % 256
mem[tm_addr + 1] = math.floor(word / 256) % 256

local gfx_bank_size = mm.DIRECTORY_BYTES + mm.GRAPHICS_POOL_BYTES
local gfx_bank_0 = ffi.string(mem + mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET, gfx_bank_size)
local stage_bank_0 = ffi.string(mem + mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET, mm.TILEMAP_BYTES)
local cgram_snapshot = ffi.string(mem + mm.CGRAM_BASE, mm.CGRAM_SIZE)

local code = assembler.assemble(string.format([[
    LDA #4242
    STA %d
    HALT
]], RESULT_ADDR), CART_LOAD_ADDR)
local code_bytes = string.char(unpack(code))

local meta = cart.new_meta("Cartuccia di prova", "s32 dev")

-- ---------------------------------------------------------------
-- 2) pack -> file, poi load -> tabella, confronto byte-per-byte
-- ---------------------------------------------------------------
local tmp_path = os.tmpname()
cart.pack({
    meta = meta,
    code = code_bytes,
    stage_banks = { [0] = stage_bank_0 },
    gfx_banks = { [0] = gfx_bank_0 },
    cgram = cgram_snapshot,
}, tmp_path)

local loaded = cart.load(tmp_path)

check("titolo", loaded.meta.title, meta.title)
check("autore", loaded.meta.author, meta.author)
check_bytes("uid (16 byte)", loaded.meta.uid, meta.uid)
check_bytes("codice (round-trip)", loaded.code, code_bytes)
check_bytes("banco stage 0 (round-trip)", loaded.stage_banks[0], stage_bank_0)
check_bytes("banco grafico 0 (round-trip)", loaded.gfx_banks[0], gfx_bank_0)
check_bytes("cgram (round-trip)", loaded.cgram, cgram_snapshot)

-- ---------------------------------------------------------------
-- 3) install() dentro una CPU nuova: verifica che VRAM/CGRAM vengano
--    popolate dallo swap iniziale (PORT_STAGE_SELECT/PORT_GFX_BANK_SELECT
--    a banco 0) e che il codice giri per davvero
-- ---------------------------------------------------------------
local cpu2 = cpu_module.new()
cart.install(cpu2, loaded, CART_LOAD_ADDR)

check_bytes("VRAM tilemap ricopiata dallo swap", ffi.string(cpu2.mem + mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET, mm.TILEMAP_BYTES), stage_bank_0)
check_bytes("VRAM directory+pool ricopiata dallo swap", ffi.string(cpu2.mem + mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET, gfx_bank_size), gfx_bank_0)
check_bytes("CGRAM ricopiata da install()", ffi.string(cpu2.mem + mm.CGRAM_BASE, mm.CGRAM_SIZE), cgram_snapshot)

cpu2:run(CART_LOAD_ADDR, 0)
check("codice caricato eseguito correttamente", cpu2:read16(RESULT_ADDR), 4242)

-- ---------------------------------------------------------------
-- 4) corruzione: un byte alterato nel corpo del file deve far fallire
--    il CRC32 in load(), non passare silenziosamente
-- ---------------------------------------------------------------
do
    local f = io.open(tmp_path, "rb")
    local raw = f:read("*a")
    f:close()

    local corrupt_pos = cart.HEADER_SIZE + 5  -- dentro il "body", non l'header
    local b = raw:byte(corrupt_pos + 1)
    local corrupted = raw:sub(1, corrupt_pos) .. string.char(bit.bxor(b, 0xFF)) .. raw:sub(corrupt_pos + 2)

    local corrupt_path = os.tmpname()
    local cf = io.open(corrupt_path, "wb")
    cf:write(corrupted)
    cf:close()

    local ok, load_err = pcall(cart.load, corrupt_path)
    check("cartuccia corrotta rifiutata (CRC32)", ok, false)
    if not ok then print("  -> " .. tostring(load_err)) end

    os.remove(corrupt_path)
end

os.remove(tmp_path)

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
