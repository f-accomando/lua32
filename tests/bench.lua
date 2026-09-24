--[[
bench.lua - indice di prestazioni del motore attuale: CPU (demo
program), PPU (sfondo/sprite/tile grandi a 320x224), e la combinazione
delle due (senza video/present, che richiede una GPU vera).

ATTENZIONE: questi numeri sono validi SOLO sulla macchina su cui
girano - x86 (sviluppo) e ARM11 del Raspberry Pi 1 (target vero) hanno
prestazioni per-istruzione radicalmente diverse (visto piu' volte nel
vecchio motore Python: un fattore anche di 10-15x). Usare per un
confronto RELATIVO fra versioni sulla STESSA macchina, non come numero
assoluto per il target.

Uso:
    luajit tests/bench.lua [n_frame]
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local cpu_module = require("cpu")
local ppu = require("ppu")
local demo = require("main")

local N = tonumber(arg[1]) or 2000
local SCREEN_W, SCREEN_H = demo.SCREEN_W, demo.SCREEN_H

ffi.cdef[[
typedef struct { long tv_sec; long tv_nsec; } timespec_t;
int clock_gettime(int clk_id, timespec_t *tp);
]]
local CLOCK_MONOTONIC = 1
local function now()
    local ts = ffi.new("timespec_t")
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

local function report(label, total_s, n)
    local ms = total_s / n * 1000
    local fps = 1000 / ms
    print(string.format("%-38s %8.4f ms/frame  (%.0f fps equivalenti)", label, ms, fps))
end

print(string.format("=== bench.lua: %d iterazioni, risoluzione %dx%d ===", N, SCREEN_W, SCREEN_H))
print()

-- ---------------------------------------------------------------
-- 1) CPU: il programma demo (movimento + clamp), input che cambia
--    ogni frame per esercitare tutti i rami (non solo il piu' corto)
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    local oam_base = demo.setup_demo_assets(cpu)
    local rom = demo.build_demo_program(oam_base)
    for i, b in ipairs(rom) do cpu.mem[demo.CART_LOAD_ADDR + i - 1] = b end

    local inputs = {0x00, 0x01, 0x08, 0x09, 0x02, 0x04}
    local total_instr = 0
    local t0 = now()
    for i = 1, N do
        total_instr = total_instr + cpu:run(demo.CART_LOAD_ADDR, inputs[(i % #inputs) + 1])
    end
    local elapsed = now() - t0
    report("CPU (programma demo)", elapsed, N)
    print(string.format("  -> %.1f istruzioni/frame media, %.3f us/istruzione",
        total_instr / N, elapsed / total_instr * 1e6))
    print()
end

-- ---------------------------------------------------------------
-- 2) PPU: sfondo pieno (tile 8x8 ripetuto su tutto lo schermo, come
--    fa il demo di main.lua)
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    demo.setup_demo_assets(cpu)
    local t0 = now()
    for i = 1, N do
        ppu.render_frame(cpu.mem, 0, 0, SCREEN_W, SCREEN_H)
    end
    report("PPU: sfondo pieno 8x8 (nessuno sprite)", now() - t0, N)
end

-- ---------------------------------------------------------------
-- 3) PPU: sfondo pieno + 50 sprite (una scena piu' vicina a un gioco
--    vero: nemici, proiettili, effetti)
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    local oam_base = demo.setup_demo_assets(cpu)
    local mem = cpu.mem
    for slot = 1, 50 do
        local base = mm.OAM_BASE + slot * mm.OAM_SLOT_BYTES
        local x, y = (slot * 17) % (SCREEN_W - 16), (slot * 23) % (SCREEN_H - 16)
        mem[base] = x % 256; mem[base + 1] = math.floor(x / 256) % 256
        mem[base + 2] = y % 256; mem[base + 3] = math.floor(y / 256) % 256
        local word = ppu.encode_tile_descriptor(2, 0)
        mem[base + 4] = word % 256; mem[base + 5] = math.floor(word / 256) % 256
        mem[base + 6] = mm.OAM_ATTR_VISIBLE; mem[base + 7] = 0
    end
    local t0 = now()
    for i = 1, N do
        ppu.render_frame(mem, 0, 0, SCREEN_W, SCREEN_H)
    end
    report("PPU: sfondo pieno + 50 sprite 16x16", now() - t0, N)
end

-- ---------------------------------------------------------------
-- 4) PPU: sfondo con tile grandi misti (32x32/64x64) - il caso che
--    esercita di piu' la logica "coperto" della griglia densa
-- ---------------------------------------------------------------
do
    local cpu = cpu_module.new()
    local mem = cpu.mem
    ppu.set_color(mem, 0, 1, 40, 80, 120)
    ppu.set_color(mem, 0, 2, 120, 40, 80)

    ppu.set_directory_entry(mem, 1, 0, 0)  -- 8x8
    for i = 0, 63 do mem[mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET + i] = 1 end

    ppu.set_directory_entry(mem, 2, 64, 3)  -- 64x64, size_class 3
    local base64 = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET + 64
    for i = 0, 64 * 64 - 1 do mem[base64 + i] = 2 end

    local small_word = ppu.encode_tile_descriptor(1, 0)
    local big_word = ppu.encode_tile_descriptor(2, 0)
    for cy = 0, math.ceil(SCREEN_H / 8) do
        for cx = 0, math.ceil(SCREEN_W / 8) do
            local addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET + (cy * mm.TILEMAP_W + cx) * mm.TILEMAP_ENTRY_BYTES
            local word = small_word
            -- un tile 64x64 (8x8 celle) ogni 8 celle, alternato allo sfondo 8x8
            if cx % 8 == 0 and cy % 8 == 0 then word = big_word end
            mem[addr] = word % 256
            mem[addr + 1] = math.floor(word / 256) % 256
        end
    end

    local t0 = now()
    for i = 1, N do
        ppu.render_background(mem, 0, 0, SCREEN_W, SCREEN_H)
    end
    report("PPU: tile 64x64 misti a 8x8 (griglia \"coperto\")", now() - t0, N)
end

print()
print("Ricorda: numeri validi solo su QUESTA macchina - rilancia identico")
print("sul Raspberry Pi (luajit tests/bench.lua) per il numero che conta.")
