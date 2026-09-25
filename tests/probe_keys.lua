--[[
probe_keys.lua - stampa in tempo reale lo scancode SDL di ogni tasto
premuto (KEYDOWN), per diagnosticare "le frecce funzionano ma WASD no"
senza indovinare - dice esattamente cosa vede SDL2/KMSDRM per ogni
tasto fisico premuto sulla tastiera reale.

Layout di SDL_KeyboardEvent/SDL_Keysym verificato con un probe in C
contro l'header reale (SDL2/SDL.h), non dedotto a memoria - vedi
input.lua per lo stesso principio applicato a SDL_Event_Header.

Uso (sul Pi, tastiera reale collegata):
    SDL_VIDEODRIVER=kmsdrm luajit tests/probe_keys.lua
Premi tasti, guarda cosa stampa. CTRL+C per uscire (o ESC).
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("sdl_load")

ffi.cdef[[
typedef struct {
    uint32_t type;
    uint32_t timestamp;
    uint32_t windowID;
    uint8_t state;
    uint8_t repeat_;
    uint8_t padding2;
    uint8_t padding3;
    int32_t scancode;
    int32_t sym;
    uint16_t mod;
    uint32_t unused;
} SDL_KeyboardEvent_t;

typedef union {
    uint32_t type;
    SDL_KeyboardEvent_t key;
    uint8_t padding[56];
} SDL_Event_t;

int SDL_Init(uint32_t flags);
int SDL_PollEvent(void *event);
const char *SDL_GetScancodeName(int scancode);
int usleep(unsigned int usec);
]]

local SDL_INIT_VIDEO = 0x00000020
local SDL_KEYDOWN = 0x300
local SDL_QUIT = 0x100

if sdl.SDL_Init(SDL_INIT_VIDEO) ~= 0 then
    error("SDL_Init fallita")
end

print("In ascolto - premi tasti (CTRL+C per uscire)...")
local ev = ffi.new("SDL_Event_t")
local running = true
while running do
    while sdl.SDL_PollEvent(ev) ~= 0 do
        if ev.type == SDL_QUIT then
            running = false
        elseif ev.type == SDL_KEYDOWN then
            local name = ffi.string(sdl.SDL_GetScancodeName(ev.key.scancode))
            print(string.format("scancode=%d  nome=%s", ev.key.scancode, name))
        end
    end
    ffi.C.usleep(10000)
end
