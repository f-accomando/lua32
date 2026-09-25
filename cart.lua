--[[
cart.lua - formato cartuccia (contenitore binario) + loader/swap nel
motore. Vedi docs/design.md "Cartucce" per il ragionamento.

Cosa fa QUESTO file: impacchetta bytes gia' pronti (codice assemblato,
banchi di tilemap, banchi grafici, palette iniziale) in un unico file
binario `.cart`, e li ricarica per eseguirli - e' l'estensione naturale
di PORT_STAGE_SELECT (gia' esistente in cpu.lua) a TUTTI gli asset di
una cartuccia, non solo alla tilemap.

Cosa NON fa (ancora, deliberatamente): non legge una cartella
dev/<nome>/ con PNG/JSON sorgenti - quella pipeline (editor -> bytes)
non ha ancora senso da costruire perche' l'editor stesso non esiste
ancora (vedi "Punti ancora aperti" in design.md). M.pack() qui sotto
prende gia' i bytes pronti, esattamente il livello che main.lua usa
oggi (assembler.assemble() produce gia' bytes).

Campi per l'autenticita' futura (NFT, vedi design.md): uid (16 byte,
identificatore della cartuccia) e content_sha256 (32 byte) sono gia'
riservati nell'header. content_sha256 e' zero-riempito per ora (nessuna
libreria SHA-256 nel progetto ancora) - l'integrita' del file e'
verificata con CRC32 (content_crc32), che basta a rilevare corruzione
accidentale; l'hash crittografico vero si aggiunge quando serve
davvero (nessun motivo di implementarlo prima che esista un uso reale
a valle, es. una registry esterna).
]]
local ffi = require("ffi")
local bit = require("bit")
local mm = require("memory_map")

local M = {}

M.MAGIC = "S32CART1"
M.VERSION = 1

-- -----------------------------------------------------------
-- header binario, packed (nessun padding fra i campi)
-- -----------------------------------------------------------
ffi.cdef[[
typedef struct __attribute__((packed)) {
    char     magic[8];
    uint8_t  version;
    uint8_t  reserved0[3];
    uint8_t  uid[16];
    char     title[64];
    char     author[32];
    uint32_t created_unix;
    uint32_t code_offset;
    uint32_t code_size;
    uint16_t stage_bank_count;
    uint32_t stage_bank_size;
    uint32_t stage_bank_offset;
    uint16_t gfx_bank_count;
    uint32_t gfx_bank_size;
    uint32_t gfx_bank_offset;
    uint32_t cgram_offset;
    uint8_t  cgram_present;
    uint32_t content_crc32;
    uint8_t  content_sha256[32];
    uint8_t  reserved1[59];
} s32_cart_header_t;
]]
local header_t = ffi.typeof("s32_cart_header_t")
M.HEADER_SIZE = ffi.sizeof(header_t)  -- 256 byte esatti

local STAGE_BANK_SIZE = mm.TILEMAP_BYTES
local GFX_BANK_SIZE = mm.DIRECTORY_BYTES + mm.GRAPHICS_POOL_BYTES

-- -----------------------------------------------------------
-- CRC32 (IEEE 802.3) - solo per rilevare corruzione accidentale del
-- file, non e' un hash crittografico (vedi nota in testa al file)
-- -----------------------------------------------------------
local crc_table
local function build_crc_table()
    crc_table = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) ~= 0 then
                c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i] = c
    end
end

local function crc32(data)
    if not crc_table then build_crc_table() end
    local crc = 0xFFFFFFFF
    for i = 1, #data do
        local byte = data:byte(i)
        crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, byte), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bxor(crc, 0xFFFFFFFF) % 0x100000000
end
M.crc32 = crc32

-- -----------------------------------------------------------
-- UID (16 byte casuali, formattati come UUID v4 per convenzione -
-- non serve crittograficamente sicuro, solo distinguere cartucce)
-- -----------------------------------------------------------
function M.new_uid()
    local bytes = {}
    for i = 1, 16 do bytes[i] = math.random(0, 255) end
    bytes[7] = bit.bor(bit.band(bytes[7], 0x0F), 0x40)  -- versione 4
    bytes[9] = bit.bor(bit.band(bytes[9], 0x3F), 0x80)  -- variante RFC4122
    return string.char(unpack(bytes))
