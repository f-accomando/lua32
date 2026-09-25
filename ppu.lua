--[[
ppu.lua - compositing di s32: legge tilemap/OAM/CGRAM/grafica dalla
memoria della CPU e produce un buffer RGB888 (uint8_t[w*h*3]).

Griglia densa a 8x8 (opzione A, vedi docs/design.md "Mappa di
memoria"): un tile piu' grande della cella base occupa un blocco di
celle a partire dalla sua "origine" - lo scan delle celle e' un solo
passaggio top-to-bottom/left-to-right con una griglia temporanea
"coperto" (una cella coperta da un tile piu' grande visto in
precedenza viene saltata, mai riletta come propria origine).

La taglia di un tile NON e' nel descrittore a 16 bit (tilemap/OAM) -
e' nella tabella directory, unica fonte di verita': un tile ha sempre
la stessa taglia ovunque venga referenziato.
]]
local ffi = require("ffi")
local bit = require("bit")
local mm = require("memory_map")

local M = {}

local TILE_SIZES = mm.TILE_SIZES
local INDEX_MASK = bit.lshift(1, mm.TILE_DESC_INDEX_BITS) - 1  -- 0x7FF

local function read16(mem, addr)
    return bit.bor(mem[addr], bit.lshift(mem[addr + 1], 8))
end

-- -----------------------------------------------------------
-- descrittore di tile (16 bit): tile_index (11 bit) + palette (3 bit)
-- + 2 bit riservati
-- -----------------------------------------------------------
function M.decode_tile_descriptor(word)
    local tile_index = bit.band(word, INDEX_MASK)
    local palette = bit.band(bit.rshift(word, mm.TILE_DESC_INDEX_BITS), 0x07)
    return tile_index, palette
end

function M.encode_tile_descriptor(tile_index, palette)
    return bit.bor(bit.band(tile_index, INDEX_MASK),
                    bit.lshift(bit.band(palette, 0x07), mm.TILE_DESC_INDEX_BITS))
end

-- -----------------------------------------------------------
-- directory: tile_index -> (offset nell'archivio grafico, taglia)
-- -----------------------------------------------------------
function M.get_directory_entry(mem, tile_index)
    local addr = mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET + tile_index * mm.DIRECTORY_ENTRY_BYTES
    local offset = bit.bor(mem[addr], bit.lshift(mem[addr + 1], 8), bit.lshift(mem[addr + 2], 16))
    local size_class = mem[addr + 3]
    return offset, size_class
end

function M.set_directory_entry(mem, tile_index, offset, size_class)
    local addr = mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET + tile_index * mm.DIRECTORY_ENTRY_BYTES
    mem[addr] = bit.band(offset, 0xff)
    mem[addr + 1] = bit.band(bit.rshift(offset, 8), 0xff)
    mem[addr + 2] = bit.band(bit.rshift(offset, 16), 0xff)
    mem[addr + 3] = size_class
    M._track_tile_usage(mem, tile_index, size_class)
end

-- -----------------------------------------------------------
-- tracking dell'uso dell'archivio grafico, per il pannello di stato
-- (lcd_status.lua "VRAM"): quanti byte sono davvero occupati da tile
-- REALMENTE definiti, non l'intera dimensione fissa del pool. Non e'
-- derivabile leggendo la sola directory a posteriori (un entry mai
-- toccato e uno che punta davvero a offset 0/size 8x8 sono byte
-- identici) - va contato quando si definisce un tile, qui.
--
-- LIMITE NOTO: uno swap di banco grafico (PORT_GFX_BANK_SELECT) fa un
-- ffi.copy grezzo, senza passare da qui - il conteggio dopo uno swap
-- resta quello di prima dello swap. Non e' un problema oggi (nessun
-- punto del motore fa ancora swap di banchi grafici veri, solo
-- set_directory_entry diretto) - da rivedere quando esistera' un
-- primo caso d'uso reale di banchi swappabili.
-- -----------------------------------------------------------
local usage_registry = {}  -- [mem] = { seen = {[tile_index]=size_bytes}, total = N }

function M._track_tile_usage(mem, tile_index, size_class)
    local reg = usage_registry[mem]
    if not reg then
        reg = { seen = {}, total = 0 }
        usage_registry[mem] = reg
    end
    local size = TILE_SIZES[size_class + 1]
    local bytes = size * size
    local prev = reg.seen[tile_index]
    if prev then
        reg.total = reg.total - prev + bytes
    else
        reg.total = reg.total + bytes
    end
    reg.seen[tile_index] = bytes
end

-- percentuale di VRAM totale occupata: tilemap+directory sono sempre
-- "allocate" per struttura (dimensione fissa), la parte variabile e'
-- solo l'archivio grafico (vedi tracking sopra)
function M.get_vram_usage_pct(mem)
    local reg = usage_registry[mem]
    local gfx_used = reg and reg.total or 0
    local used = mm.TILEMAP_BYTES + mm.DIRECTORY_BYTES + gfx_used
    return math.min(100, used / mm.VRAM_SIZE * 100)
end

-- offset+taglia (byte) di un tile - una sola lettura di directory,
-- da riusare per tutti i pixel dello stesso tile (non richiamare
-- get_directory_entry per ogni pixel)
function M.get_tile_info(mem, tile_index)
    local offset, size_class = M.get_directory_entry(mem, tile_index)
    return offset, TILE_SIZES[size_class + 1]
end

-- indice di palette (0-255, 0 = trasparente) del pixel (local_x,local_y)
-- dentro un tile gia' risolto (offset+size da get_tile_info)
function M.sample_tile_pixel(mem, offset, size, local_x, local_y)
    local addr = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET + offset + local_y * size + local_x
    return mem[addr]
end

-- -----------------------------------------------------------
-- CGRAM: 24-bit (RGB888), 8 palette da 256 colori
-- -----------------------------------------------------------
function M.decode_color(mem, palette, index)
    local addr = mm.CGRAM_BASE + (palette * mm.COLORS_PER_PALETTE + index) * mm.CGRAM_COLOR_BYTES
    return mem[addr], mem[addr + 1], mem[addr + 2]
end

function M.set_color(mem, palette, index, r, g, b)
    local addr = mm.CGRAM_BASE + (palette * mm.COLORS_PER_PALETTE + index) * mm.CGRAM_COLOR_BYTES
    mem[addr] = r
    mem[addr + 1] = g
    mem[addr + 2] = b
end

-- -----------------------------------------------------------
-- sfondo: griglia densa a 8x8, un solo passaggio con "coperto"
--
-- OTTIMIZZAZIONE (dopo il primo benchmark reale su Pi 1, ~20-36ms per
-- un fondo 320x224 - vedi docs/scheda_tecnica.md): due cambi, non uno
-- solo, perche' le cause erano distinte:
--
-- 1. Prima si allocava un buffer di output NUOVO (ffi.new, ~215KB per
--    320x224) e una griglia "coperto" fatta di tabelle Lua annidate
--    NUOVE ad ogni singola chiamata - decine di volte al secondo. Su
--    un Pi 1 con poca banda di memoria e un solo core, la pressione
--    sul GC/allocatore per liberare e ricreare tutto questo ad ogni
--    frame e' reale. Ora entrambi sono riusati fra una chiamata e
--    l'altra (cache a livello di modulo, riallocata solo se cambiano
--    le dimensioni) e semplicemente azzerati con ffi.fill (un memset,
--    ordini di grandezza piu' veloce di ricreare tabelle/cdata).
--    CONTRATTO: il buffer ritornato e' valido solo fino alla chiamata
--    successiva a render_background/render_frame - va consumato
--    subito (esattamente come gia' fa v:present() e ogni test
--    esistente, che leggono i pixel subito dopo la chiamata).
-- 2. Il ciclo per-pixel chiamava sample_tile_pixel()/decode_color()
--    (due funzioni) per OGNI pixel, e decode_color ricalcolava
--    l'indirizzo CGRAM da zero ogni volta (moltiplicazione per
--    palette*COLORS_PER_PALETTE inclusa) anche se la palette di un
--    tile e' la stessa per tutti i suoi pixel. Ora l'indirizzo base
--    della palette e dell'archivio grafico si calcola UNA VOLTA per
--    tile (non per pixel) e il ciclo interno legge direttamente da
--    mem[] senza chiamate di funzione.
-- -----------------------------------------------------------
local CELL_PX = 8
local MAX_SPAN_CELLS = 8  -- 64px / 8px: quanto puo' estendersi
                           -- all'indietro l'origine di un tile grande

