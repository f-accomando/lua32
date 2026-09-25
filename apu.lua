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

    -- scratch per-canale riusato ad ogni generate() invece di essere
    -- ricreato - vedi generate() per il perche' (i registri non
    -- cambiano DURANTE una chiamata, quindi si leggono una volta sola
    -- per canale, non una volta per campione)
    self.ch_freq, self.ch_waveform, self.ch_duty, self.ch_volume = {}, {}, {}, {}
    self.ch_gate, self.ch_sustain = {}, {}
    self.ch_attack_inc, self.ch_decay_inc, self.ch_release_inc = {}, {}, {}

    return self
end

-- genera n_samples campioni PCM mono a 16-bit, mixando tutti gli 8
-- canali - da chiamare una volta per frame (vedi main.lua), non per
-- singolo campione.
--
-- Misurato sul Pi reale: questo era il vero costo nascosto dell'audio
-- (9.78ms/frame, alla pari di PPU/GPU - mai trascurabile come assunto
-- dalla sandbox x86). La causa: i registri di un canale sono costanti
-- per TUTTA la durata di una singola generate() (il gioco puo'
-- scriverli solo FRA una chiamata e l'altra, mai mentre gira), ma il
-- codice li rileggeva da mem e ricalcolava gli incrementi ADSR (una
-- divisione ciascuno) per OGNI campione di OGNI canale - fino a
-- ~370 campioni x 8 canali x 3 divisioni = oltre 8800 divisioni inutili
-- al frame. Ora si leggono e si calcolano una volta sola per canale
-- prima del loop sui campioni; il loop caldo lavora solo su numeri gia'
-- pronti (nessuna lettura di memoria, nessuna divisione, nessuna
-- chiamata a funzione - le stesse M.square_wave/triangle_wave/ecc.
-- restano definite sopra solo per i test, qui sono inlineate).
function Apu:generate(mem, n_samples)
    local buf = ffi.new("int16_t[?]", n_samples)
    local base = mm.APU_BASE
    local CH_BYTES = mm.APU_CHANNEL_BYTES
    local sample_rate = self.sample_rate
    local n_channels = mm.APU_CHANNEL_COUNT
    local channels = self.channels

    local freq_a, wave_a, duty_a, vol_a = self.ch_freq, self.ch_waveform, self.ch_duty, self.ch_volume
    local gate_a, sus_a = self.ch_gate, self.ch_sustain
    local atk_a, dec_a, rel_a = self.ch_attack_inc, self.ch_decay_inc, self.ch_release_inc

    for ch = 0, n_channels - 1 do
        local reg = base + ch * CH_BYTES
        freq_a[ch] = mem[reg + mm.APU_REG_FREQ_LO] + mem[reg + mm.APU_REG_FREQ_HI] * 256
        wave_a[ch] = mem[reg + mm.APU_REG_WAVEFORM]
        duty_a[ch] = mem[reg + mm.APU_REG_DUTY] / 255
        vol_a[ch] = mem[reg + mm.APU_REG_VOLUME] / 255
        gate_a[ch] = bit.band(mem[reg + mm.APU_REG_CONTROL], mm.APU_CONTROL_GATE) ~= 0
        sus_a[ch] = mem[reg + mm.APU_REG_SUSTAIN]
        atk_a[ch] = M.rate_increment(mem[reg + mm.APU_REG_ATTACK], sample_rate)
        dec_a[ch] = M.rate_increment(mem[reg + mm.APU_REG_DECAY], sample_rate)
        rel_a[ch] = M.rate_increment(mem[reg + mm.APU_REG_RELEASE], sample_rate)
    end

    local WAVE_NOISE = mm.APU_WAVEFORM_NOISE
    local WAVE_SQUARE = mm.APU_WAVEFORM_SQUARE
    local WAVE_TRIANGLE = mm.APU_WAVEFORM_TRIANGLE
    local floor = math.floor

    for s = 0, n_samples - 1 do
        local mix = 0.0
        for ch = 0, n_channels - 1 do
            local st = channels[ch]
            local gate = gate_a[ch]

            if gate and not st.gated_prev then
                st.env_stage = "attack"
                st.env_level = 0.0
            elseif (not gate) and st.gated_prev then
                st.env_stage = "release"
            end
            st.gated_prev = gate

            local stage = st.env_stage
            local level = st.env_level
            local sustain = sus_a[ch]
            if stage == "attack" then
                level = level + atk_a[ch]
                if level >= 255 then level = 255; stage = "decay" end
            elseif stage == "decay" then
                level = level - dec_a[ch]
                if level <= sustain then level = sustain; stage = "sustain" end
            elseif stage == "sustain" then
                level = sustain
            elseif stage == "release" then
                level = level - rel_a[ch]
                if level <= 0 then level = 0; stage = "idle" end
            end
            st.env_stage = stage
            st.env_level = level

            local waveform = wave_a[ch]
            local freq = freq_a[ch]
            local value
            if waveform == WAVE_NOISE then
                st.phase = st.phase + freq / sample_rate
                if st.phase >= 1.0 then
                    st.phase = st.phase - floor(st.phase)
                    local lfsr = st.lfsr
                    local bit0 = bit.band(lfsr, 1)
                    local bit1 = bit.band(bit.rshift(lfsr, 1), 1)
                    local feedback = bit.bxor(bit0, bit1)
                    st.lfsr = bit.bor(bit.rshift(lfsr, 1), bit.lshift(feedback, 14))
                    st.noise_value = bit0 == 1 and 1.0 or -1.0
                end
                value = st.noise_value
            else
                local phase = st.phase + freq / sample_rate
                phase = phase - floor(phase)
                st.phase = phase
                if waveform == WAVE_SQUARE then
                    value = phase < duty_a[ch] and 1.0 or -1.0
                elseif waveform == WAVE_TRIANGLE then
                    value = phase < 0.5 and (-1.0 + 4.0 * phase) or (3.0 - 4.0 * phase)
                else
                    value = 2.0 * phase - 1.0
                end
            end

            mix = mix + value * (level / 255) * vol_a[ch]
        end

        -- somma diretta, NIENTE divisione fissa per n_channels: un
        -- singolo canale attivo deve suonare a piena scala, non a 1/8
        -- del volume. Il clipping (limitato qui sotto) interviene solo
        -- nel caso raro di piu' canali forti in fase fra loro - stesso
        -- compromesso di un mixer hardware semplice reale, non della
        -- normalizzazione automatica di un DAW.
        if mix > 1.0 then mix = 1.0 elseif mix < -1.0 then mix = -1.0 end
        buf[s] = floor(mix * 32767)
    end

    return buf
end

return M
