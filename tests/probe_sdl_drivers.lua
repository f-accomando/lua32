--[[
probe_sdl_drivers.lua - elenca i driver video che QUESTA libSDL2 ha
davvero compilati dentro (non quello che ci si aspetterebbe in
teoria). Serve a diagnosticare "SDL_Init fallita: kmsdrm not
available": se "kmsdrm" non compare in questa lista, il pacchetto
libsdl2 installato e' stato compilato senza quel backend (aggiunto
solo da SDL 2.0.10 in poi) - non e' un problema di overlay/permessi.

    luajit tests/probe_sdl_drivers.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local sdl = require("sdl_load")

ffi.cdef[[
int SDL_GetNumVideoDrivers(void);
const char *SDL_GetVideoDriver(int index);
]]

local n = sdl.SDL_GetNumVideoDrivers()
print(string.format("Driver video compilati in questa libSDL2 (%d):", n))
local has_kmsdrm = false
for i = 0, n - 1 do
    local name = ffi.string(sdl.SDL_GetVideoDriver(i))
    print("  - " .. name)
    if name:lower() == "kmsdrm" then has_kmsdrm = true end
end

print()
if has_kmsdrm then
    print("kmsdrm C'E' - il problema non e' qui (controlla /dev/dri, permessi, overlay).")
else
    print("kmsdrm ASSENTE - questa libSDL2 e' stata compilata senza supporto KMSDRM")
    print("(aggiunto in SDL 2.0.10). Controlla la versione con:")
    print("  dpkg -l | grep libsdl2")
    print("  cat /etc/os-release")
end
