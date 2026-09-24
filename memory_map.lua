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
-- VRAM - solo l'inizio (dove vive la tilemap, dimensione fissa
-- perche' la tilemap resta una griglia densa a 8x8 - vedi
-- docs/design.md "Tile e sprite"). Il resto di VRAM (archivio piatto
-- + tabella directory per i tile a taglia variabile) si definisce
-- quando si costruisce il PPU.
-- ---------------------------------------------------------------
M.VRAM_BASE = M.WRAM_END  -- 0x020000

M.TILEMAP_W = 128  -- tile (in celle da 8x8px: 1024px)
M.TILEMAP_H = 128
M.TILEMAP_ENTRY_BYTES = 2  -- tile_index + palette + taglia, formato
                            -- esatto dei bit deciso col PPU - CPU sa
                            -- solo quanti byte copiare, non cosa
                            -- significano
M.TILEMAP_BYTES = M.TILEMAP_W * M.TILEMAP_H * M.TILEMAP_ENTRY_BYTES  -- 32768 (32KB)
M.TILEMAP_VRAM_OFFSET = 0

-- ---------------------------------------------------------------
-- PORTE memory-mapped
-- ---------------------------------------------------------------
M.PORT_INPUT = 0x042000          -- giocatore 1 (locale, tastiera/joypad)
M.PORT_STAGE_SELECT = 0x042001   -- scrivere un numero di stage copia
                                  -- ISTANTANEAMENTE la tilemap di quello
                                  -- stage dentro VRAM (dati registrati
                                  -- prima dall'host in cpu.stages)
M.PORT_SCROLL_X = 0x042002
M.PORT_SCROLL_Y = 0x042003
M.PORT_SOUND = 0x042004          -- scrivere un ID suono lo accoda -
                                  -- l'ID punta a una definizione nella
                                  -- regione audio memory-mapped (APU,
                                  -- vedi docs/design.md), non piu' a un
                                  -- asset esterno

M.EXTRA_INPUT_PORTS = {
    0x042010,  -- giocatore 2 (indice 1)
    0x042011,  -- giocatore 3 (indice 2)
    0x042012,  -- giocatore 4 (indice 3)
    0x042013,  -- giocatore 5 (indice 4)
    0x042014,  -- giocatore 6 (indice 5)
    0x042015,  -- giocatore 7 (indice 6)
    0x042016,  -- giocatore 8 (indice 7)
}

return M
