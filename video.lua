--[[
video.lua - binding FFI diretti a SDL2 per l'output video (nessun
framework, vedi docs/design.md "Libreria grafica/input/audio").

Prende il buffer RGB888 che produce ppu.lua (render_frame) e lo porta
a schermo via una texture GPU (SDL_Renderer accelerato) - stesso
principio del GpuRenderer del vecchio motore Python: aggiorna la
texture, poi un blit accelerato, non un Surface software.

Nessun letterbox: SDL_RenderSetLogicalSize fa scalare automaticamente
la risoluzione nativa della console a riempire la finestra/schermo
intero (vedi docs/design.md "Video" - con la GPU la scala e' gratis).

Le costanti SDL2 qui sotto sono state VERIFICATE contro l'header reale
(SDL2/SDL.h) con un piccolo probe in C, non tratte a memoria - vedi il
commento su ciascuna.
]]
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef[[
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;

int SDL_Init(uint32_t flags);
void SDL_Quit(void);
const char *SDL_GetError(void);

SDL_Window *SDL_CreateWindow(const char *title, int x, int y, int w, int h, uint32_t flags);
void SDL_DestroyWindow(SDL_Window *window);

SDL_Renderer *SDL_CreateRenderer(SDL_Window *window, int index, uint32_t flags);
void SDL_DestroyRenderer(SDL_Renderer *renderer);
int SDL_RenderSetLogicalSize(SDL_Renderer *renderer, int w, int h);
int SDL_RenderClear(SDL_Renderer *renderer);
int SDL_RenderCopy(SDL_Renderer *renderer, SDL_Texture *texture, const void *srcrect, const void *dstrect);
void SDL_RenderPresent(SDL_Renderer *renderer);

SDL_Texture *SDL_CreateTexture(SDL_Renderer *renderer, uint32_t format, int access, int w, int h);
void SDL_DestroyTexture(SDL_Texture *texture);
int SDL_UpdateTexture(SDL_Texture *texture, const void *rect, const void *pixels, int pitch);

int SDL_ShowCursor(int toggle);
]]

-- SDL2 non e' gia' linkata nel processo (a differenza delle funzioni
-- della libc, sempre in ffi.C) - va caricata esplicitamente. Vedi
-- sdl_load.lua per il perche' non basta ffi.load("SDL2") sul target
-- reale (solo pacchetto runtime, niente -dev).
local sdl = require("sdl_load")

-- valori verificati con un probe in C contro SDL2/SDL.h vero (vedi
-- docstring sopra) - MAI dedotti a mano dalla sola documentazione,
-- perche' SDL_PIXELFORMAT_* in particolare e' un valore impacchettato
-- a bit che e' facilissimo sbagliare "a occhio"
local SDL_INIT_VIDEO = 0x00000020
local SDL_WINDOW_SHOWN = 0x00000004
local SDL_WINDOW_FULLSCREEN_DESKTOP = 0x00001001  -- SDL_WINDOW_FULLSCREEN(0x1) | 0x1000
local SDL_RENDERER_ACCELERATED = 0x00000002
local SDL_TEXTUREACCESS_STREAMING = 0x00000001
local SDL_WINDOWPOS_UNDEFINED = 0x1FFF0000
local SDL_PIXELFORMAT_RGB24 = 0x17101803  -- ARRAYU8/RGB/24bit/3byte -
                                            -- stesso ordine byte del
                                            -- buffer che produce
                                            -- ppu.render_frame()
local SDL_DISABLE = 0  -- per SDL_ShowCursor: valore da SDL_events.h,
                        -- non specifico di KMSDRM/accelerazione

local M = {}

local Video = {}
Video.__index = Video
M.Video = Video

-- Video.new(title, native_w, native_h, fullscreen, renderer_flags) -
-- native_w/h sono la risoluzione LOGICA della console (es. 320x224),
-- non quella dello schermo fisico - SDL scala automaticamente (vedi
-- SDL_RenderSetLogicalSize sotto). renderer_flags e' opzionale (default
-- SDL_RENDERER_ACCELERATED, quello vero su hardware con GPU/KMSDRM) -
-- esposto solo per i test di fumo, dove il driver SDL 'dummy' (nessun
-- display reale) non offre alcun renderer accelerato.
function M.new(title, native_w, native_h, fullscreen, renderer_flags)
    renderer_flags = renderer_flags or SDL_RENDERER_ACCELERATED
    if sdl.SDL_Init(SDL_INIT_VIDEO) ~= 0 then
        error("SDL_Init fallita: " .. ffi.string(sdl.SDL_GetError()))
    end
    sdl.SDL_ShowCursor(SDL_DISABLE)  -- niente cursore del mouse su una
                                      -- console senza mouse (visibile
                                      -- di default, SDL non lo nasconde
                                      -- da solo sotto KMSDRM)

    local window_flags = SDL_WINDOW_SHOWN
    if fullscreen then
        window_flags = bit.bor(window_flags, SDL_WINDOW_FULLSCREEN_DESKTOP)
    end
    local window = sdl.SDL_CreateWindow(title, SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                                          native_w, native_h, window_flags)
    if window == nil then
        error("SDL_CreateWindow fallita: " .. ffi.string(sdl.SDL_GetError()))
    end

    local renderer = sdl.SDL_CreateRenderer(window, -1, renderer_flags)
    if renderer == nil then
        sdl.SDL_DestroyWindow(window)
        error("SDL_CreateRenderer fallita: " .. ffi.string(sdl.SDL_GetError()))
    end
    sdl.SDL_RenderSetLogicalSize(renderer, native_w, native_h)

    local texture = sdl.SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24, SDL_TEXTUREACCESS_STREAMING,
                                            native_w, native_h)
    if texture == nil then
        sdl.SDL_DestroyRenderer(renderer)
        sdl.SDL_DestroyWindow(window)
        error("SDL_CreateTexture fallita: " .. ffi.string(sdl.SDL_GetError()))
    end

    local self = setmetatable({}, Video)
    self.window = window
    self.renderer = renderer
    self.texture = texture
    self.w = native_w
    self.h = native_h
    self.pitch = native_w * 3  -- RGB24: 3 byte/pixel, nessun padding di riga
    return self
end

-- present(buf): buf e' un uint8_t[w*h*3] RGB888 - lo stesso formato
-- prodotto da ppu.render_frame()
function Video:present(buf)
    sdl.SDL_UpdateTexture(self.texture, nil, buf, self.pitch)
    sdl.SDL_RenderClear(self.renderer)
    sdl.SDL_RenderCopy(self.renderer, self.texture, nil, nil)
    sdl.SDL_RenderPresent(self.renderer)
end

function Video:close()
    sdl.SDL_DestroyTexture(self.texture)
    sdl.SDL_DestroyRenderer(self.renderer)
    sdl.SDL_DestroyWindow(self.window)
    sdl.SDL_Quit()
end

return M
