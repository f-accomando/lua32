--[[
s32_os_ui.lua - disegno dei pannelli dell'OS (cart-picker, pausa,
conferma cambio cartuccia) su un buffer RGB888 piatto, esattamente
nello stesso modo in cui lcd_status.lua disegna il pannello diagnostico
sull'LCD SPI (fill_rect + font bitmap) - non passa dalla PPU/VRAM della
console: l'OS non e' un "gioco" che gira sull'hardware emulato, e'
l'host che decide cosa mostrare prima ancora che una cartuccia sia
caricata. Il buffer prodotto va passato diretto a video:present(),
stesso formato di ppu.render_frame() (RGB888, w*h*3 byte).

Icona cartuccia: rettangolo con l'angolo in basso a sinistra tagliato a
scalini (richiama la forma di una scheda SD) - vedi design.md "Icona
cartuccia nell'OS": e' solo la forma dell'asset grafico nell'interfaccia,
nessun significato hardware.
]]
local ffi = require("ffi")
local font = require("font8x8")

local M = {}

-- SCALE=1 (8px/carattere): a SCALE=2 (16px/carattere) una frase corta
-- come "demo verra' chiuso." (20 caratteri) sfora gia' i 320px di
-- larghezza schermo (18px/carattere x 20 = 360px) - scoperto
-- renderizzando e guardando l'immagine, non a occhio. SCALE=2 resta
-- disponibile per titoli brevi se servisse in futuro.
local SCALE = 1
local CHAR_ADVANCE = (font.GLYPH_W + 1) * SCALE
local LINE_ADVANCE = (font.GLYPH_H + 2) * SCALE  -- altezza riga + interlinea

local COLOR_BG = { 12, 12, 18 }
local COLOR_TEXT = { 230, 230, 235 }
local COLOR_TEXT_DIM = { 120, 120, 130 }
local COLOR_ICON = { 60, 90, 150 }
local COLOR_ICON_DEV = { 150, 100, 40 }
local COLOR_SELECTED_BORDER = { 250, 220, 60 }
local COLOR_DIALOG_BG = { 30, 20, 20 }
local COLOR_DIALOG_BORDER = { 220, 80, 70 }

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function fill_rect(buf, w, h, x0, y0, rw, rh, r, g, b)
    local x1 = clamp(x0 + rw, 0, w)
    local y1 = clamp(y0 + rh, 0, h)
    x0 = clamp(x0, 0, w)
    y0 = clamp(y0, 0, h)
    for y = y0, y1 - 1 do
        local row = y * w * 3
        for x = x0, x1 - 1 do
            local i = row + x * 3
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b
        end
    end
end

-- rettangolo con l'angolo in basso a sinistra tagliato a scalini
-- (notch = quanti pixel di taglio massimo, proporzionale alla taglia)
local function draw_cart_icon(buf, w, h, x0, y0, size, r, g, b)
    local notch = math.floor(size * 0.3)
    for row = 0, size - 1 do
        if row < size - notch then
            fill_rect(buf, w, h, x0, y0 + row, size, 1, r, g, b)
        else
            local cut = row - (size - notch) + 1
            fill_rect(buf, w, h, x0 + cut, y0 + row, size - cut, 1, r, g, b)
        end
    end
end

local function draw_char(buf, w, h, x0, y0, ch, r, g, b)
    local rows = font.GLYPHS[ch] or font.GLYPHS[" "]
    for gy = 0, font.GLYPH_H - 1 do
        local row = rows[gy + 1]
        for gx = 0, font.GLYPH_W - 1 do
            if row:byte(gx + 1) == string.byte("1") then
                fill_rect(buf, w, h, x0 + gx * SCALE, y0 + gy * SCALE, SCALE, SCALE, r, g, b)
            end
        end
    end
end

-- draw_text: NON forza maiuscolo (a differenza di lcd_status.lua) -
-- font8x8 ha davvero le minuscole, e' il motivo per cui esiste.
local function draw_text(buf, w, h, x0, y0, text, r, g, b)
    local x = x0
    for i = 1, #text do
        draw_char(buf, w, h, x, y0, text:sub(i, i), r, g, b)
        x = x + CHAR_ADVANCE
    end
end

-- text_width(text): larghezza in pixel a schermo, utile per centrare
local function text_width(text)
    return #text * CHAR_ADVANCE - SCALE  -- l'ultimo carattere non ha il gap dopo
end

M.SCALE = SCALE
M.draw_text = draw_text
M.text_width = text_width
M.fill_rect = fill_rect

-- -----------------------------------------------------------
-- griglia del cart-picker
-- -----------------------------------------------------------
local ICON_SIZE = 56
local CELL_W, CELL_H = 72, 84  -- icona + margine + una riga di testo sotto
local GRID_X0, GRID_Y0 = 16, 16

-- grid_cols(w): quante colonne stanno nella larghezza w - unica fonte
-- di verita' condivisa con s32_os.lua (Session:move usa lo stesso
-- numero di colonne del rendering, altrimenti il cursore disegnato e
-- quello mosso dalla logica potrebbero disallinearsi)
function M.grid_cols(w)
    return math.max(1, math.floor((w - GRID_X0) / CELL_W))
end

local COLOR_PAUSED_MARK = { 90, 220, 120 }

