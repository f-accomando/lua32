--[[
pack_demo_cart.lua - impacchetta il demo (lo stesso "quadrato che si
muove" di main.lua) come vera cartuccia cart/demo.cart, cosi' l'OS
(s32_os.lua) ha qualcosa di reale da elencare/lanciare nel picker senza
aspettare l'editor. Non fa parte del motore - un'utility una tantum, va
rilanciato solo se build_demo_program() in main.lua cambia.

    luajit tests/pack_demo_cart.lua

Nota: setup_demo_assets() NON serve piu' per far apparire lo sprite
(il programma ora inizializza da solo il proprio descrittore OAM, vedi
il commento su sprite_word in main.lua:build_demo_program) - qui la
usiamo comunque per generare gfx/tilemap/palette da mettere nel banco 0
della cartuccia, visto che quella parte resta comunque necessaria
(tile grafici e palette non sono "codice", il programma non li genera
da solo).
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local cart = require("cart")
local cpu_mod = require("cpu")
local main_mod = require("main")

local cpu = cpu_mod.new()
local oam_base = main_mod.setup_demo_assets(cpu)
assert(oam_base == mm.OAM_BASE, "oam_base inatteso")

local mem = cpu.mem
local gfx_bank_size = mm.DIRECTORY_BYTES + mm.GRAPHICS_POOL_BYTES
local gfx_bank_0 = ffi.string(mem + mm.VRAM_BASE + mm.DIRECTORY_VRAM_OFFSET, gfx_bank_size)
local stage_bank_0 = ffi.string(mem + mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET, mm.TILEMAP_BYTES)
local cgram_snapshot = ffi.string(mem + mm.CGRAM_BASE, mm.CGRAM_SIZE)

local rom = main_mod.build_demo_program(oam_base)
local code_bytes = string.char(unpack(rom))

local meta = cart.new_meta("Demo - quadrato mobile", "s32 dev")
local out_path = script_dir .. "../cart/demo.cart"

cart.pack({
    meta = meta,
    code = code_bytes,
    stage_banks = { [0] = stage_bank_0 },
    gfx_banks = { [0] = gfx_bank_0 },
    cgram = cgram_snapshot,
}, out_path)

print("Scritto " .. out_path .. " (" .. #code_bytes .. " byte di codice)")

-- verifica round-trip minima: si ricarica e si esegue davvero
local loaded = cart.load(out_path)
local cpu2 = cpu_mod.new()
local load_addr = cart.install(cpu2, loaded, main_mod.CART_LOAD_ADDR)
cpu2:run(load_addr, 0)
local x = cpu2.mem[mm.OAM_BASE] + cpu2.mem[mm.OAM_BASE + 1] * 256
local y = cpu2.mem[mm.OAM_BASE + 2] + cpu2.mem[mm.OAM_BASE + 3] * 256
local attr = cpu2.mem[mm.OAM_BASE + 6]
print(string.format("Verifica: dopo il primo run, sprite a (%d,%d), attr=%d (atteso 150,100,1)", x, y, attr))
assert(x == 150 and y == 100 and attr == mm.OAM_ATTR_VISIBLE, "verifica fallita - il .cart non si comporta come atteso")
print("OK: cart/demo.cart si carica ed esegue correttamente.")