end

function M.uid_to_hex(uid)
    local out = {}
    for i = 1, 16 do out[i] = string.format("%02x", uid:byte(i)) end
    return table.concat(out)
end

function M.new_meta(title, author)
    return {
        uid = M.new_uid(),
        title = title or "",
        author = author or "",
        created = os.time(),
    }
end

-- -----------------------------------------------------------
-- pack: bytes gia' pronti -> file .cart
--
-- spec = {
--   meta = { uid=<16 byte string>, title=<string>, author=<string>, created=<unix time> },
--   code = <string bytes>,
--   stage_banks = { [0]=<string TILEMAP_BYTES>, [1]=..., ... },  -- indice = numero di stage/PORT_STAGE_SELECT
--   gfx_banks = { [0]=<string GFX_BANK_SIZE>, ... },              -- indice = numero di banco/PORT_GFX_BANK_SELECT
--   cgram = <string CGRAM_SIZE o nil>,                            -- palette iniziale, opzionale
-- }
-- -----------------------------------------------------------
local function banks_to_list(banks)
    -- gli indici Lua-side partono da 0 (coerente con i valori scritti
    -- nelle porte PORT_STAGE_SELECT/PORT_GFX_BANK_SELECT) - qui li
    -- rendiamo una sequenza densa 1..n per scriverli in ordine nel file
    local n = 0
    for k in pairs(banks) do if k + 1 > n then n = k + 1 end end
    local list = {}
    for i = 0, n - 1 do
        list[i + 1] = banks[i] or error(string.format("banco %d mancante (gli indici devono essere densi da 0)", i))
    end
    return list, n
end

