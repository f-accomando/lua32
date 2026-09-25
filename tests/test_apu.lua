--[[
test_apu.lua - verifica gli oscillatori, l'inviluppo ADSR e il mixing
a canale esplicito dell'APU (apu.lua).

    luajit tests/test_apu.lua
]]
local script_dir = arg[0]:match("(.*/)") or "./"
package.path = script_dir .. "../?.lua;" .. package.path

local ffi = require("ffi")
local mm = require("memory_map")
local apu_module = require("apu")

local fails = 0
local function check(label, got, expected)
    local ok = got == expected
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso %s, ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(got)))
end

local function check_near(label, got, expected, tol)
    local ok = math.abs(got - expected) <= tol
    if not ok then fails = fails + 1 end
    print(string.format("%s %s: atteso ~%s (tol %s), ottenuto %s", ok and "OK  " or "FAIL", label, tostring(expected), tostring(tol), tostring(got)))
end

local function new_mem()
    return ffi.new("uint8_t[?]", mm.APU_END)
end

local function set_channel(mem, ch, fields)
    local reg = mm.APU_BASE + ch * mm.APU_CHANNEL_BYTES
    if fields.freq then
        mem[reg + mm.APU_REG_FREQ_LO] = fields.freq % 256
        mem[reg + mm.APU_REG_FREQ_HI] = math.floor(fields.freq / 256) % 256
    end
    if fields.waveform then mem[reg + mm.APU_REG_WAVEFORM] = fields.waveform end
    if fields.duty then mem[reg + mm.APU_REG_DUTY] = fields.duty end
    if fields.volume then mem[reg + mm.APU_REG_VOLUME] = fields.volume end
    if fields.attack then mem[reg + mm.APU_REG_ATTACK] = fields.attack end
    if fields.decay then mem[reg + mm.APU_REG_DECAY] = fields.decay end
    if fields.sustain then mem[reg + mm.APU_REG_SUSTAIN] = fields.sustain end
    if fields.release then mem[reg + mm.APU_REG_RELEASE] = fields.release end
    if fields.gate ~= nil then
        mem[reg + mm.APU_REG_CONTROL] = fields.gate and mm.APU_CONTROL_GATE or 0
    end
end

-- ---------------------------------------------------------------
-- oscillatori puri: forma d'onda corretta a fasi note
-- ---------------------------------------------------------------
check("quadra: prima meta' del duty = +1", apu_module.square_wave(0.1, 0.5), 1.0)
check("quadra: dopo il duty = -1", apu_module.square_wave(0.6, 0.5), -1.0)
check_near("triangolo: minimo a fase 0", apu_module.triangle_wave(0.0), -1.0, 1e-9)
check_near("triangolo: massimo a fase 0.5", apu_module.triangle_wave(0.5), 1.0, 1e-9)
check_near("triangolo: zero a fase 0.25", apu_module.triangle_wave(0.25), 0.0, 1e-9)
check_near("sawtooth: minimo a fase 0", apu_module.sawtooth_wave(0.0), -1.0, 1e-9)
check_near("sawtooth: massimo a fase quasi 1", apu_module.sawtooth_wave(0.999), 0.998, 0.01)

do
    local lfsr, bit0 = apu_module.noise_step(1)
    check("noise_step: mai ritorna lfsr=0 (si bloccherebbe)", lfsr ~= 0, true)
end

-- ---------------------------------------------------------------
-- canale silenzioso di default (tutti i registri a zero)
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    local apu = apu_module.new(22050)
    local buf = apu:generate(mem, 100)
    local all_zero = true
    for i = 0, 99 do if buf[i] ~= 0 then all_zero = false end end
    check("canale non configurato: silenzio totale", all_zero, true)
end

