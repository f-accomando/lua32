--[[
test_ppu.lua - test del PPU: tile a taglia variabile sulla griglia
densa 8x8 (con celle "coperte" da tile piu' grandi), palette a 24-bit,
sprite (posizione, trasparenza, flip, visibilita').

    luajit tests/test_ppu.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local ppu = require("ppu")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local function new_mem()
    return ffi.new("uint8_t[?]", mm.ADDRESS_SPACE)
end

-- ---------------------------------------------------------------
-- helper di test: scrivono asset in VRAM/OAM/CGRAM - non fanno parte
-- del PPU vero (quello sara' compito dell'editor/cart builder), qui
-- servono solo a costruire scene di prova
-- ---------------------------------------------------------------
local next_gfx_offset = 0
local function reset_gfx_allocator() next_gfx_offset = 0 end

local function write_tile(mem, tile_index, size, palette_index_grid)
    local size_class
    for i, s in ipairs(mm.TILE_SIZES) do
        if s == size then size_class = i - 1 end
    end
    assert(size_class, "taglia tile non valida: " .. tostring(size))
    ppu.set_directory_entry(mem, tile_index, next_gfx_offset, size_class)
    local base = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET + next_gfx_offset
    for y = 0, size - 1 do
        for x = 0, size - 1 do
            mem[base + y * size + x] = palette_index_grid[y * size + x + 1] or 0
        end
    end
    next_gfx_offset = next_gfx_offset + size * size
end

local function write_tilemap_entry(mem, cx, cy, tile_index, palette)
    local addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET + (cy * mm.TILEMAP_W + cx) * mm.TILEMAP_ENTRY_BYTES
    local word = ppu.encode_tile_descriptor(tile_index, palette)
    mem[addr] = word % 256
    mem[addr + 1] = math.floor(word / 256) % 256
end

local function write_oam(mem, slot, x, y, tile_index, palette, attr)
    local base = mm.OAM_BASE + slot * mm.OAM_SLOT_BYTES
    mem[base] = x % 256; mem[base + 1] = math.floor(x / 256) % 256
    mem[base + 2] = y % 256; mem[base + 3] = math.floor(y / 256) % 256
    local word = ppu.encode_tile_descriptor(tile_index, palette)
    mem[base + 4] = word % 256; mem[base + 5] = math.floor(word / 256) % 256
    mem[base + 6] = attr % 256; mem[base + 7] = 0
end

local function pixel(buf, w, x, y)
    local off = (y * w + x) * 3
    return buf[off], buf[off + 1], buf[off + 2]
end

-- ---------------------------------------------------------------
-- un tile 8x8 semplice, a scroll zero
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 1, 200, 50, 50)   -- palette 0, indice 1 = rosso
    ppu.set_color(mem, 0, 2, 50, 200, 50)   -- palette 0, indice 2 = verde
    -- tile 8x8: meta' sinistra indice 1 (rosso), meta' destra indice 2 (verde)
    local grid = {}
    for y = 0, 7 do
        for x = 0, 7 do
            grid[y * 8 + x + 1] = (x < 4) and 1 or 2
        end
    end
    write_tile(mem, 1, 8, grid)
    write_tilemap_entry(mem, 0, 0, 1, 0)

    local buf = ppu.render_background(mem, 0, 0, 16, 16)
    local r, g, b = pixel(buf, 16, 1, 1)
    check("tile 8x8: pixel rosso a sinistra", r == 200 and g == 50, true)
    local r2, g2, b2 = pixel(buf, 16, 6, 1)
    check("tile 8x8: pixel verde a destra", g2 == 200 and r2 == 50, true)
end

-- ---------------------------------------------------------------
-- indice 0 = trasparente: non deve scrivere nulla (resta il default
-- del buffer, zero)
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 1, 255, 255, 255)
    local grid = {}
    for i = 1, 64 do grid[i] = 0 end  -- tutto trasparente
    write_tile(mem, 1, 8, grid)
    write_tilemap_entry(mem, 0, 0, 1, 0)
    local buf = ppu.render_background(mem, 0, 0, 8, 8)
    local r, g, b = pixel(buf, 8, 4, 4)
    check("indice 0 trasparente: nessun colore scritto", r == 0 and g == 0 and b == 0, true)
end

-- ---------------------------------------------------------------
-- tile 32x32 che copre un blocco 4x4 di celle - le celle "coperte"
-- con entry diverse (spazzatura) devono essere ignorate
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 5, 10, 20, 30)
    local grid = {}
    for i = 1, 32 * 32 do grid[i] = 5 end  -- tile 32x32 tutto dello stesso colore
    write_tile(mem, 2, 32, grid)
    write_tilemap_entry(mem, 0, 0, 2, 0)  -- origine del tile grande

    -- "spazzatura" nelle celle che il tile da 32x32 dovrebbe coprire -
    -- un tile diverso, mai disegnato se il PPU salta le celle coperte
    ppu.set_color(mem, 0, 9, 250, 0, 250)
    local junk = {}
    for i = 1, 64 do junk[i] = 9 end
    write_tile(mem, 3, 8, junk)
    write_tilemap_entry(mem, 2, 2, 3, 0)  -- dentro il blocco 4x4 coperto da tile_index=2

    local buf = ppu.render_background(mem, 0, 0, 32, 32)
    local r, g, b = pixel(buf, 32, 20, 20)  -- dentro l'area "coperta"
    check("tile 32x32: la cella coperta mostra il tile grande, non la spazzatura",
          r == 10 and g == 20 and b == 30, true)
    local r2 = pixel(buf, 32, 31, 31)
    check("tile 32x32: copre fino all'ultimo pixel del blocco 4x4", r2, 10)
end

-- ---------------------------------------------------------------
-- palette diverse per lo stesso indice danno colori diversi
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 1, 100, 0, 0)
    ppu.set_color(mem, 3, 1, 0, 0, 100)
    local grid = {}
    for i = 1, 64 do grid[i] = 1 end
    write_tile(mem, 1, 8, grid)
    write_tilemap_entry(mem, 0, 0, 1, 3)  -- stesso tile, palette 3

    local buf = ppu.render_background(mem, 0, 0, 8, 8)
    local r, g, b = pixel(buf, 8, 0, 0)
    check("palette diversa per lo stesso tile: colore della palette 3", b, 100)