local TILEMAP_W, TILEMAP_H = mm.TILEMAP_W, mm.TILEMAP_H
local TILEMAP_ENTRY_BYTES = mm.TILEMAP_ENTRY_BYTES
local TILE_DESC_INDEX_BITS = mm.TILE_DESC_INDEX_BITS
local VRAM_TILEMAP_BASE = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET
local VRAM_DIRECTORY_BASE = mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET
local GRAPHICS_POOL_BASE = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET
local DIRECTORY_ENTRY_BYTES = mm.DIRECTORY_ENTRY_BYTES
local CGRAM_BASE = mm.CGRAM_BASE
local COLORS_PER_PALETTE = mm.COLORS_PER_PALETTE
local CGRAM_COLOR_BYTES = mm.CGRAM_COLOR_BYTES

local frame_buf_cache = { size = 0, buf = nil }
local function get_frame_buf(screen_w, screen_h)
    local needed = screen_w * screen_h * 3
    if frame_buf_cache.size ~= needed then
        frame_buf_cache.buf = ffi.new("uint8_t[?]", needed)
        frame_buf_cache.size = needed
    end
    ffi.fill(frame_buf_cache.buf, needed, 0)
    return frame_buf_cache.buf
end

local covered_cache = { cols = 0, rows = 0, grid = nil }
local function get_covered_grid(cols, rows)
    local total = cols * rows
    if covered_cache.cols ~= cols or covered_cache.rows ~= rows then
        covered_cache.grid = ffi.new("uint8_t[?]", total)
        covered_cache.cols, covered_cache.rows = cols, rows
    else
        ffi.fill(covered_cache.grid, total, 0)
    end
    return covered_cache.grid
