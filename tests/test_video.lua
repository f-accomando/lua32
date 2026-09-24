--[[
test_video.lua - test di fumo per video.lua: crea finestra/renderer/
texture, presenta un frame vero prodotto da ppu.lua, chiude - verifica
che l'intera catena FFI non vada in crash.

NON verifica che appaia qualcosa di visibile (serve un vero schermo/
HDMI per quello, vedi README per come testarlo sul Raspberry Pi) - qui
usiamo il driver 'dummy' di SDL, pensato apposta per girare senza
display reale.

    SDL_VIDEODRIVER=dummy luajit tests/test_video.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local ppu = require("ppu")
local video = require("video")

local fails = 0
local function check(label, ok)
    if not ok then fails = fails + 1 end
    print(string.format("%s %s", ok and "OK  " or "FAIL", label))
end

local ok, err = pcall(function()
    -- renderer_flags=0 (nessun ACCELERATED richiesto): il driver SDL
    -- 'dummy' usato in questo test di fumo non ha alcun renderer
    -- accelerato (niente GPU vera in questo ambiente) - sul target
    -- vero (Raspberry Pi, KMSDRM) video.new() si chiama SENZA questo
    -- parametro, cosi' usa ACCELERATED di default.
    local v = video.new("s32 - test", 320, 224, false, 0)
    check("finestra/renderer/texture create senza errori", true)

    -- un frame vero: un rettangolo di sfondo tinta unita, cosi' se
    -- mai lo si guarda su un vero schermo si vede qualcosa di
    -- riconoscibile invece di rumore
    local mem = ffi.new("uint8_t[?]", mm.ADDRESS_SPACE)
    ppu.set_color(mem, 0, 1, 0, 120, 200)
    local grid = {}
    for i = 1, 64 do grid[i] = 1 end
    ppu.set_directory_entry(mem, 1, 0, 0)  -- tile 8x8 (size_class 0), offset 0
    for y = 0, 7 do
        for x = 0, 7 do
            mem[mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET + y * 8 + x] = 1
        end
    end
    local word = ppu.encode_tile_descriptor(1, 0)
    for cy = 0, 27 do
        for cx = 0, 39 do
            local addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET + (cy * mm.TILEMAP_W + cx) * mm.TILEMAP_ENTRY_BYTES
            mem[addr] = word % 256
            mem[addr + 1] = math.floor(word / 256) % 256
        end
    end

    local buf = ppu.render_frame(mem, 0, 0, 320, 224)
    v:present(buf)
    check("present() di un frame vero senza errori", true)

    v:close()
    check("close() senza errori", true)
end)

check("nessuna eccezione lungo tutta la catena FFI", ok)
if not ok then print("errore: " .. tostring(err)) end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
