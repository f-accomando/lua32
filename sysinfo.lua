--[[
sysinfo.lua - letture di sistema per il pannello LCD (lcd_status.lua):
percentuale di utilizzo CPU, temperatura, stato di throttling/
sottovoltaggio del firmware.

NOTA: il Raspberry Pi 1 (e i Pi in generale, salvo hardware aggiuntivo
tipo un sensore INA219 su un HAT) non espone un vero sensore di
consumo elettrico via software - non esiste un modo onesto di leggere
"quanti watt" senza hardware in piu' che qui non c'e'. Al suo posto si
usa lo stato di throttling/sottovoltaggio del firmware
(vcgencmd get_throttled), che e' il segnale piu' utile davvero
disponibile per capire se l'alimentazione sta reggendo il carico -
diretto, tra l'altro, al problema di freeze/tastiera morta segnalato
durante i test.
]]
local bit = require("bit")

local M = {}

-- -----------------------------------------------------------
-- temperatura CPU (grado Celsius) - lettura diretta di file, nessun
-- sottoprocesso
-- -----------------------------------------------------------
function M.read_temp_c()
    local f = io.open("/sys/class/thermal/thermal_zone0/temp", "r")
    if not f then return nil end
    local raw = f:read("*l")
    f:close()
    local v = raw and tonumber(raw)
    if not v then return nil end
    return v / 1000
end

-- -----------------------------------------------------------
-- utilizzo CPU (%) - serve un delta fra due letture di /proc/stat
-- (jiffies cumulativi dal boot, non un valore istantaneo). Uso:
--   local state = nil
--   pct, state = sysinfo.read_cpu_usage_pct(state)  -- una volta ogni
--   chiamata successiva, riusando lo stato ritornato
-- Ritorna nil la primissima volta (nessun delta ancora disponibile).
-- -----------------------------------------------------------
local function read_proc_stat()
    local f = io.open("/proc/stat", "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    local nums = {}
    for n in line:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
    if #nums < 4 then return nil end
    local user, nice, system, idle = nums[1], nums[2], nums[3], nums[4]
    local iowait, irq, softirq, steal = nums[5] or 0, nums[6] or 0, nums[7] or 0, nums[8] or 0
    local idle_all = idle + iowait
    local total = user + nice + system + idle + iowait + irq + softirq + steal
    return { idle = idle_all, total = total }
end

function M.read_cpu_usage_pct(prev_state)
    local cur = read_proc_stat()
    if not cur then return nil, prev_state end
    if not prev_state then return nil, cur end
    local d_total = cur.total - prev_state.total
    local d_idle = cur.idle - prev_state.idle
    if d_total <= 0 then return nil, cur end
    local pct = (1 - d_idle / d_total) * 100
    return pct, cur
end

-- -----------------------------------------------------------
-- stato di throttling/sottovoltaggio (vcgencmd get_throttled) - unico
-- sottoprocesso di questo modulo, va chiamato meno spesso delle altre
-- due letture (vedi main.lua: timer separato, piu' lento)
-- -----------------------------------------------------------
function M.read_throttled()
    local f = io.popen("vcgencmd get_throttled 2>/dev/null")
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    local hex = out and out:match("0x(%x+)")
    if not hex then return nil end
    local raw = tonumber(hex, 16)
    if not raw then return nil end
    return {
        raw = raw,
        under_voltage_now = bit.band(raw, 0x1) ~= 0,
        freq_capped_now = bit.band(raw, 0x2) ~= 0,
        throttled_now = bit.band(raw, 0x4) ~= 0,
        soft_temp_limit_now = bit.band(raw, 0x8) ~= 0,
        under_voltage_ever = bit.band(raw, 0x10000) ~= 0,
        throttled_ever = bit.band(raw, 0x40000) ~= 0,
    }
end

return M
