--[[
memory_map.lua - specifica di s32 (motore a 16-bit, bus a 24-bit flat).

Unica fonte di verita' per la mappa indirizzi - cpu.lua e chiunque
altro nel motore importa le costanti da qui, non le ridefinisce.

Per ora contiene solo quello che serve a cpu.lua (bus, registri, WRAM
per lo stack hardware, porte memory-mapped). VRAM/OAM/CGRAM (con
l'indirizzamento a taglia variabile per i tile 8-64px, vedi
docs/design.md) vengono aggiunti quando si costruisce il PPU - CPU non
ha bisogno di conoscerne i dettagli interni, solo TILEMAP_BYTES (per
la copia scatenata da PORT_STAGE_SELECT).

Vedi docs/design.md per il perche' di ogni numero.
]]
local M = {}

-- ---------------------------------------------------------------
-- BUS
-- ---------------------------------------------------------------
M.ADDRESS_BITS = 24
M.ADDRESS_SPACE = 16777216  -- 1 << 24 (16MB)
M.ADDRESS_MASK = M.ADDRESS_SPACE - 1

-- ---------------------------------------------------------------
-- REGISTRI
-- ---------------------------------------------------------------
M.REGISTER_BITS = 16
M.REGISTER_MAX = 65535

M.FLAG_ZERO = 0x01
M.FLAG_NEGATIVE = 0x02
M.FLAG_CARRY = 0x04
M.FLAG_OVERFLOW = 0x08

-- ---------------------------------------------------------------
-- WRAM - stessa generosita' del vecchio motore Python, nessun
-- motivo emerso per cambiarla
-- ---------------------------------------------------------------
M.WRAM_BASE = 0x000000
M.WRAM_SIZE = 128 * 1024  -- 128KB
M.WRAM_END = M.WRAM_BASE + M.WRAM_SIZE  -- 0x020000 (esclusivo)