-- render_picker(buf, w, h, entries, selected_index, dev_mode, paused_entry):
-- entries e' M.list_entries() di s32_os.lua ({name=, kind="play"|"dev", ...}).
-- selected_index e' 1-based (convenzione Lua, coerente col resto del
-- codice - non 0-based come i registri della CPU emulata). paused_entry
-- (opzionale) e' la cartuccia congelata in RAM (session.paused di
-- s32_os.lua) - se combacia con una voce, la segna con un "*" verde:
-- niente schermata di pausa separata, ESC porta DIRETTO qui (decisione
-- dell'utente - vedi s32_os.lua Session), quindi il picker stesso deve
-- far vedere quale cartuccia riprenderebbe selezionandola di nuovo.
function M.render_picker(buf, w, h, entries, selected_index, dev_mode, paused_entry)
    fill_rect(buf, w, h, 0, 0, w, h, COLOR_BG[1], COLOR_BG[2], COLOR_BG[3])

    local title = dev_mode and "S32 - CARTUCCE (DEV-MODE)" or "S32 - CARTUCCE"
    draw_text(buf, w, h, GRID_X0, 4, title, COLOR_TEXT[1], COLOR_TEXT[2], COLOR_TEXT[3])

    local cols = M.grid_cols(w)

    if #entries == 0 then
        draw_text(buf, w, h, GRID_X0, 40, "nessuna cartuccia in cart/", COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3])
        return
    end

    for i, entry in ipairs(entries) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local cx = GRID_X0 + col * CELL_W
        local cy = GRID_Y0 + 20 + row * CELL_H

        local icon_color = entry.kind == "dev" and COLOR_ICON_DEV or COLOR_ICON
        draw_cart_icon(buf, w, h, cx, cy, ICON_SIZE, icon_color[1], icon_color[2], icon_color[3])

        if i == selected_index then
            -- cornice di selezione: 4 bordi sottili appena fuori dall'icona
            local bx, by, bs = cx - 3, cy - 3, ICON_SIZE + 6
            local bc = COLOR_SELECTED_BORDER
            fill_rect(buf, w, h, bx, by, bs, 2, bc[1], bc[2], bc[3])
            fill_rect(buf, w, h, bx, by + bs - 2, bs, 2, bc[1], bc[2], bc[3])
            fill_rect(buf, w, h, bx, by, 2, bs, bc[1], bc[2], bc[3])
            fill_rect(buf, w, h, bx + bs - 2, by, 2, bs, bc[1], bc[2], bc[3])
        end

        local is_paused = paused_entry and paused_entry.name == entry.name and paused_entry.kind == entry.kind
        -- nome troncato se piu' largo della cella (meglio tagliato che
        -- sovrapposto alla cartuccia successiva) - il marcatore "*" di
        -- pausa conta come un carattere, va tolto dallo spazio disponibile
        local max_chars = math.floor((CELL_W - 4) / CHAR_ADVANCE) - (is_paused and 1 or 0)
        local label = entry.name
        if #label > max_chars then label = label:sub(1, math.max(1, max_chars - 1)) .. "." end
        if is_paused then label = "*" .. label end
        local tc = is_paused and COLOR_PAUSED_MARK or (i == selected_index and COLOR_TEXT or COLOR_TEXT_DIM)
        draw_text(buf, w, h, cx, cy + ICON_SIZE + 4, label, tc[1], tc[2], tc[3])
    end

    local hint = paused_entry and "INVIO:avvia ESC:riprendi/esci" or "INVIO: avvia   ESC: esci"
    draw_text(buf, w, h, GRID_X0, h - font.GLYPH_H * SCALE - 4, hint, COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3])
end

-- -----------------------------------------------------------
-- dialogo di conferma: si sovrappone al picker quando si sceglie una
-- cartuccia diversa da quella in pausa (vedi s32_os.lua, stato
-- "confirm_switch")
-- -----------------------------------------------------------
function M.render_confirm_dialog(buf, w, h, paused_name, new_name)
    local panel_w = 220
    local panel_h = 10 + LINE_ADVANCE * 3 + 6
    local px, py = math.floor((w - panel_w) / 2), math.floor((h - panel_h) / 2)
    fill_rect(buf, w, h, px, py, panel_w, panel_h, COLOR_DIALOG_BG[1], COLOR_DIALOG_BG[2], COLOR_DIALOG_BG[3])
    fill_rect(buf, w, h, px, py, panel_w, 2, COLOR_DIALOG_BORDER[1], COLOR_DIALOG_BORDER[2], COLOR_DIALOG_BORDER[3])
    fill_rect(buf, w, h, px, py + panel_h - 2, panel_w, 2, COLOR_DIALOG_BORDER[1], COLOR_DIALOG_BORDER[2], COLOR_DIALOG_BORDER[3])

    local line1 = paused_name .. " verra' chiuso."
    draw_text(buf, w, h, px + 8, py + 6, line1, COLOR_TEXT[1], COLOR_TEXT[2], COLOR_TEXT[3])
    local line2 = "aprire " .. new_name .. "?"
    draw_text(buf, w, h, px + 8, py + 6 + LINE_ADVANCE, line2, COLOR_TEXT[1], COLOR_TEXT[2], COLOR_TEXT[3])
    draw_text(buf, w, h, px + 8, py + 6 + LINE_ADVANCE * 2, "INVIO: ok   ESC: annulla",
        COLOR_TEXT_DIM[1], COLOR_TEXT_DIM[2], COLOR_TEXT_DIM[3])
end

return M
