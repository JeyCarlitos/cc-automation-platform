-- core/logger.lua
-- Logging centralizado con niveles y timestamp.
-- Todos los módulos deben usar Logger en lugar de print() directamente.
--
-- Uso:
--   local Logger = require("core.logger")
--   Logger.info("Mining started")
--   Logger.warn("Fuel low: " .. level)
--   Logger.error("Cannot open state file")

local Config = require("config.config")

local Logger = {}

-- Mapa de niveles para comparación numérica
local LEVEL_MAP = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

-- Colores por nivel (solo en terminales con color)
local LEVEL_COLORS = {
    DEBUG = colors and colors.gray   or nil,
    INFO  = colors and colors.white  or nil,
    WARN  = colors and colors.yellow or nil,
    ERROR = colors and colors.red    or nil,
}

-- ============================================================
-- Helpers internos
-- ============================================================

-- CC:Tweaked no expone fecha real del sistema.
-- Usamos os.day() + os.time() que representan el tiempo del mundo Minecraft.
local function timestamp()
    local t   = os.time()
    local day = os.day()
    local h   = math.floor(t)
    local m   = math.floor((t - h) * 60)
    return string.format("Dia %3d %02d:%02d", day, h, m)
end

local function ensureLogDir()
    if not fs.exists("data")      then fs.makeDir("data")      end
    if not fs.exists("data/logs") then fs.makeDir("data/logs") end
end

local function write(level, msg)
    local minLevel = LEVEL_MAP[Config.LOG_LEVEL] or LEVEL_MAP["INFO"]
    if (LEVEL_MAP[level] or 0) < minLevel then return end

    local line = string.format("[%s] [%-5s] %s", timestamp(), level, tostring(msg))

    -- Imprimir en terminal con color
    if term and term.isColor and term.isColor() then
        local col = LEVEL_COLORS[level]
        if col then term.setTextColor(col) end
        print(line)
        term.setTextColor(colors.white)
    else
        print(line)
    end

    -- Escribir a archivo con rotación automática
    ensureLogDir()
    local logPath = Config.LOG_FILE
    local maxSize = Config.MAX_LOG_SIZE or 40000

    -- Si el log supera el límite, borrarlo y empezar de nuevo
    if fs.exists(logPath) and fs.getSize(logPath) >= maxSize then
        fs.delete(logPath)
        local rot = fs.open(logPath, "w")
        if rot then
            rot.writeLine(string.format("[%s] [INFO ] --- Log rotado (superó %d bytes) ---", timestamp(), maxSize))
            rot.close()
        end
    end

    local file = fs.open(logPath, "a")
    if file then
        file.writeLine(line)
        file.close()
    end
end

-- ============================================================
-- API pública
-- ============================================================

function Logger.debug(msg) write("DEBUG", msg) end
function Logger.info(msg)  write("INFO",  msg) end
function Logger.warn(msg)  write("WARN",  msg) end
function Logger.error(msg) write("ERROR", msg) end

return Logger
