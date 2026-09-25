--[[
main.lua - primo giro end-to-end del motore: CPU + PPU + video + input
vere, in un loop a 60fps. Non e' ancora l'OS (nessuna selezione
cartuccia, nessuna sospensione) - e' la prova che tutti i pezzi
costruiti finora (cpu.lua, assembler.lua, ppu.lua, video.lua,
input.lua) lavorano insieme per davvero, prima di costruire l'OS sopra.

Il "gioco" e' assemblato al volo qui dentro (non c'e' ancora un
formato cartuccia/loader) - un quadrato che si muove con le frecce/
WASD e rimbalza sui bordi dello schermo, scrivendo la sua posizione
direttamente in OAM (esattamente come farebbe una cartuccia vera).

Uso (sul target reale, Raspberry Pi con KMSDRM):
    SDL_VIDEODRIVER=kmsdrm luajit main.lua

ESC per uscire.
]]
local ffi = require("ffi")
local mm = require("memory_map")
local cpu_module = require("cpu")
local assembler = require("assembler")
local ppu = require("ppu")
local video = require("video")
local input = require("input")

local SCREEN_W, SCREEN_H = 320, 224  -- modalita' 4:3, vedi docs/design.md
local CART_LOAD_ADDR = 0x1000
local TICK_DT = 1 / 60
local MAX_CATCHUP_TICKS = 5  -- stesso principio del vecchio motore:
                               -- se il rendering e' stato lento, recupera
                               -- un po' di tick ma non tutti in un colpo

ffi.cdef[[
typedef struct { long tv_sec; long tv_nsec; } timespec_t;
int clock_gettime(int clk_id, timespec_t *tp);
int nanosleep(const timespec_t *req, timespec_t *rem);
]]
local CLOCK_MONOTONIC = 1
local function now()
    local ts = ffi.new("timespec_t")
    ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end
local function sleep(seconds)
    if seconds <= 0 then return end
    local ts = ffi.new("timespec_t")
    ts.tv_sec = math.floor(seconds)
    ts.tv_nsec = (seconds - math.floor(seconds)) * 1e9
    ffi.C.nanosleep(ts, nil)
end

-- -----------------------------------------------------------
-- asset del demo: sfondo (tile 8x8 ripetuto) + sprite (tile 16x16)
-- -----------------------------------------------------------
local mem  -- popolato in setup_demo_assets(), serve gia' qui per assemblare l'ASM sotto

local function setup_demo_assets(cpu)
    mem = cpu.mem

    ppu.set_color(mem, 0, 1, 20, 30, 60)     -- sfondo: blu scuro
    ppu.set_color(mem, 0, 2, 230, 200, 40)   -- sprite: giallo

    -- tile di sfondo 8x8, tinta unita (indice 1)
    ppu.set_directory_entry(mem, 1, 0, 0)  -- size_class 0 = 8x8, offset 0
    local bg_base = mm.VRAM_BASE + mm.GRAPHICS_POOL_VRAM_OFFSET
    for i = 0, 63 do mem[bg_base + i] = 1 end

    -- tile sprite 16x16, tinta unita (indice 2) - size_class 1 = 16x16
    ppu.set_directory_entry(mem, 2, 64, 1)
    local spr_base = bg_base + 64
    for i = 0, 255 do mem[spr_base + i] = 2 end

    -- riempi la tilemap visibile con lo sfondo (piu' un margine per lo
    -- scroll, anche se qui scroll_x/y restano sempre 0)
    local bg_word = ppu.encode_tile_descriptor(1, 0)
    for cy = 0, math.ceil(SCREEN_H / 8) do
        for cx = 0, math.ceil(SCREEN_W / 8) do
            local addr = mm.VRAM_BASE + mm.TILEMAP_VRAM_OFFSET + (cy * mm.TILEMAP_W + cx) * mm.TILEMAP_ENTRY_BYTES
            mem[addr] = bg_word % 256
            mem[addr + 1] = math.floor(bg_word / 256) % 256
        end
    end

    -- OAM slot 0: tile descrittore (indice 2, palette 0) + attr visibile,
    -- scritti una volta qui - il programma CPU aggiorna solo x/y ogni frame
    local sprite_word = ppu.encode_tile_descriptor(2, 0)
    local oam0 = mm.OAM_BASE
    mem[oam0 + 4] = sprite_word % 256
    mem[oam0 + 5] = math.floor(sprite_word / 256) % 256
    mem[oam0 + 6] = mm.OAM_ATTR_VISIBLE
    mem[oam0 + 7] = 0

    return mm.OAM_BASE
