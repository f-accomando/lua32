--[[
lcd_status.lua - pannello di stato sull'LCD SPI (separato dall'HDMI:
ora che il motore usa HDMI+KMSDRM per il gioco, l'LCD e' libero per
diagnostica - vedi docs/design.md). Ridisegna il disegno "shinchan"
(pre-convertito una volta con tests/shinchan_to_bin.py) con sopra una
fascia di statistiche live: tempo CPU, tempo PPU (compositing), tempo
GPU/blit (present su HDMI), banco grafica/stage correnti, FPS.

Scrive direttamente sul framebuffer del pannello (oggi /dev/fb0 -
verificato con `cat /proc/fb` sul Pi: fb_ili9486, 480x320, RGB565) con
una semplice scrittura sequenziale, la stessa tecnica gia' provata e
funzionante nello script shinchan.sh originale - non serve mmap per un
aggiornamento a bassa frequenza (qualche volta al secondo, non ogni
frame: un refresh pieno del pannello via SPI e' lento, ~33fps e' gia'
il limite del driver stesso).

Formato pixel: RGB565, byte basso poi byte alto - ESATTAMENTE l'ordine
gia' verificato sull'hardware reale (vedi commento originale
"immagine con byte RGB565 invertiti; colori attesi: rosso = rosso,
giallo = giallo"). Non "correggere" quest'ordine sulla base di quello
che ci si aspetterebbe in teoria - e' gia' stato validato a occhio sul
pannello vero.
]]
local ffi = require("ffi")
local bit = require("bit")
local font = require("font5x7")

local M = {}

local LcdStatus = {}
LcdStatus.__index = LcdStatus
M.LcdStatus = LcdStatus

local SCALE = 2  -- ingrandimento del testo (5x7 -> 10x14 px per carattere)
local CHAR_ADVANCE = (font.GLYPH_W + 1) * SCALE  -- +1 = spazio fra caratteri
local LINE_HEIGHT = (font.GLYPH_H + 2) * SCALE

-- -----------------------------------------------------------
-- pacchettizzazione RGB565 (vedi nota in testa al file sull'ordine byte)
-- -----------------------------------------------------------
local function set_pixel(buf, width, height, x, y, r, g, b)
    if x < 0 or y < 0 or x >= width or y >= height then return end
    local p = bit.bor(
        bit.lshift(bit.band(bit.rshift(r, 3), 0x1F), 11),
        bit.lshift(bit.band(bit.rshift(g, 2), 0x3F), 5),
        bit.band(bit.rshift(b, 3), 0x1F))
    local idx = (y * width + x) * 2
    buf[idx] = bit.band(p, 0xFF)
    buf[idx + 1] = bit.band(bit.rshift(p, 8), 0xFF)
end

local function fill_rect(buf, width, height, x0, y0, w, h, r, g, b)
    for y = y0, y0 + h - 1 do
        for x = x0, x0 + w - 1 do
            set_pixel(buf, width, height, x, y, r, g, b)
        end
    end
end

local function draw_char(buf, width, height, x0, y0, ch, r, g, b)
    local rows = font.GLYPHS[ch] or font.GLYPHS[" "]
    for gy = 0, font.GLYPH_H - 1 do
        local row = rows[gy + 1]
        for gx = 0, font.GLYPH_W - 1 do
            if row:byte(gx + 1) == string.byte("1") then
                fill_rect(buf, width, height, x0 + gx * SCALE, y0 + gy * SCALE, SCALE, SCALE, r, g, b)
            end
        end
    end
end

local function draw_text(buf, width, height, x0, y0, text, r, g, b)
    local x = x0
    for i = 1, #text do
        draw_char(buf, width, height, x, y0, text:sub(i, i):upper(), r, g, b)
        x = x + CHAR_ADVANCE
    end
end

-- -----------------------------------------------------------
-- LcdStatus:new(fb_path, bg_bin_path, width, height)
--
-- bg_bin_path: file RGB565 raw pre-convertito (tests/shinchan_to_bin.py)
-- - se manca, si parte da sfondo nero invece di fallire (l'LCD resta
-- comunque utile solo per le statistiche).
-- -----------------------------------------------------------
function M.new(fb_path, bg_bin_path, width, height)
    local self = setmetatable({}, LcdStatus)
    self.fb_path = fb_path
    self.width, self.height = width, height

    local n_bytes = width * height * 2
    self.bg = ffi.new("uint8_t[?]", n_bytes)
    if bg_bin_path then
        local f = io.open(bg_bin_path, "rb")
        if f then
            local data = f:read("*a")
            f:close()
            ffi.copy(self.bg, data, math.min(#data, n_bytes))
        end
    end

    self.frame = ffi.new("uint8_t[?]", n_bytes)
    self.frame_bytes = n_bytes
    return self
end

-- update(stats): stats = {
--   cpu_us_per_instr, ppu_ms, present_ms, gfx_bank, stage, fps
-- } - tutti opzionali, una riga viene disegnata solo se il relativo
-- campo e' presente
function LcdStatus:update(stats)
    ffi.copy(self.frame, self.bg, self.frame_bytes)

    local bar_h = LINE_HEIGHT * 5 + SCALE * 4
    local bar_y = self.height - bar_h
    fill_rect(self.frame, self.width, self.height, 0, bar_y, self.width, bar_h, 10, 10, 14)

    local y = bar_y + SCALE * 2
    local x = SCALE * 2
    local WHITE = { 235, 235, 235 }

    if stats.cpu_us_per_instr then
        draw_text(self.frame, self.width, self.height, x, y,
            string.format("CPU %.1fUS", stats.cpu_us_per_instr), WHITE[1], WHITE[2], WHITE[3])
        y = y + LINE_HEIGHT
    end
    if stats.ppu_ms then
        draw_text(self.frame, self.width, self.height, x, y,
            string.format("PPU %.2fMS", stats.ppu_ms), WHITE[1], WHITE[2], WHITE[3])
        y = y + LINE_HEIGHT
    end
    if stats.present_ms then
        draw_text(self.frame, self.width, self.height, x, y,
            string.format("GPU %.2fMS", stats.present_ms), WHITE[1], WHITE[2], WHITE[3])
        y = y + LINE_HEIGHT
    end
    if stats.gfx_bank ~= nil and stats.stage ~= nil then
        draw_text(self.frame, self.width, self.height, x, y,
            string.format("VRAM B%d S%d", stats.gfx_bank, stats.stage), WHITE[1], WHITE[2], WHITE[3])
        y = y + LINE_HEIGHT
    end
    if stats.fps then
        draw_text(self.frame, self.width, self.height, x, y,
            string.format("FPS %d", stats.fps), WHITE[1], WHITE[2], WHITE[3])
    end

    local f = io.open(self.fb_path, "wb")
    if f then
        f:write(ffi.string(self.frame, self.frame_bytes))
        f:close()
    end
end

-- lanciato direttamente (non richiesto come modulo): disegna una volta
-- con dati di esempio, utile per verificare il pannello senza dover
-- avviare tutto il motore -
--     luajit lcd_status.lua [fb_path] [bg_bin_path]
if arg and arg[0] and arg[0]:match("lcd_status%.lua$") then
    local fb_path = arg[1] or "/dev/fb0"
    local bg_path = arg[2] or "shinchan_565.bin"
    local panel = M.new(fb_path, bg_path, 480, 320)
    panel:update({ cpu_us_per_instr = 3.7, ppu_ms = 0.63, present_ms = 1.10, gfx_bank = 0, stage = 0, fps = 58 })
    print("Scritto un frame di prova su " .. fb_path)
end

return M