-- ---------------------------------------------------------------
-- VRAM
--
-- Tilemap: griglia DENSA a 8x8 (opzione A - vedi docs/design.md
-- "Mappa di memoria"): un tile piu' grande si piazza nella cella
-- "origine" e occupa per convenzione il blocco di celle successive
-- (es. 32x32 copre 4x4 celle) - il PPU lo disegna sopra, le celle
-- coperte sotto non contano.
--
-- Ogni entry di tilemap/OAM e' un "descrittore di tile" a 16 bit:
--   bit 0-10  (11 bit): tile_index (0-2047)
--   bit 11-13 (3 bit):  palette (0-7)
--   bit 14-15 (2 bit):  riservati (flip/priorita' futuri)
-- La TAGLIA del tile (8/16/32/64) NON e' nel descrittore - e'
-- un'unica fonte di verita' nella tabella directory sotto, cosi' un
-- tile ha sempre la stessa taglia ovunque venga referenziato, niente
-- incoerenze tra un piazzamento e l'altro.
--
-- Indirizzamento della grafica vera (taglie diverse = byte diversi:
-- 8x8=64B, 16x16=256B, 32x32=1024B, 64x64=4096B, quindi niente
-- indirizzo per moltiplicazione fissa come nel vecchio motore):
-- un archivio piatto di byte (allineato a 64, mcd tra le 4 taglie)
-- piu' una tabella "directory" che per ogni tile_index registra dove
-- inizia (offset dentro l'archivio) e quanto e' grande.
-- ---------------------------------------------------------------
M.VRAM_BASE = M.WRAM_END  -- 0x020000

M.TILEMAP_W = 128  -- tile (in celle da 8x8px: 1024px)
M.TILEMAP_H = 128
M.TILEMAP_ENTRY_BYTES = 2
M.TILEMAP_BYTES = M.TILEMAP_W * M.TILEMAP_H * M.TILEMAP_ENTRY_BYTES  -- 32768 (32KB)
M.TILEMAP_VRAM_OFFSET = 0

M.TILE_DESC_INDEX_BITS = 11
M.TILE_DESC_PALETTE_BITS = 3
M.MAX_TILES = 2048  -- 1 << TILE_DESC_INDEX_BITS

M.TILE_SIZES = {8, 16, 32, 64}  -- indicizzato da size_class 0-3 (vedi
                                  -- tile_size_from_class in ppu.lua)
M.BITS_PER_PIXEL = 8  -- indici di palette a 8 bit, come il vecchio motore

M.DIRECTORY_ENTRY_BYTES = 4  -- offset a 24 bit (3 byte) + size_class (1 byte)
M.DIRECTORY_BYTES = M.MAX_TILES * M.DIRECTORY_ENTRY_BYTES  -- 8192 (8KB)
M.DIRECTORY_VRAM_OFFSET = M.TILEMAP_BYTES

M.GRAPHICS_POOL_BYTES = 512 * 1024  -- 512KB - generoso: 2048 tile a
                                      -- 16x16 (256B ciascuno) ci stanno
                                      -- esattamente; taglie piu' grandi
                                      -- usate con parsimonia, come i
                                      -- 64x64 dello SNES vero
M.GRAPHICS_POOL_VRAM_OFFSET = M.DIRECTORY_VRAM_OFFSET + M.DIRECTORY_BYTES

M.VRAM_SIZE = M.TILEMAP_BYTES + M.DIRECTORY_BYTES + M.GRAPHICS_POOL_BYTES  -- 565248 (~552KB)
M.VRAM_END = M.VRAM_BASE + M.VRAM_SIZE

-- ---------------------------------------------------------------
-- OAM (sprite) - stesso formato slot del vecchio motore (8 byte:
-- x, y, descrittore di tile, attr), solo il campo "tile" ora e' il
-- descrittore condiviso con la tilemap invece di un indice fisso.
-- attr: bit0 = visibile, bit1 = flip orizzontale, bit2 = flip
-- verticale (tutto a zero di default = sprite nascosto, come prima).
-- ---------------------------------------------------------------
M.OAM_BASE = M.VRAM_END
M.OAM_SLOT_BYTES = 8
M.OAM_MAX_SPRITES = 512
M.OAM_SIZE = M.OAM_SLOT_BYTES * M.OAM_MAX_SPRITES  -- 4096 (4KB)
M.OAM_END = M.OAM_BASE + M.OAM_SIZE

M.OAM_ATTR_VISIBLE = 0x01
M.OAM_ATTR_FLIP_X = 0x02
M.OAM_ATTR_FLIP_Y = 0x04

-- ---------------------------------------------------------------
-- CGRAM - a 24-bit (RGB888, non piu' 15-bit: vedi docs/design.md
-- "Colore" per il perche', l'output finale e' comunque HDMI
-- truecolor). 8 palette da 256 colori, indice 0 sempre trasparente.
-- ---------------------------------------------------------------
M.CGRAM_BASE = M.OAM_END
M.CGRAM_COLOR_BYTES = 3
M.COLORS_PER_PALETTE = 256
M.PALETTE_COUNT = 8
M.CGRAM_SIZE = M.PALETTE_COUNT * M.COLORS_PER_PALETTE * M.CGRAM_COLOR_BYTES  -- 6144 (6KB)
M.CGRAM_END = M.CGRAM_BASE + M.CGRAM_SIZE

-- ---------------------------------------------------------------
-- PORTE memory-mapped
-- ---------------------------------------------------------------
M.PORTS_BASE = M.CGRAM_END
M.PORT_INPUT = M.PORTS_BASE + 0          -- giocatore 1 (locale, tastiera/joypad)
M.PORT_STAGE_SELECT = M.PORTS_BASE + 1   -- scrivere un numero di stage copia
                                           -- ISTANTANEAMENTE la tilemap di quello
                                           -- stage dentro VRAM (dati registrati
                                           -- prima dall'host in cpu.stages)
M.PORT_SCROLL_X = M.PORTS_BASE + 2
M.PORT_SCROLL_Y = M.PORTS_BASE + 3
M.PORT_SOUND = M.PORTS_BASE + 4          -- scrivere un ID suono lo accoda -
                                           -- l'ID punta a una definizione nella
                                           -- regione audio memory-mapped (APU,
                                           -- vedi docs/design.md), non piu' a un
                                           -- asset esterno
M.PORT_GFX_BANK_SELECT = M.PORTS_BASE + 5  -- stesso principio di PORT_STAGE_SELECT,
                                           -- ma per la grafica: scrivere un numero
                                           -- di banco copia ISTANTANEAMENTE
                                           -- directory+archivio grafico dentro VRAM
                                           -- (dati registrati prima dall'host in
                                           -- cpu.gfx_banks) - vedi docs/design.md
                                           -- "Cartucce" e "Formato cartuccia"

M.EXTRA_INPUT_PORTS = {
    M.PORTS_BASE + 0x10,  -- giocatore 2 (indice 1)
    M.PORTS_BASE + 0x11,  -- giocatore 3 (indice 2)
    M.PORTS_BASE + 0x12,  -- giocatore 4 (indice 3)
    M.PORTS_BASE + 0x13,  -- giocatore 5 (indice 4)
    M.PORTS_BASE + 0x14,  -- giocatore 6 (indice 5)
    M.PORTS_BASE + 0x15,  -- giocatore 7 (indice 6)
    M.PORTS_BASE + 0x16,  -- giocatore 8 (indice 7)
}
M.PORTS_SIZE = 256
M.PORTS_END = M.PORTS_BASE + M.PORTS_SIZE

return M
