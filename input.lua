--[[
input.lua - binding FFI diretti a SDL2 per tastiera E controller
(nessun framework, stessa famiglia di video.lua).

A differenza del vecchio motore Python su LCD SPI (dove serviva
leggere /dev/input direttamente con evdev perche' non c'era mai una
vera finestra con focus), qui la finestra SDL/KMSDRM E' reale - la
tastiera normale di SDL (SDL_PollEvent + SDL_GetKeyboardState) funziona
senza trucchi.

Controller: usa l'API SDL_GameController, non il joystick grezzo -
SDL2 include gia' un database di mappature per i controller comuni
(PS4/PS5, Xbox...) e li normalizza tutti allo stesso layout astratto
(bottone "A" = Cross su PS4, "B" = Circle, ecc.) - non serve gestire
PS4 diversamente da un pad Xbox, SDL se ne occupa da solo.

Produce un input_byte compatibile con cpu:run(start_pc, input_byte):
  bit0 = su, bit1 = giu', bit2 = sinistra, bit3 = destra, bit4 = azione
Tastiera e controller sono in OR fra loro - qualunque dei due funziona,
non serve scegliere quale usare.
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

int SDL_Init(uint32_t flags);
int SDL_PollEvent(void *event);
int SDL_PushEvent(void *event);
const uint8_t *SDL_GetKeyboardState(int *numkeys);

int SDL_NumJoysticks(void);
int SDL_IsGameController(int joystick_index);
typedef struct SDL_GameController SDL_GameController;
SDL_GameController *SDL_GameControllerOpen(int joystick_index);
void SDL_GameControllerClose(SDL_GameController *gamecontroller);
uint8_t SDL_GameControllerGetButton(SDL_GameController *gamecontroller, int button);
const char *SDL_GameControllerName(SDL_GameController *gamecontroller);
]]

local sdl = require("sdl_load")

-- SDL_INIT_GAMECONTROLLER=0x2000, SDL_QUIT=0x100,
-- SDL_CONTROLLERDEVICEADDED/REMOVED - verificati con probe in C contro
-- SDL2/SDL.h e SDL2/SDL_gamecontroller.h reali, non a memoria
local SDL_INIT_GAMECONTROLLER = 0x2000
local SDL_QUIT = 0x100
local SDL_CONTROLLERDEVICEADDED = 0x653
local SDL_CONTROLLERDEVICEREMOVED = 0x654

-- bottoni SDL_GameController (layout astratto, gia' normalizzato da
-- SDL indipendentemente dal controller fisico) - verificati con lo
-- stesso probe
local BTN_DPAD_UP = 11
local BTN_DPAD_DOWN = 12
local BTN_DPAD_LEFT = 13
local BTN_DPAD_RIGHT = 14
local BTN_A = 0        -- Cross su PS4, A su Xbox - il "conferma/azione" universale
local BTN_B = 1        -- Circle su PS4
local BTN_X = 2        -- Square su PS4 (occhio: "X" di SDL e "X" fisico su PS4 NON coincidono)
local BTN_Y = 3        -- Triangle su PS4
local BTN_START = 6    -- Options su PS4 - usato come pulsante menu
local BTN_LEFTSHOULDER = 9
local BTN_RIGHTSHOULDER = 10

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

sdl.SDL_Init(SDL_INIT_GAMECONTROLLER)

-- controller attualmente aperto (nil se nessuno collegato) - un solo
-- giocatore per ora, coerente col demo attuale (main.lua legge un solo
-- input_byte); piu' controller per il multiplayer locale sono
-- un'estensione naturale quando servira' davvero
local controller = nil

local function try_open_first_controller()
    if controller then return end
    for i = 0, sdl.SDL_NumJoysticks() - 1 do
        if sdl.SDL_IsGameController(i) ~= 0 then
            controller = sdl.SDL_GameControllerOpen(i)
            if controller ~= nil then
                print("s32: controller collegato - " .. ffi.string(sdl.SDL_GameControllerName(controller)))
                return
            end
        end
    end
end
try_open_first_controller()  -- se e' gia' collegato all'avvio

