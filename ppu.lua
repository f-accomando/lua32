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
-- -----------------------------------------------------------
local CELL_PX = 8
local MAX_SPAN_CELLS = 8  -- 64px / 8px: quanto puo' estendersi
                           -- all'indietro l'origine di un tile grande

function M.render_background(mem, scroll_x, scroll_y, screen_w, screen_h)
    local buf = ffi.new("uint8_t[?]", screen_w * screen_h * 3)

    local first_cell_x = math.floor(scroll_x / CELL_PX) - MAX_SPAN_CELLS
    local first_cell_y = math.floor(scroll_y / CELL_PX) - MAX_SPAN_CELLS
    local last_cell_x = math.floor((scroll_x + screen_w - 1) / CELL_PX)
    local last_cell_y = math.floor((scroll_y + screen_h - 1) / CELL_PX)

    local covered = {}  -- covered[cy][cx] = true se gia' disegnata da un tile piu' grande
    local function is_covered(cx, cy)
        local row = covered[cy]
        return row ~= nil and row[cx]
    end
    local function mark_covered(cx, cy)
        local row = covered[cy]
        if not row then row = {}; covered[cy] = row end
        row[cx] = true
    end

    for cy = first_cell_y, last_cell_y do
        for cx = first_cell_x, last_cell_x do
            if not is_covered(cx, cy) then
                local tm_x = cx % mm.TILEMAP_W
                local tm_y = cy % mm.TILEMAP_H
                if tm_x < 0 then tm_x = tm_x + mm.TILEMAP_W end
                if tm_y < 0 then tm_y = tm_y + mm.TILEMAP_H end
                local entry_addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET
                    + (tm_y * mm.TILEMAP_W + tm_x) * mm.TILEMAP_ENTRY_BYTES
                local tile_index, palette = M.decode_tile_descriptor(read16(mem, entry_addr))

                if tile_index ~= 0 then
                    local offset, size = M.get_tile_info(mem, tile_index)
                    local span = size / CELL_PX

                    for dy = 0, span - 1 do
                        for dx = 0, span - 1 do
                            mark_covered(cx + dx, cy + dy)
                        end
                    end

                    local tile_world_x = cx * CELL_PX
                    local tile_world_y = cy * CELL_PX
                    for ly = 0, size - 1 do
                        local oy = tile_world_y + ly - scroll_y
                        if oy >= 0 and oy < screen_h then
                            local row_base = oy * screen_w
                            for lx = 0, size - 1 do
                                local ox = tile_world_x + lx - scroll_x
                                if ox >= 0 and ox < screen_w then
                                    local pal_index = M.sample_tile_pixel(mem, offset, size, lx, ly)
                                    if pal_index ~= 0 then
                                        local r, g, b = M.decode_color(mem, palette, pal_index)
                                        local pix = (row_base + ox) * 3
                                        buf[pix] = r
                                        buf[pix + 1] = g
                                        buf[pix + 2] = b
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
            local tile_index, palette = M.decode_tile_descriptor(read16(mem, base + 4))
            if x > 32767 then x = x - 65536 end  -- 16 bit con segno, uno
            if y > 32767 then y = y - 65536 end  -- sprite puo' uscire dal bordo
            local flip_x = bit.band(attr, mm.OAM_ATTR_FLIP_X) ~= 0
            local flip_y = bit.band(attr, mm.OAM_ATTR_FLIP_Y) ~= 0
            local offset, size = M.get_tile_info(mem, tile_index)

            for ly = 0, size - 1 do
                local oy = y + ly
                if oy >= 0 and oy < screen_h then
                    local sy = flip_y and (size - 1 - ly) or ly
                    local row_base = oy * screen_w
                    for lx = 0, size - 1 do
                        local ox = x + lx
                        if ox >= 0 and ox < screen_w then
                            local sx = flip_x and (size - 1 - lx) or lx
                            local pal_index = M.sample_tile_pixel(mem, offset, size, sx, sy)
                            if pal_index ~= 0 then
                                local r, g, b = M.decode_color(mem, palette, pal_index)
                                local pix = (row_base + ox) * 3
                                buf[pix] = r
                                buf[pix + 1] = g
                                buf[pix + 2] = b
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