end

-- -----------------------------------------------------------
-- il "gioco": un quadrato che si muove con le frecce/WASD, clampato
-- ai bordi - scritto in ASM ed eseguito ad ogni tick come farebbe una
-- cartuccia vera (WRAM persiste tra una run() e l'altra, il programma
-- HALT-a a fine frame)
-- -----------------------------------------------------------
local function build_demo_program(oam_base)
    local POS_X, POS_Y, INIT_FLAG, INPUT_TMP = 0x3000, 0x3002, 0x3020, 0x3022
    local src = string.format([[
        LDA %d
        JNZ already_init
        LDA #150
        STA %d
        LDA #100
        STA %d
        LDA #1
        STA %d
    already_init:
        IN
        STA %d

        ; su/sinistra sottraggono 2 da un registro a 16 bit SENZA
        ; segno - farlo incondizionatamente quando il valore e' gia'
        ; sotto 2 lo fa avvolgere a un numero enorme (es. 0-2=65534),
        ; che poi CLAMPX/CLAMPY bloccano al limite SUPERIORE invece
        ; che a zero (il numero avvolto sembra "troppo grande", non
        ; negativo - CLAMP non ha modo di saperlo). CMP+JCC controlla
        ; PRIMA di sottrarre: JCC salta se A < 2 (carry non impostato
        ; da CMP quando l'operando e' maggiore, vedi cpu.lua:_cmp),
        ; nel qual caso si fissa direttamente a 0 invece di sottrarre.
        LDA %d
        AND #1
        JZ no_up
        LDA %d
        CMP #2
        JCC clamp_up_zero
        SUB #2
        STA %d
        JMP no_up
    clamp_up_zero:
        LDA #0
        STA %d
    no_up:
        LDA %d
        AND #2
        JZ no_down
        LDA %d
        ADD #2
        STA %d
    no_down:
        LDA %d
        AND #4
        JZ no_left
        LDA %d
        CMP #2
        JCC clamp_left_zero
        SUB #2
        STA %d
        JMP no_left
    clamp_left_zero:
        LDA #0
        STA %d
    no_left:
        LDA %d
        AND #8
        JZ no_right
        LDA %d
        ADD #2
        STA %d
    no_right:
        LDX %d
        CLAMPX 0,%d
        STX %d
        LDY %d
        CLAMPY 0,%d
        STY %d

        LDA %d
        STA %d
        LDA %d
        STA %d
        HALT
    ]],
        INIT_FLAG,
        POS_X, POS_Y, INIT_FLAG,
        INPUT_TMP,
        INPUT_TMP, POS_Y, POS_Y, POS_Y,
        INPUT_TMP, POS_Y, POS_Y,
        INPUT_TMP, POS_X, POS_X, POS_X,
        INPUT_TMP, POS_X, POS_X,
        POS_X, SCREEN_W - 16, POS_X,
        POS_Y, SCREEN_H - 16, POS_Y,
        POS_X, oam_base,
        POS_Y, oam_base + 2
    )
    return assembler.assemble(src, CART_LOAD_ADDR)
end

local M = {}
M.setup_demo_assets = setup_demo_assets
M.build_demo_program = build_demo_program
M.SCREEN_W, M.SCREEN_H = SCREEN_W, SCREEN_H
M.CART_LOAD_ADDR = CART_LOAD_ADDR