-- controller_button_state(): stato di TUTTI i bottoni interessanti,
-- non solo i 5 gia' collassati in input_byte() - serve per
-- visualizzare cosa viene premuto (vedi lcd_status.lua "controller").
-- Etichette per il simbolo FISICO stampato sul pad PS4 (X/O/S/T), non
-- per il nome astratto di SDL - occhio: SDL_CONTROLLER_BUTTON_X (2)
-- e' il tasto Square su PS4, NON il simbolo "X" (quello e' BUTTON_A) -
-- una collisione di nomi facile da sbagliare, vedi commenti sopra.
-- Ritorna nil se nessun controller e' collegato.
function M.controller_button_state()
    if not controller then return nil end
    local g = sdl.SDL_GameControllerGetButton
    return {
        up = g(controller, BTN_DPAD_UP) ~= 0,
        down = g(controller, BTN_DPAD_DOWN) ~= 0,
        left = g(controller, BTN_DPAD_LEFT) ~= 0,
        right = g(controller, BTN_DPAD_RIGHT) ~= 0,
        x = g(controller, BTN_A) ~= 0,       -- Cross
        o = g(controller, BTN_B) ~= 0,       -- Circle
        square = g(controller, BTN_X) ~= 0,  -- Square (SDL "X" fisico diverso!)
        triangle = g(controller, BTN_Y) ~= 0,
        l1 = g(controller, BTN_LEFTSHOULDER) ~= 0,
        r1 = g(controller, BTN_RIGHTSHOULDER) ~= 0,
    }
end

-- event_buf: buffer grezzo riusato ad ogni chiamata di poll() - evita
-- di allocare un nuovo cdata a ogni evento (potenzialmente molti per
-- frame)
local event_buf = ffi.new("SDL_Event_Header")

-- poll(): svuota la coda eventi SDL (necessario perche' SDL li accodi
-- comunque anche se non ci interessano - altrimenti la coda cresce
-- senza limite), ritorna true se e' arrivato un QUIT (finestra chiusa).
-- Intercetta anche i collegamenti/scollegamenti di controller a caldo -
-- non serve riavviare per farlo riconoscere durante una sessione.
function M.poll()
    local quit = false
    while sdl.SDL_PollEvent(event_buf) ~= 0 do
        if event_buf.type == SDL_QUIT then
            quit = true
        elseif event_buf.type == SDL_CONTROLLERDEVICEADDED then
            try_open_first_controller()
        elseif event_buf.type == SDL_CONTROLLERDEVICEREMOVED then
            if controller then
                sdl.SDL_GameControllerClose(controller)
                controller = nil
                try_open_first_controller()  -- nel caso ce ne sia un altro rimasto
            end
        end
    end
    return quit
end

function M.controller_connected()
    return controller ~= nil
end

-- input_byte(): stato ATTUALE di tastiera + controller (non eventi) -
-- piu' adatto a un gioco in tempo reale (tasto/bottone tenuto premuto)
-- che una coda di eventi discreti. Tastiera e controller in OR: va
-- bene indifferentemente l'uno o l'altro.
function M.input_byte()
    local keys = sdl.SDL_GetKeyboardState(nil)
    local b = 0
    if keys[SDL_SCANCODE_UP] ~= 0 or keys[SDL_SCANCODE_W] ~= 0 then b = bit.bor(b, 0x01) end
    if keys[SDL_SCANCODE_DOWN] ~= 0 or keys[SDL_SCANCODE_S] ~= 0 then b = bit.bor(b, 0x02) end
    if keys[SDL_SCANCODE_LEFT] ~= 0 or keys[SDL_SCANCODE_A] ~= 0 then b = bit.bor(b, 0x04) end
    if keys[SDL_SCANCODE_RIGHT] ~= 0 or keys[SDL_SCANCODE_D] ~= 0 then b = bit.bor(b, 0x08) end
    if keys[SDL_SCANCODE_SPACE] ~= 0 or keys[SDL_SCANCODE_J] ~= 0 then b = bit.bor(b, 0x10) end

    if controller then
        if sdl.SDL_GameControllerGetButton(controller, BTN_DPAD_UP) ~= 0 then b = bit.bor(b, 0x01) end
        if sdl.SDL_GameControllerGetButton(controller, BTN_DPAD_DOWN) ~= 0 then b = bit.bor(b, 0x02) end
        if sdl.SDL_GameControllerGetButton(controller, BTN_DPAD_LEFT) ~= 0 then b = bit.bor(b, 0x04) end
        if sdl.SDL_GameControllerGetButton(controller, BTN_DPAD_RIGHT) ~= 0 then b = bit.bor(b, 0x08) end
        if sdl.SDL_GameControllerGetButton(controller, BTN_A) ~= 0 then b = bit.bor(b, 0x10) end
    end

    return b
end

function M.menu_button_pressed()
    local keys = sdl.SDL_GetKeyboardState(nil)
    if keys[SDL_SCANCODE_ESCAPE] ~= 0 then return true end
    if controller and sdl.SDL_GameControllerGetButton(controller, BTN_START) ~= 0 then return true end
    return false
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
