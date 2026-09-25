--[[
sdl_load.lua - carica libSDL2 provando i nomi reali che puo' avere sul
sistema, condiviso da video.lua/input.lua (e in futuro audio_out.lua).

"SDL2" (-> libSDL2.so) funziona SOLO se e' installato anche il pacchetto
-dev (quello mette il symlink senza versione, usato per compilare) - sul
target reale installiamo solo il runtime (tests/install_pi.sh), che
fornisce esclusivamente "libSDL2-2.0.so.0" (il vero soname). Si prova
prima il nome semplice (comodo in sandbox/desktop con -dev installato),
poi il soname reale.
]]
local ffi = require("ffi")

local CANDIDATES = { "SDL2", "libSDL2-2.0.so.0", "libSDL2-2.0.so" }

local sdl, last_err
for _, name in ipairs(CANDIDATES) do
    local ok, result = pcall(ffi.load, name)
    if ok then
        sdl = result
        break
    end
    last_err = result
end

if not sdl then
    error("impossibile caricare libSDL2 (provati: " .. table.concat(CANDIDATES, ", ") .. ") - "
        .. tostring(last_err))
end

return sdl
