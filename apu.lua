--[[
apu.lua - sintesi audio procedurale di s32: legge gli 8 canali
memory-mapped (vedi memory_map.lua "APU") e genera campioni PCM
mono a 16-bit. Nessun campione pre-registrato - solo oscillatori
(quadra/triangolo/sawtooth/rumore) passati per un inviluppo ADSR vero,
stile SNES ma senza il pezzo piu' costoso (i sample compressi BRR) -
vedi docs/design.md "Audio" per il confronto con Pico-8/SNES.

Controllo a canale esplicito: il programma scrive direttamente nei
registri del canale che vuole usare (frequenza, forma d'onda, ADSR,
GATE per accendere/spegnere la nota) - niente "accoda su un canale
libero", stessa filosofia delle console vere (nessun chip storico ha
mai avuto allocazione automatica dei canali in hardware).

Stato per canale (fase dell'oscillatore, stadio e livello
dell'inviluppo, registro LFSR del rumore) vive qui, non nei registri -
gli stessi registri riletti ogni generate_samples() producono
un'onda che continua a evolvere nel tempo, non un valore statico.
]]
local ffi = require("ffi")
local bit = require("bit")
local mm = require("memory_map")

local M = {}

-- -----------------------------------------------------------
-- oscillatori: fase 0.0-1.0 (una frazione di ciclo) -> valore -1..1.
-- Esposte come funzioni pure (non metodi) per essere testabili da sole.
-- -----------------------------------------------------------
function M.square_wave(phase, duty)
    return phase < duty and 1.0 or -1.0
end

function M.triangle_wave(phase)
    if phase < 0.5 then
        return -1.0 + 4.0 * phase
    else
        return 3.0 - 4.0 * phase
    end
end

function M.sawtooth_wave(phase)
    return 2.0 * phase - 1.0
end

-- LFSR a 15 bit in stile chip anni '80 (NES ecc.) - non e' una copia
-- bit-esatta di nessun chip specifico, solo lo stesso principio
-- (registro a scorrimento con retroazione XOR) per un rumore
-- pseudo-casuale a basso costo, deterministico (stesso seed -> stessa
-- sequenza, utile per i test)
function M.noise_step(lfsr)
    local bit0 = bit.band(lfsr, 1)
    local bit1 = bit.band(bit.rshift(lfsr, 1), 1)
    local feedback = bit.bxor(bit0, bit1)
    local new_lfsr = bit.bor(bit.rshift(lfsr, 1), bit.lshift(feedback, 14))
    return new_lfsr, bit0
end

