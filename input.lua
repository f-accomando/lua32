--[[
input.lua - binding FFI diretti a SDL2 per la tastiera (nessun
framework, stessa famiglia di video.lua).

A differenza del vecchio motore Python su LCD SPI (dove serviva
leggere /dev/input direttamente con evdev perche' non c'era mai una
vera finestra con focus), qui la finestra SDL/KMSDRM E' reale - la
tastiera normale di SDL (SDL_PollEvent + SDL_GetKeyboardState) funziona
senza trucchi.

Produce un input_byte compatibile con cpu:run(start_pc, input_byte):
  bit0 = su, bit1 = giu', bit2 = sinistra, bit3 = destra, bit4 = azione
]]
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct {
    uint32_t type;
    uint8_t padding[52];  // il resto di SDL_Event non ci serve - lo
                            // ignoriamo, ma la union e' grande quanto
                            // il piu' grande dei suoi membri (56 byte
                            // su SDL2 64-bit) e va comunque riservato
                            // per intero perche' SDL_PollEvent scrive
                            // l'evento reale in questa memoria
} SDL_Event_Header;

int SDL_PollEvent(void *event);
int SDL_PushEvent(void *event);
const uint8_t *SDL_GetKeyboardState(int *numkeys);
]]

local sdl = require("sdl_load")

-- SDL_QUIT: valore verificato contro SDL_events.h (SDL_QUIT = 0x100,
-- primo evento della categoria "application events")
local SDL_QUIT = 0x100

-- scancode SDL (SDL_SCANCODE_*, layout indipendenti - non i keycode,
-- verificati contro SDL_scancode.h)
local SDL_SCANCODE_UP = 82
local SDL_SCANCODE_DOWN = 81
local SDL_SCANCODE_LEFT = 80
local SDL_SCANCODE_RIGHT = 79
local SDL_SCANCODE_W = 26
local SDL_SCANCODE_A = 4
local SDL_SCANCODE_S = 22
local SDL_SCANCODE_D = 7
local SDL_SCANCODE_SPACE = 44
local SDL_SCANCODE_J = 13
local SDL_SCANCODE_ESCAPE = 41

local M = {}

-- event_buf: buffer grezzo riusato ad ogni chiamata di poll() - evita
-- di allocare un nuovo cdata a ogni evento (potenzialmente molti per
-- frame)
local event_buf = ffi.new("SDL_Event_Header")

-- poll(): svuota la coda eventi SDL (necessario perche' SDL li accodi
-- comunque anche se non ci interessano - altrimenti la coda cresce
-- senza limite) e ritorna true se e' arrivato un QUIT (finestra chiusa)
function M.poll()
    local quit = false
    while sdl.SDL_PollEvent(event_buf) ~= 0 do
        if event_buf.type == SDL_QUIT then
            quit = true
        end
    end
    return quit
end

-- input_byte(): stato ATTUALE della tastiera (non eventi) - piu'
-- adatto a un gioco in tempo reale (tasto tenuto premuto) che una
-- coda di eventi discreti
function M.input_byte()
    local keys = sdl.SDL_GetKeyboardState(nil)
    local b = 0
    if keys[SDL_SCANCODE_UP] ~= 0 or keys[SDL_SCANCODE_W] ~= 0 then b = bit.bor(b, 0x01) end
    if keys[SDL_SCANCODE_DOWN] ~= 0 or keys[SDL_SCANCODE_S] ~= 0 then b = bit.bor(b, 0x02) end
    if keys[SDL_SCANCODE_LEFT] ~= 0 or keys[SDL_SCANCODE_A] ~= 0 then b = bit.bor(b, 0x04) end
    if keys[SDL_SCANCODE_RIGHT] ~= 0 or keys[SDL_SCANCODE_D] ~= 0 then b = bit.bor(b, 0x08) end
    if keys[SDL_SCANCODE_SPACE] ~= 0 or keys[SDL_SCANCODE_J] ~= 0 then b = bit.bor(b, 0x10) end
    return b
end

function M.menu_button_pressed()
    local keys = sdl.SDL_GetKeyboardState(nil)
    return keys[SDL_SCANCODE_ESCAPE] ~= 0
end

-- push_quit_event(): inietta un evento SDL_QUIT sintetico nella coda -
-- usato solo dai test (tests/test_input.lua) per verificare che
-- poll() lo riconosca davvero, senza dover chiudere una finestra vera
function M.push_quit_event()
    local ev = ffi.new("SDL_Event_Header")
    ev.type = SDL_QUIT
    sdl.SDL_PushEvent(ev)
end

return M