end

function M.render_background(mem, scroll_x, scroll_y, screen_w, screen_h)
    local buf = get_frame_buf(screen_w, screen_h)

    local first_cell_x = math.floor(scroll_x / CELL_PX) - MAX_SPAN_CELLS
    local first_cell_y = math.floor(scroll_y / CELL_PX) - MAX_SPAN_CELLS
    local last_cell_x = math.floor((scroll_x + screen_w - 1) / CELL_PX)
    local last_cell_y = math.floor((scroll_y + screen_h - 1) / CELL_PX)

    local cols = last_cell_x - first_cell_x + 1
    local rows = last_cell_y - first_cell_y + 1
    local covered = get_covered_grid(cols, rows)

    for cy = first_cell_y, last_cell_y do
        local crow = (cy - first_cell_y) * cols
        for cx = first_cell_x, last_cell_x do
            local cidx = crow + (cx - first_cell_x)
            if covered[cidx] == 0 then
                local tm_x = cx % TILEMAP_W
                local tm_y = cy % TILEMAP_H
                if tm_x < 0 then tm_x = tm_x + TILEMAP_W end
                if tm_y < 0 then tm_y = tm_y + TILEMAP_H end
                local entry_addr = VRAM_TILEMAP_BASE + (tm_y * TILEMAP_W + tm_x) * TILEMAP_ENTRY_BYTES
                local word = bit.bor(mem[entry_addr], bit.lshift(mem[entry_addr + 1], 8))
                local tile_index = bit.band(word, INDEX_MASK)

                if tile_index ~= 0 then
                    local palette = bit.band(bit.rshift(word, TILE_DESC_INDEX_BITS), 0x07)
                    local dir_addr = VRAM_DIRECTORY_BASE + tile_index * DIRECTORY_ENTRY_BYTES
                    local offset = bit.bor(mem[dir_addr], bit.lshift(mem[dir_addr + 1], 8),
                        bit.lshift(mem[dir_addr + 2], 16))
                    local size = TILE_SIZES[mem[dir_addr + 3] + 1]
                    local span = size / CELL_PX

                    local dy_max = math.min(span - 1, last_cell_y - cy)
                    local dx_max = math.min(span - 1, last_cell_x - cx)
                    for dy = 0, dy_max do
                        local mrow = crow + dy * cols
                        for dx = 0, dx_max do
                            covered[mrow + (cx - first_cell_x) + dx] = 1
                        end
                    end

                    -- indirizzi base per QUESTO tile (calcolati una
                    -- volta, non per ogni pixel - vedi nota in testa)
                    local tile_pixel_base = GRAPHICS_POOL_BASE + offset
                    local palette_base = CGRAM_BASE + palette * COLORS_PER_PALETTE * CGRAM_COLOR_BYTES

                    local tile_world_x = cx * CELL_PX
                    local tile_world_y = cy * CELL_PX
                    for ly = 0, size - 1 do
                        local oy = tile_world_y + ly - scroll_y
                        if oy >= 0 and oy < screen_h then
                            local row_base = oy * screen_w
                            local tile_row_base = tile_pixel_base + ly * size
                            for lx = 0, size - 1 do
                                local ox = tile_world_x + lx - scroll_x
                                if ox >= 0 and ox < screen_w then
                                    local pal_index = mem[tile_row_base + lx]
                                    if pal_index ~= 0 then
                                        local caddr = palette_base + pal_index * CGRAM_COLOR_BYTES
                                        local pix = (row_base + ox) * 3
                                        buf[pix] = mem[caddr]
                                        buf[pix + 1] = mem[caddr + 1]
                                        buf[pix + 2] = mem[caddr + 2]
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return buf
end