end

-- ---------------------------------------------------------------
-- scroll: un tile a origine (1,1) in celle (8,8 in pixel) deve
-- apparire spostato di conseguenza sullo schermo
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 7, 77, 77, 77)
    local grid = {}
    for i = 1, 64 do grid[i] = 7 end
    write_tile(mem, 1, 8, grid)
    write_tilemap_entry(mem, 2, 0, 1, 0)  -- a x=16px nel mondo

    local buf_noscroll = ppu.render_background(mem, 0, 0, 32, 8)
    local r1 = pixel(buf_noscroll, 32, 16, 0)
    check("senza scroll: tile visibile a x=16", r1, 77)

    local buf_scrolled = ppu.render_background(mem, 16, 0, 32, 8)
    local r2 = pixel(buf_scrolled, 32, 0, 0)
    check("con scroll_x=16: lo stesso tile ora e' a x=0 sullo schermo", r2, 77)
end

-- ---------------------------------------------------------------
-- sprite: posizione, trasparenza, disegnato sopra lo sfondo
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 1, 1, 1, 1)   -- sfondo
    ppu.set_color(mem, 0, 3, 250, 250, 0)  -- sprite

    local bg_grid = {}
    for i = 1, 64 do bg_grid[i] = 1 end
    write_tile(mem, 1, 8, bg_grid)
    write_tilemap_entry(mem, 0, 0, 1, 0)

    local sprite_grid = {}
    for y = 0, 7 do
        for x = 0, 7 do
            sprite_grid[y * 8 + x + 1] = (x == 0 and y == 0) and 3 or 0  -- un solo pixel opaco
        end
    end
    write_tile(mem, 2, 8, sprite_grid)
    write_oam(mem, 0, 2, 2, 2, 0, mm.OAM_ATTR_VISIBLE)

    local buf = ppu.render_frame(mem, 0, 0, 8, 8)
    local rs, gs, bs = pixel(buf, 8, 2, 2)
    check("sprite: pixel opaco sopra lo sfondo", rs == 250 and gs == 250 and bs == 0, true)
    local rb = pixel(buf, 8, 5, 5)
    check("sprite: sfondo visibile fuori dal pixel opaco dello sprite", rb, 1)
    local rt = pixel(buf, 8, 3, 2)
    check("sprite: pixel trasparente dello sprite lascia vedere lo sfondo sotto", rt, 1)
end

do
    -- sprite NON visibile (bit VISIBLE spento) non deve disegnare nulla
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 3, 250, 250, 0)
    local grid = {}
    for i = 1, 64 do grid[i] = 3 end
    write_tile(mem, 1, 8, grid)
    write_oam(mem, 0, 0, 0, 1, 0, 0)  -- attr=0, VISIBLE non impostato

    local buf = ppu.render_frame(mem, 0, 0, 8, 8)
    local r = pixel(buf, 8, 0, 0)
    check("sprite invisibile (VISIBLE=0): non disegnato", r, 0)
end

do
    -- flip orizzontale: un tile asimmetrico (rosso a sinistra, verde a
    -- destra) con flip_x deve apparire ribaltato
    local mem = new_mem()
    reset_gfx_allocator()
    ppu.set_color(mem, 0, 1, 200, 0, 0)
    ppu.set_color(mem, 0, 2, 0, 200, 0)
    local grid = {}
    for y = 0, 7 do
        for x = 0, 7 do
            grid[y * 8 + x + 1] = (x < 4) and 1 or 2
        end
    end
    write_tile(mem, 1, 8, grid)
    write_oam(mem, 0, 0, 0, 1, 0, mm.OAM_ATTR_VISIBLE + mm.OAM_ATTR_FLIP_X)

    local buf = ppu.render_frame(mem, 0, 0, 8, 8)
    local r_left, g_left = pixel(buf, 8, 1, 1)
    local r_right, g_right = pixel(buf, 8, 6, 1)
    check("flip orizzontale: verde ora a sinistra (era rosso)", r_left == 0 and g_left == 200, true)
    check("flip orizzontale: rosso ora a destra (era verde)", r_right == 200 and g_right == 0, true)
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