-- -----------------------------------------------------------
-- ADSR: converte un registro "rate" (0-255) nell'incremento/decremento
-- di livello (0-255) da applicare ad OGNI campione. Rampa lineare
-- (non esponenziale come l'hardware vero) - scelta deliberata per
-- semplicita' nella prima versione, vedi docs/design.md.
-- rate=0 -> transizione immediata (un solo campione).
-- rate=255 -> MAX_ENVELOPE_SECONDS per attraversare l'intera rampa 0-255.
-- -----------------------------------------------------------
local MAX_ENVELOPE_SECONDS = 2.0

function M.rate_increment(rate_byte, sample_rate)
    if rate_byte <= 0 then return 256 end
    local seconds = (rate_byte / 255) * MAX_ENVELOPE_SECONDS
    local samples = math.max(1, seconds * sample_rate)
    return 255 / samples
end

-- -----------------------------------------------------------
-- Apu: stato persistente per canale (fase, inviluppo, LFSR)
-- -----------------------------------------------------------
local Apu = {}
Apu.__index = Apu
M.Apu = Apu

function M.new(sample_rate)
    local self = setmetatable({}, Apu)
    self.sample_rate = sample_rate or 22050
    self.channels = {}
    for ch = 0, mm.APU_CHANNEL_COUNT - 1 do
        self.channels[ch] = {
            phase = 0.0,
            env_stage = "idle",  -- idle | attack | decay | sustain | release
            env_level = 0.0,     -- 0..255
            gated_prev = false,
            lfsr = 1,            -- MAI zero, o il LFSR si blocca per sempre
            noise_value = -1.0,
        }
    end
    return self
end

-- avanza l'inviluppo di un canale di un campione, secondo lo stadio
-- corrente - ritorna il livello 0..255 aggiornato
local function step_envelope(st, gate, attack, decay, sustain, release, sample_rate)
    if gate and not st.gated_prev then
        st.env_stage = "attack"
        st.env_level = 0.0
    elseif (not gate) and st.gated_prev then
        st.env_stage = "release"
    end
    st.gated_prev = gate

    if st.env_stage == "attack" then
        st.env_level = st.env_level + M.rate_increment(attack, sample_rate)
        if st.env_level >= 255 then
            st.env_level = 255
            st.env_stage = "decay"
        end
    elseif st.env_stage == "decay" then
        st.env_level = st.env_level - M.rate_increment(decay, sample_rate)
        if st.env_level <= sustain then
            st.env_level = sustain
            st.env_stage = "sustain"
        end
    elseif st.env_stage == "sustain" then
        st.env_level = sustain
    elseif st.env_stage == "release" then
        st.env_level = st.env_level - M.rate_increment(release, sample_rate)
        if st.env_level <= 0 then
            st.env_level = 0
            st.env_stage = "idle"
        end
    end
    return st.env_level
end

-- genera n_samples campioni PCM mono a 16-bit, mixando tutti gli 8
-- canali - da chiamare una volta per frame (vedi main.lua), non per
-- singolo campione
function Apu:generate(mem, n_samples)
    local buf = ffi.new("int16_t[?]", n_samples)
    local base = mm.APU_BASE
    local CH_BYTES = mm.APU_CHANNEL_BYTES
    local sample_rate = self.sample_rate
    local n_channels = mm.APU_CHANNEL_COUNT

    for s = 0, n_samples - 1 do
        local mix = 0.0
        for ch = 0, n_channels - 1 do
            local st = self.channels[ch]
            local reg = base + ch * CH_BYTES

            local freq = bit.bor(mem[reg + mm.APU_REG_FREQ_LO], bit.lshift(mem[reg + mm.APU_REG_FREQ_HI], 8))
            local waveform = mem[reg + mm.APU_REG_WAVEFORM]
            local duty = mem[reg + mm.APU_REG_DUTY] / 255
            local volume = mem[reg + mm.APU_REG_VOLUME] / 255
            local attack = mem[reg + mm.APU_REG_ATTACK]
            local decay = mem[reg + mm.APU_REG_DECAY]
            local sustain = mem[reg + mm.APU_REG_SUSTAIN]
            local release = mem[reg + mm.APU_REG_RELEASE]
            local gate = bit.band(mem[reg + mm.APU_REG_CONTROL], mm.APU_CONTROL_GATE) ~= 0

            local env = step_envelope(st, gate, attack, decay, sustain, release, sample_rate) / 255

            local value
            if waveform == mm.APU_WAVEFORM_NOISE then
                st.phase = st.phase + freq / sample_rate
                if st.phase >= 1.0 then
                    st.phase = st.phase - math.floor(st.phase)
                    local new_lfsr, out_bit = M.noise_step(st.lfsr)
                    st.lfsr = new_lfsr
                    st.noise_value = out_bit == 1 and 1.0 or -1.0
                end
                value = st.noise_value
            else
                st.phase = st.phase + freq / sample_rate
                st.phase = st.phase - math.floor(st.phase)
                if waveform == mm.APU_WAVEFORM_SQUARE then
                    value = M.square_wave(st.phase, duty)
                elseif waveform == mm.APU_WAVEFORM_TRIANGLE then
                    value = M.triangle_wave(st.phase)
                else
                    value = M.sawtooth_wave(st.phase)
                end
            end

            mix = mix + value * env * volume
        end

        -- somma diretta, NIENTE divisione fissa per n_channels: un
        -- singolo canale attivo deve suonare a piena scala, non a 1/8
        -- del volume. Il clipping (limitato qui sotto) interviene solo
        -- nel caso raro di piu' canali forti in fase fra loro - stesso
        -- compromesso di un mixer hardware semplice reale, non della
        -- normalizzazione automatica di un DAW.
        if mix > 1.0 then mix = 1.0 elseif mix < -1.0 then mix = -1.0 end
        buf[s] = math.floor(mix * 32767)
    end

    return buf
end

return M
