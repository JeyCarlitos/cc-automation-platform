-- turtles/miner/state.lua
-- Persistencia del estado de sesión de minería.
--
-- Guarda automáticamente posición, dirección y progreso para
-- poder recuperarse de un crash o apagado inesperado.
--
-- Formato del estado guardado:
-- {
--   phase        = "MINING",
--   mainProgress = 24,     -- último bloque completado del túnel principal
--   moveCount    = 130,    -- movimientos totales en la sesión
--   x = 0, y = 0, z = 24, -- posición al momento del guardado
--   dir = "north",
-- }
--
-- Uso:
--   local State = require("turtles.miner.state")
--   State.save(data)
--   local saved = State.load()   -- nil si no hay sesión previa
--   State.checkpoint(data)       -- guarda solo si moveCount % INTERVAL == 0
--   State.clear()                -- borra al completar la sesión

local Config = require("config.config")
local Logger = require("core.logger")

local State = {}

-- ============================================================
-- Helpers internos
-- ============================================================

local function ensureStateDir()
    if not fs.exists("data")       then fs.makeDir("data")       end
    if not fs.exists("data/state") then fs.makeDir("data/state") end
end

-- ============================================================
-- API pública
-- ============================================================

-- Serializa 'data' y lo escribe en disco.
-- Retorna true si tuvo éxito.
function State.save(data)
    ensureStateDir()

    local file = fs.open(Config.STATE_FILE, "w")
    if not file then
        Logger.error("State.save: no se pudo abrir " .. Config.STATE_FILE)
        return false
    end

    file.write(textutils.serialise(data))
    file.close()

    Logger.debug(string.format(
        "State saved: phase=%s progress=%d x=%d y=%d z=%d",
        tostring(data.phase),
        data.mainProgress or 0,
        data.x or 0, data.y or 0, data.z or 0
    ))
    return true
end

-- Lee y deserializa el estado guardado.
-- Retorna la tabla con el estado, o nil si no existe o está corrupta.
function State.load()
    if not fs.exists(Config.STATE_FILE) then
        return nil
    end

    local file = fs.open(Config.STATE_FILE, "r")
    if not file then
        Logger.error("State.load: no se pudo abrir " .. Config.STATE_FILE)
        return nil
    end

    local content = file.readAll()
    file.close()

    if not content or content == "" then
        Logger.warn("State.load: archivo vacío")
        return nil
    end

    local data = textutils.unserialise(content)
    if not data then
        Logger.error("State.load: estado corrupto, ignorando")
        return nil
    end

    Logger.info(string.format(
        "Sesion anterior encontrada: phase=%s, progreso=%d bloques",
        tostring(data.phase), data.mainProgress or 0
    ))
    return data
end

-- Borra el archivo de estado. Llamar al completar la sesión.
function State.clear()
    if fs.exists(Config.STATE_FILE) then
        fs.delete(Config.STATE_FILE)
        Logger.info("State cleared (sesión completada)")
    end
end

-- Guarda solo si moveCount es múltiplo del intervalo configurado.
-- Llámalo después de cada movimiento para auto-guardado periódico.
function State.checkpoint(data)
    local count = data.moveCount or 0
    if count > 0 and count % Config.STATE_SAVE_INTERVAL == 0 then
        State.save(data)
    end
end

return State