-- -----------------------------------------------------------
-- main
-- -----------------------------------------------------------
-- pannello di stato sull'LCD SPI (opzionale, vedi lcd_status.lua) -
-- l'HDMI e' l'unico output del gioco vero, l'LCD e' libero per
-- diagnostica. Attivato solo con S32_LCD_STATUS=1 per non aggiungere
-- costo (scrittura SPI) a chi non lo usa.
local LCD_UPDATE_INTERVAL = 0.5  -- secondi fra un refresh del pannello e l'altro
local function lcd_status_enabled()
    return os.getenv("S32_LCD_STATUS") == "1"
end

-- riepilogo di sessione, stampato su stdout all'uscita (ESC/quit) cosi'
-- si puo' copiare/incollare da SSH senza dover leggere l'LCD a voce -
-- picco/media/1% low/0.01% low sono le metriche standard per misurare
-- gli scatti (stutter), non solo il framerate medio: un frame pessimo
-- ogni tanto puo' sparire nella media ma si sente giocando.
local function avg_of(list, from, to)
    from = from or 1; to = to or #list
    local sum = 0
    for i = from, to do sum = sum + list[i] end
    return sum / (to - from + 1)
end

local function compute_fps_stats(frame_times_s)
    local n = #frame_times_s
    if n == 0 then return nil end
    local fps = {}
    for i = 1, n do fps[i] = 1 / frame_times_s[i] end
    table.sort(fps)  -- crescente: i peggiori (fps piu' basso) all'inizio

    local function low_pct(p)
        local k = math.max(1, math.floor(n * p + 0.5))
        return avg_of(fps, 1, k), k
    end
    local low1, low1_n = low_pct(0.01)
    local low001, low001_n = low_pct(0.0001)

    return {
        n = n,
        avg = avg_of(fps),
        peak = fps[n],
        worst = fps[1],
        low1 = low1, low1_n = low1_n,
        low001 = low001, low001_n = low001_n,
    }
end

local function print_session_summary(frame_times_s, cpu_s, ppu_s, present_s, instr, frames)
    local stats = compute_fps_stats(frame_times_s)
    if not stats then return end
    print(string.format([[

=== s32 - riepilogo sessione (%d frame campionati) ===
FPS medio:      %6.1f
FPS di picco:   %6.1f
FPS peggiore:   %6.1f
1%% low:         %6.1f   (peggiori %d frame)
0.01%% low:      %6.1f   (peggiori %d frame)

CPU:  %.2f us/istruzione (%d istruzioni totali)
PPU:  %.2f ms/frame medio
GPU:  %.2f ms/frame medio (present/blit su HDMI)
]],
        stats.n, stats.avg, stats.peak, stats.worst,
        stats.low1, stats.low1_n, stats.low001, stats.low001_n,
        instr > 0 and (cpu_s / instr * 1e6) or 0, instr,
        ppu_s / frames * 1000,
        present_s / frames * 1000))
end

local function main()
    local cpu = cpu_module.new()
    local oam_base = setup_demo_assets(cpu)
    local rom = build_demo_program(oam_base)
    for i, b in ipairs(rom) do cpu.mem[CART_LOAD_ADDR + i - 1] = b end

    local v = video.new("s32 - demo", SCREEN_W, SCREEN_H, false)

    local lcd_panel = nil
    if lcd_status_enabled() then
        local lcd_status = require("lcd_status")
        lcd_panel = lcd_status.new(
            os.getenv("S32_LCD_FB") or "/dev/fb0",
            os.getenv("S32_LCD_BG") or "shinchan_565.bin",
            480, 320)
    end
    local lcd_timer, lcd_instr, lcd_cpu_s, lcd_ppu_s, lcd_present_s, lcd_frames = 0, 0, 0, 0, 0, 0

    -- accumulatori per l'intera sessione (non si azzerano mai, a
    -- differenza di quelli sopra che alimentano l'LCD ogni 0.5s) - per
    -- il riepilogo finale su stdout, vedi print_session_summary
    local session_frame_times = {}
    local session_cpu_s, session_ppu_s, session_present_s, session_instr, session_frames = 0, 0, 0, 0, 0

    local running = true
    local accumulator = 0
    local last_time = now()

    while running do
        local t = now()
        local raw_elapsed = t - last_time  -- non clampato: per le statistiche serve il dato vero, non quello limitato per l'accumulatore
        local frame_time = math.min(raw_elapsed, TICK_DT * MAX_CATCHUP_TICKS)
        last_time = t
        accumulator = accumulator + frame_time

        local ticks = 0
        local t_cpu = now()
        while accumulator >= TICK_DT and ticks < MAX_CATCHUP_TICKS do
            -- poll() (svuota la coda eventi, aggiorna lo stato tastiera
            -- che input_byte() legge) va fatto ad ogni tick, non una
            -- sola volta per frame renderizzato: se il rendering e'
            -- lento (present() e' il costo maggiore su hardware debole,
            -- vedi tests/bench.lua) il framerate reale puo' scendere
            -- ben sotto i 60Hz del tick, e con lui la frequenza con cui
            -- si guarda la tastiera - una pressione breve rischia di
            -- sparire fra un frame e l'altro. Qui dentro gira sempre a
            -- 60Hz nominali, indipendentemente da quanto sia lento il
            -- resto del frame.
            if input.poll() then running = false end
            if input.menu_button_pressed() then running = false end
            local steps = cpu:run(CART_LOAD_ADDR, input.input_byte())
            lcd_instr = lcd_instr + steps
            session_instr = session_instr + steps
            accumulator = accumulator - TICK_DT
            ticks = ticks + 1
        end
        local dt_cpu = now() - t_cpu
        lcd_cpu_s = lcd_cpu_s + dt_cpu
        session_cpu_s = session_cpu_s + dt_cpu

        local t_ppu = now()
        local buf = ppu.render_frame(cpu.mem, 0, 0, SCREEN_W, SCREEN_H)
        local dt_ppu = now() - t_ppu
        lcd_ppu_s = lcd_ppu_s + dt_ppu
        session_ppu_s = session_ppu_s + dt_ppu

        local t_present = now()
        v:present(buf)
        local dt_present = now() - t_present
        lcd_present_s = lcd_present_s + dt_present
        session_present_s = session_present_s + dt_present

        lcd_frames = lcd_frames + 1
        lcd_timer = lcd_timer + frame_time
        session_frames = session_frames + 1
        session_frame_times[#session_frame_times + 1] = raw_elapsed
        if lcd_panel and lcd_timer >= LCD_UPDATE_INTERVAL then
            lcd_panel:update({
                cpu_us_per_instr = lcd_instr > 0 and (lcd_cpu_s / lcd_instr * 1e6) or nil,
                ppu_ms = lcd_ppu_s / lcd_frames * 1000,
                present_ms = lcd_present_s / lcd_frames * 1000,
                vram_pct = ppu.get_vram_usage_pct(cpu.mem),
                gfx_bank = cpu.current_gfx_bank,
                stage = cpu.current_stage,
                fps = math.floor(lcd_frames / lcd_timer + 0.5),
            })
            lcd_timer, lcd_instr, lcd_cpu_s, lcd_ppu_s, lcd_present_s, lcd_frames = 0, 0, 0, 0, 0, 0
        end

        local elapsed = now() - t
        sleep(TICK_DT - elapsed)
    end

    print_session_summary(session_frame_times, session_cpu_s, session_ppu_s, session_present_s,
        session_instr, session_frames)
    v:close()
end

-- gira main() solo se lanciato direttamente (luajit main.lua), non
-- quando richiesto come modulo dai test (arg[0] in quel caso e' lo
-- script di test, non main.lua)
if arg and arg[0] and arg[0]:match("main%.lua$") then
    main()
end

return M
