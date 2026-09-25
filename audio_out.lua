--[[
audio_out.lua - uscita audio via SDL2 (stessa libreria di video.lua/
input.lua, nessuna dipendenza nuova) verso ALSA/HDMI.

Modello a CODA (SDL_QueueAudio), non a callback: SDL normalmente
invocherebbe un callback su un thread audio separato ogni volta che
serve altro audio - ma quel callback dovrebbe leggere gli stessi
registri APU (cpu.mem) che la CPU scrive dal thread principale, una
corsa critica reale da evitare. Con la coda, i campioni si generano
nello stesso game loop single-thread di sempre (apu:generate() chiamato
una volta per frame, poi accodato) - zero problemi di concorrenza,
stessa filosofia sincrona di tutto il resto del motore.

Layout di SDL_AudioSpec dichiarato come vero struct C (non offset
calcolati a mano): lascia che sia LuaJIT a calcolare l'allineamento
giusto per l'architettura reale (i puntatori sono 4 byte su ARM32 del
Pi, 8 byte nella sandbox x86_64 - un offset fisso scritto a mano
sarebbe stato sbagliato su una delle due). Costanti (SDL_INIT_AUDIO,
AUDIO_S16SYS) verificate con un probe in C contro l'header reale,
stesso principio di video.lua.
]]
local ffi = require("ffi")
local sdl = require("sdl_load")

ffi.cdef[[
typedef void (*s32_audio_callback_t)(void *userdata, uint8_t *stream, int len);
typedef struct {
    int freq;
    uint16_t format;
    uint8_t channels;
    uint8_t silence;
    uint16_t samples;
    uint16_t padding;
    uint32_t size;
    s32_audio_callback_t callback;
    void *userdata;
} s32_SDL_AudioSpec;

int SDL_Init(uint32_t flags);
const char *SDL_GetError(void);
uint32_t SDL_OpenAudioDevice(const char *device, int iscapture,
    const s32_SDL_AudioSpec *desired, s32_SDL_AudioSpec *obtained, int allowed_changes);
void SDL_PauseAudioDevice(uint32_t dev, int pause_on);
int SDL_QueueAudio(uint32_t dev, const void *data, uint32_t len);
uint32_t SDL_GetQueuedAudioSize(uint32_t dev);
void SDL_ClearQueuedAudio(uint32_t dev);
void SDL_CloseAudioDevice(uint32_t dev);
]]

-- SDL_INIT_AUDIO=0x10, AUDIO_S16SYS=0x8010 (= AUDIO_S16LSB sia su ARM
-- che x86, entrambi little-endian) - verificati con probe in C contro
-- SDL2/SDL.h e SDL2/SDL_audio.h reali, non dedotti a memoria
local SDL_INIT_AUDIO = 0x10
local AUDIO_S16SYS = 0x8010

local M = {}

local AudioOut = {}
AudioOut.__index = AudioOut
M.AudioOut = AudioOut

-- MAX_QUEUED_MS: quanto audio si puo' accumulare in coda prima che
-- nuovi blocchi vengano scartati invece che accodati - se il game loop
-- rallenta, meglio un piccolo drop-out (impercettibile) che lasciar
-- crescere la latenza audio senza limite
local MAX_QUEUED_MS = 100

-- M.new(sample_rate, buffer_samples) - buffer_samples e' la dimensione
-- del buffer interno di SDL (non quanto generiamo per frame, quello lo
-- decide chi chiama :queue()) - 1024 e' un default ragionevole
function M.new(sample_rate, buffer_samples)
    sample_rate = sample_rate or 22050
    if sdl.SDL_Init(SDL_INIT_AUDIO) ~= 0 then
        error("SDL_Init(AUDIO) fallita: " .. ffi.string(sdl.SDL_GetError()))
    end

    local desired = ffi.new("s32_SDL_AudioSpec")
    desired.freq = sample_rate
    desired.format = AUDIO_S16SYS
    desired.channels = 1  -- mono, come apu:generate()
    desired.samples = buffer_samples or 1024
    desired.callback = nil  -- NULL: modello a coda, vedi nota in testa al file

    local obtained = ffi.new("s32_SDL_AudioSpec")
    local dev = sdl.SDL_OpenAudioDevice(nil, 0, desired, obtained, 0)
    if dev == 0 then
        error("SDL_OpenAudioDevice fallita: " .. ffi.string(sdl.SDL_GetError()))
    end
    sdl.SDL_PauseAudioDevice(dev, 0)  -- SDL apre il device in pausa di default

    local self = setmetatable({}, AudioOut)
    self.dev = dev
    self.sample_rate = tonumber(obtained.freq)
    self.channels = tonumber(obtained.channels)
    return self
end

-- queue(buf, n_samples): buf e' un int16_t[n_samples] (mono) prodotto
-- da apu:generate() - lo accoda per la riproduzione
function AudioOut:queue(buf, n_samples)
    local max_bytes = self.sample_rate * MAX_QUEUED_MS / 1000 * 2  -- 2 byte/campione (int16)
    if sdl.SDL_GetQueuedAudioSize(self.dev) > max_bytes then
        return false  -- troppo in ritardo: salta questo blocco invece di accumulare latenza
    end
    sdl.SDL_QueueAudio(self.dev, buf, n_samples * 2)
    return true
end

function AudioOut:queued_ms()
    return sdl.SDL_GetQueuedAudioSize(self.dev) / 2 / self.sample_rate * 1000
end

function AudioOut:close()
    sdl.SDL_CloseAudioDevice(self.dev)
end

return M