-- ---------------------------------------------------------------
-- inviluppo: attack rapido porta il livello a salire, poi sustain lo
-- mantiene finche' gate=1, poi release lo riporta a zero
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    local apu = apu_module.new(22050)
    set_channel(mem, 0, {
        freq = 440, waveform = mm.APU_WAVEFORM_SQUARE, duty = 128, volume = 255,
        attack = 10, decay = 10, sustain = 200, release = 10, gate = true,
    })

    -- dopo pochi campioni l'ampiezza deve essere cresciuta rispetto al primo campione
    local buf1 = apu:generate(mem, 1)
    local buf2 = apu:generate(mem, 200)
    local max_early = 0
    for i = 0, 199 do max_early = math.max(max_early, math.abs(buf2[i])) end
    check("attack: l'ampiezza cresce nei primi campioni", max_early > math.abs(buf1[0]), true)

    -- avanti abbastanza campioni da superare attack+decay e stabilizzarsi sul sustain
    local buf3 = apu:generate(mem, 5000)
    local max_sustain = 0
    for i = 4000, 4999 do max_sustain = math.max(max_sustain, math.abs(buf3[i])) end
    -- sustain=200/255 * volume=255/255 -> ampiezza attesa vicina a 200/255 * 32767
    local expected_sustain_peak = (200 / 255) * 32767
    check_near("sustain: ampiezza si stabilizza intorno al livello di sustain", max_sustain, expected_sustain_peak, expected_sustain_peak * 0.05)

    -- rilascio: gate=0 deve far scendere il livello verso zero
    set_channel(mem, 0, { gate = false })
    local buf4 = apu:generate(mem, 5000)
    local max_late = 0
    for i = 4000, 4999 do max_late = math.max(max_late, math.abs(buf4[i])) end
    check("release: l'ampiezza torna a zero dopo il rilascio", max_late, 0)
end

-- ---------------------------------------------------------------
-- due canali sono indipendenti: silenziare uno non tocca l'altro
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    local apu = apu_module.new(22050)
    set_channel(mem, 0, { freq = 220, waveform = mm.APU_WAVEFORM_SQUARE, duty = 128, volume = 255, attack = 0, decay = 0, sustain = 255, release = 0, gate = true })
    set_channel(mem, 1, { freq = 660, waveform = mm.APU_WAVEFORM_TRIANGLE, volume = 255, attack = 0, decay = 0, sustain = 255, release = 0, gate = true })

    local buf_both = apu:generate(mem, 50)
    local any_nonzero_both = false
    for i = 0, 49 do if buf_both[i] ~= 0 then any_nonzero_both = true end end
    check("due canali attivi: uscita non silenziosa", any_nonzero_both, true)

    -- spegni il canale 1, il canale 0 deve continuare a suonare da solo
    local apu2 = apu_module.new(22050)
    set_channel(mem, 1, { volume = 0, gate = false })
    local buf_one = apu2:generate(mem, 50)
    local any_nonzero_one = false
    for i = 0, 49 do if buf_one[i] ~= 0 then any_nonzero_one = true end end
    check("canale 0 continua a suonare da solo dopo aver spento il canale 1", any_nonzero_one, true)
end

-- ---------------------------------------------------------------
-- rumore: produce valori diversi nel tempo (non e' silenzio ne' una
-- costante), a differenza delle onde toniche
-- ---------------------------------------------------------------
do
    local mem = new_mem()
    local apu = apu_module.new(22050)
    set_channel(mem, 0, { freq = 4000, waveform = mm.APU_WAVEFORM_NOISE, volume = 255, attack = 0, decay = 0, sustain = 255, release = 0, gate = true })
    local buf = apu:generate(mem, 200)
    local seen_positive, seen_negative = false, false
    for i = 0, 199 do
        if buf[i] > 0 then seen_positive = true end
        if buf[i] < 0 then seen_negative = true end
    end
    check("rumore: alterna valori positivi e negativi", seen_positive and seen_negative, true)
end

print()
if fails == 0 then
    print("Tutti i test passati.")
else
    print(string.format("%d test falliti.", fails))
    os.exit(1)
end
