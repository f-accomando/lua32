--[[
os_config.lua - impostazioni persistenti dell'OS (per ora solo
dev_mode - selezionabile con la combo Ctrl+D/L1+R1, vedi
input.lua:dev_toggle_held() e os.lua). Salvate in un file di testo
"chiave=valore" invece che con un vero e proprio formato Lua serializzato
(niente loadstring su un file scrivibile: non serve eseguire codice
arbitrario per un flag booleano, e un formato a righe e' piu' facile da
ispezionare/editare a mano su un Pi senza editor grafico).
]]
local M = {}

M.DEFAULT_PATH = "os_config.cfg"

local function parse_bool(s)
    return s == "1" or s == "true"
end

-- load(path): ritorna SEMPRE una tabella valida coi default (dev_mode
-- spento) se il file manca o e' malformato - un config assente e' la
-- normalita' alla primissima esecuzione, non un errore da segnalare.
function M.load(path)
    path = path or M.DEFAULT_PATH
    local cfg = { dev_mode = false }
    local f = io.open(path, "r")
    if not f then return cfg end
    for line in f:lines() do
        local key, val = line:match("^%s*(%a[%w_]*)%s*=%s*(.-)%s*$")
        if key == "dev_mode" then
            cfg.dev_mode = parse_bool(val)
        end
    end
    f:close()
    return cfg
end

function M.save(cfg, path)
    path = path or M.DEFAULT_PATH
    local f = io.open(path, "w")
    if not f then return false, "impossibile scrivere " .. path end
    f:write("dev_mode=" .. (cfg.dev_mode and "1" or "0") .. "\n")
    f:close()
    return true
end

return M
