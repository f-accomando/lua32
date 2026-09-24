--[[
test_input.lua - test di input.lua. Serve SDL video gia' inizializzato
(la tastiera in SDL2 e' legata al sottosistema video) - qui usiamo
video.lua stesso per farlo, driver 'dummy'.

Iniettiamo un evento SDL_QUIT SINTETICO per verificare che poll() lo
riconosca davvero (SDL_PushEvent mette l'evento nella coda per
davvero, SDL_PollEvent lo legge da li' - a differenza dello stato
tastiera di SDL_GetKeyboardState, che invece riflette solo eventi
hardware VERI e non e' simulabile da qui, per quello lo verifichiamo
solo come "nessun tasto premuto" di base, un controllo comunque
significativo che la funzione gira senza errori).

    SDL_VIDEODRIVER=dummy luajit tests/test_input.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local video = require("video")
local input = require("input")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local v = video.new("s32 - test input", 320, 224, false, 0)  -- renderer_flags=0: vedi test_video.lua

check("poll() senza eventi in coda: nessun quit", input.poll(), false)
check("input_byte() di base: nessun tasto premuto (0)", input.input_byte(), 0)

input.push_quit_event()
check("poll() dopo un QUIT sintetico iniettato: lo riconosce", input.poll(), true)

v:close()

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
