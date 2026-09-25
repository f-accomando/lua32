--[[
test_audio_out.lua - verifica la catena FFI di audio_out.lua (apertura
device, accodamento, chiusura) - con SDL_AUDIODRIVER=dummy non produce
suono reale, ma esercita ogni chiamata SDL2 per davvero, stesso
principio di test_video.lua per il video.

    SDL_AUDIODRIVER=dummy luajit tests/test_audio_out.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")

local fails = 0
local function check(label, ok)
    if not ok then fails = fails + 1 end
    print(string.format("%s %s", ok and "OK  " or "FAIL", label))
end

local ok, err = pcall(function()
    local audio_out = require("audio_out")
    local out = audio_out.new(22050, 1024)
    check("apertura device: sample_rate ottenuto", out.sample_rate ~= nil and out.sample_rate > 0)
    check("apertura device: mono", out.channels == 1)

    local buf = ffi.new("int16_t[?]", 512)
    for i = 0, 511 do buf[i] = 1000 end
    local queued = out:queue(buf, 512)
    check("queue() di un blocco non fallisce", queued == true)

    local ms = out:queued_ms()
    check("queued_ms() ritorna un numero >= 0", ms ~= nil and ms >= 0)

    out:close()
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