-- -----------------------------------------------------------
-- sprite: coordinate schermo dirette (non scrollate), disegnati
-- sopra lo sfondo nell'ordine degli slot OAM (slot piu' alto = sopra)
-- -----------------------------------------------------------
function M.render_sprites(mem, buf, screen_w, screen_h)
    for i = 0, mm.OAM_MAX_SPRITES - 1 do
        local base = mm.OAM_BASE + i * mm.OAM_SLOT_BYTES
        local attr = read16(mem, base + 6)
        if bit.band(attr, mm.OAM_ATTR_VISIBLE) ~= 0 then
            local x = read16(mem, base + 0)
            local y = read16(mem, base + 2)
            local word = read16(mem, base + 4)
            local tile_index = bit.band(word, INDEX_MASK)
            local palette = bit.band(bit.rshift(word, TILE_DESC_INDEX_BITS), 0x07)
            if x > 32767 then x = x - 65536 end  -- 16 bit con segno, uno
            if y > 32767 then y = y - 65536 end  -- sprite puo' uscire dal bordo
            local flip_x = bit.band(attr, mm.OAM_ATTR_FLIP_X) ~= 0
            local flip_y = bit.band(attr, mm.OAM_ATTR_FLIP_Y) ~= 0
            local offset, size = M.get_tile_info(mem, tile_index)

            -- indirizzi base per QUESTO sprite (una volta, non per
            -- pixel - stessa idea di render_background)
            local tile_pixel_base = GRAPHICS_POOL_BASE + offset
            local palette_base = CGRAM_BASE + palette * COLORS_PER_PALETTE * CGRAM_COLOR_BYTES

            for ly = 0, size - 1 do
                local oy = y + ly
                if oy >= 0 and oy < screen_h then
                    local sy = flip_y and (size - 1 - ly) or ly
                    local row_base = oy * screen_w
                    local tile_row_base = tile_pixel_base + sy * size
                    for lx = 0, size - 1 do
                        local ox = x + lx
                        if ox >= 0 and ox < screen_w then
                            local sx = flip_x and (size - 1 - lx) or lx
                            local pal_index = mem[tile_row_base + sx]
                            if pal_index ~= 0 then
                                local caddr = palette_base + pal_index * CGRAM_COLOR_BYTES
                                local pix = (row_base + ox) * 3
                                buf[pix] = mem[caddr]
                                buf[pix + 1] = mem[caddr + 1]
                                buf[pix + 2] = mem[caddr + 2]
                            end
                        end
                    end
                end
            end
        end
    end
end

function M.render_frame(mem, scroll_x, scroll_y, screen_w, screen_h)
    local buf = M.render_background(mem, scroll_x, scroll_y, screen_w, screen_h)
    M.render_sprites(mem, buf, screen_w, screen_h)
    return buf
end

return M
