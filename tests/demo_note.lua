--[[
demo_note.lua - genera una nota vera con apu.lua e la salva come .wav,
cosi' si puo' ASCOLTARE il risultato (non solo leggere numeri) - oltre
a stampare qualche statistica di base sul segnale.

    luajit tests/demo_note.lua [output.wav]

Nota di prova: La4 (440Hz), onda quadra, ADSR non banale (attack
percepibile, decay verso un sustain piu' basso, poi release quando il
gate si spegne) - proprio il tipo di suono che un fade in/out semplice
(quello che ha Pico-8) non riesce a fare altrettanto bene.
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local apu_module = require("apu")

local out_path = arg[1] or "demo_note.wav"
local SAMPLE_RATE = 22050

-- -----------------------------------------------------------
-- scrittore WAV minimale (PCM mono 16-bit) - solo per ispezione/
-- debug, non fa parte del motore
-- -----------------------------------------------------------
local function le16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function le32(n)
    return string.char(n % 256, math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function write_wav(path, samples_ffi, n_samples, sample_rate)
    local data = ffi.string(samples_ffi, n_samples * 2)
    local byte_rate = sample_rate * 2
    local f = io.open(path, "wb")
    f:write("RIFF")
    f:write(le32(36 + #data))
    f:write("WAVE")
    f:write("fmt ")
    f:write(le32(16))       -- dimensione chunk fmt
    f:write(le16(1))        -- PCM
    f:write(le16(1))        -- mono
    f:write(le32(sample_rate))
    f:write(le32(byte_rate))
    f:write(le16(2))        -- block align (2 byte/campione, mono)
    f:write(le16(16))       -- bit per campione
    f:write("data")
    f:write(le32(#data))
    f:write(data)
    f:close()
end

-- -----------------------------------------------------------
-- imposta il canale 0: La4 (440Hz), quadra, ADSR percepibile
-- -----------------------------------------------------------
local mem = ffi.new("uint8_t[?]", mm.APU_END)
local apu = apu_module.new(SAMPLE_RATE)

local function set_reg(ch, off, v) mem[mm.APU_BASE + ch * mm.APU_CHANNEL_BYTES + off] = v end
local FREQ = 440
set_reg(0, mm.APU_REG_FREQ_LO, FREQ % 256)
set_reg(0, mm.APU_REG_FREQ_HI, math.floor(FREQ / 256))
set_reg(0, mm.APU_REG_WAVEFORM, mm.APU_WAVEFORM_SQUARE)
set_reg(0, mm.APU_REG_DUTY, 90)       -- duty ~35%, piu' "nasale" di un 50% netto
set_reg(0, mm.APU_REG_VOLUME, 220)
set_reg(0, mm.APU_REG_ATTACK, 15)     -- percepibile, non istantaneo
set_reg(0, mm.APU_REG_DECAY, 40)
set_reg(0, mm.APU_REG_SUSTAIN, 140)   -- scende visibilmente sotto il picco
set_reg(0, mm.APU_REG_RELEASE, 60)
set_reg(0, mm.APU_REG_CONTROL, mm.APU_CONTROL_GATE)  -- gate ON

-- 0.6s con la nota accesa (si sente attack->decay->sustain)...
local n_on = math.floor(SAMPLE_RATE * 0.6)
local buf_on = apu:generate(mem, n_on)

-- ...poi si spegne il gate e si continua a generare per sentire il release
set_reg(0, mm.APU_REG_CONTROL, 0)
local n_off = math.floor(SAMPLE_RATE * 0.9)
local buf_off = apu:generate(mem, n_off)

-- unisce i due blocchi in un unico buffer per il file .wav
local n_total = n_on + n_off
local buf = ffi.new("int16_t[?]", n_total)
ffi.copy(buf, buf_on, n_on * 2)
ffi.copy(buf + n_on, buf_off, n_off * 2)

write_wav(out_path, buf, n_total, SAMPLE_RATE)

-- -----------------------------------------------------------
-- ispezione numerica di base
-- -----------------------------------------------------------
local peak, sum_sq = 0, 0
for i = 0, n_total - 1 do
    local v = buf[i]
    if math.abs(v) > peak then peak = math.abs(v) end
    sum_sq = sum_sq + v * v
end
local rms = math.sqrt(sum_sq / n_total)

-- stima della frequenza SOLO su una finestra stabile dentro il sustain
-- (0.3s-0.5s, ben dentro il plateau, lontana da attack/decay/release e
-- soprattutto dalla coda di silenzio dopo il release - contarli
-- assieme diluirebbe la stima verso il basso, non e' un problema
-- dell'oscillatore ma del contare su una finestra che include silenzio)
local win_start = math.floor(SAMPLE_RATE * 0.3)
local win_end = math.floor(SAMPLE_RATE * 0.5)
local zero_crossings, prev_sign = 0, 0
for i = win_start, win_end do
    local sign = buf[i] >= 0 and 1 or -1
    if prev_sign ~= 0 and sign ~= prev_sign then zero_crossings = zero_crossings + 1 end
    prev_sign = sign
end
local window_s = (win_end - win_start) / SAMPLE_RATE
local expected_freq = zero_crossings / 2 / window_s

print(string.format("Scritto %s (%.2fs, %d campioni a %dHz)", out_path, n_total / SAMPLE_RATE, n_total, SAMPLE_RATE))
print(string.format("Picco: %d / 32767 (%.1f%%)", peak, peak / 32767 * 100))
print(string.format("RMS: %.1f", rms))
print(string.format("Frequenza stimata dagli attraversamenti di zero: %.1fHz (atteso %dHz)", expected_freq, FREQ))
print()
print("Fasi visibili nel file: 0.0-0.15s circa attack (sale), poi decay verso")
print("il sustain (~140/255 del volume), sustain fino a 0.6s, poi release")
print("(l'ampiezza torna a zero) da 0.6s a ~1.1s.")