function M.pack(spec, out_path)
    local meta = spec.meta or M.new_meta()
    local code = spec.code or ""
    local stage_list, stage_count = banks_to_list(spec.stage_banks or {})
    local gfx_list, gfx_count = banks_to_list(spec.gfx_banks or {})
    local cgram = spec.cgram

    for i, data in ipairs(stage_list) do
        if #data ~= STAGE_BANK_SIZE then
            error(string.format("banco stage %d: dimensione %d, attesa %d", i - 1, #data, STAGE_BANK_SIZE))
        end
    end
    for i, data in ipairs(gfx_list) do
        if #data ~= GFX_BANK_SIZE then
            error(string.format("banco grafico %d: dimensione %d, attesa %d", i - 1, #data, GFX_BANK_SIZE))
        end
    end
    if cgram and #cgram ~= mm.CGRAM_SIZE then
        error(string.format("cgram: dimensione %d, attesa %d", #cgram, mm.CGRAM_SIZE))
    end

    local code_offset = M.HEADER_SIZE
    local stage_offset = code_offset + #code
    local gfx_offset = stage_offset + stage_count * STAGE_BANK_SIZE
    local cgram_offset = gfx_offset + gfx_count * GFX_BANK_SIZE

    local body_parts = { code }
    for _, data in ipairs(stage_list) do body_parts[#body_parts + 1] = data end
    for _, data in ipairs(gfx_list) do body_parts[#body_parts + 1] = data end
    if cgram then body_parts[#body_parts + 1] = cgram end
    local body = table.concat(body_parts)

    local h = header_t()
    ffi.fill(h, M.HEADER_SIZE)
    ffi.copy(h.magic, M.MAGIC, #M.MAGIC)
    h.version = M.VERSION
    if meta.uid then ffi.copy(h.uid, meta.uid, 16) end
    ffi.copy(h.title, meta.title or "", math.min(#(meta.title or ""), 63))
    ffi.copy(h.author, meta.author or "", math.min(#(meta.author or ""), 31))
    h.created_unix = meta.created or os.time()
    h.code_offset = code_offset
    h.code_size = #code
    h.stage_bank_count = stage_count
    h.stage_bank_size = STAGE_BANK_SIZE
    h.stage_bank_offset = stage_count > 0 and stage_offset or 0
    h.gfx_bank_count = gfx_count
    h.gfx_bank_size = GFX_BANK_SIZE
    h.gfx_bank_offset = gfx_count > 0 and gfx_offset or 0
    h.cgram_offset = cgram and cgram_offset or 0
    h.cgram_present = cgram and 1 or 0
    h.content_crc32 = crc32(body)
    -- content_sha256 resta a zero: nessun hash crittografico ancora
    -- implementato, vedi nota in testa al file

    local f, err = io.open(out_path, "wb")
    if not f then error("impossibile scrivere " .. out_path .. ": " .. tostring(err)) end
    f:write(ffi.string(h, M.HEADER_SIZE))
    f:write(body)
    f:close()
end

-- -----------------------------------------------------------
-- load: file .cart -> tabella Lua pronta per install()
-- -----------------------------------------------------------
function M.load(path)
    local f, err = io.open(path, "rb")
    if not f then error("impossibile leggere " .. path .. ": " .. tostring(err)) end
    local raw = f:read("*a")
    f:close()

    if #raw < M.HEADER_SIZE then error(path .. ": file troppo corto per contenere un header valido") end
    local h = ffi.new(header_t)
    ffi.copy(h, raw, M.HEADER_SIZE)

    if ffi.string(h.magic, 8) ~= M.MAGIC then
        error(path .. ": magic non valido (non e' una cartuccia s32)")
    end
    if h.version ~= M.VERSION then
        error(string.format("%s: versione %d non supportata (attesa %d)", path, h.version, M.VERSION))
    end

    local body = raw:sub(M.HEADER_SIZE + 1)
    local crc = crc32(body)
    if crc ~= h.content_crc32 then
        error(string.format("%s: CRC32 non corrisponde (0x%08X calcolato, 0x%08X atteso) - file corrotto?",
            path, crc, h.content_crc32))
    end

    local code = raw:sub(h.code_offset + 1, h.code_offset + h.code_size)

    local stage_banks = {}
    for i = 0, h.stage_bank_count - 1 do
        local off = h.stage_bank_offset + i * h.stage_bank_size
        stage_banks[i] = raw:sub(off + 1, off + h.stage_bank_size)
    end

    local gfx_banks = {}
    for i = 0, h.gfx_bank_count - 1 do
        local off = h.gfx_bank_offset + i * h.gfx_bank_size
        gfx_banks[i] = raw:sub(off + 1, off + h.gfx_bank_size)
    end

    local cgram = nil
    if h.cgram_present ~= 0 then
        cgram = raw:sub(h.cgram_offset + 1, h.cgram_offset + mm.CGRAM_SIZE)
    end

    return {
        meta = {
            uid = ffi.string(h.uid, 16),
            title = ffi.string(h.title),
            author = ffi.string(h.author),
            created = tonumber(h.created_unix),
        },
        code = code,
        stage_banks = stage_banks,
        gfx_banks = gfx_banks,
        cgram = cgram,
    }
end

-- -----------------------------------------------------------
-- install: carica una cartuccia gia' letta (M.load) dentro una CPU -
-- equivalente a quello che fara' l'OS quando lancia una cartuccia
-- -----------------------------------------------------------
function M.install(cpu, cart, load_addr)
    ffi.copy(cpu.mem + load_addr, cart.code, #cart.code)
    cpu.stages = cart.stage_banks
    cpu.gfx_banks = cart.gfx_banks
    if cart.cgram then
        ffi.copy(cpu.mem + mm.CGRAM_BASE, cart.cgram, mm.CGRAM_SIZE)
    end
    if cart.stage_banks[0] then cpu:write16(mm.PORT_STAGE_SELECT, 0) end
    if cart.gfx_banks[0] then cpu:write16(mm.PORT_GFX_BANK_SELECT, 0) end
    return load_addr
end

return M
