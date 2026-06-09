-- turtles/miner/state.lua
-- Persistencia del estado de sesión — Chunk Quarry Vertical.
--
-- Formato del estado guardado:
-- {
--   phase           = "MINING_LAYER",
--   x=0, y=-5, z=0, dir="east",
--   currentLayer    = 2,
--   currentRow      = 5,
--   currentColumn   = 7,
--   moveCount       = 130,
--   returningReason = "LAYER_COMPLETE",  -- razón del último retorno
--   workPosition    = {                  -- dónde retomar tras descargar
--     x=7, y=-10, z=3, dir="east",
--     currentLayer=2, currentRow=5, currentColumn=7
--   }
-- }

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

-- Serializa 'data' y lo escribe en disco. Retorna true si tuvo éxito.
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
        "State saved: phase=%s layer=%d row=%d col=%d x=%d y=%d z=%d",
        tostring(data.phase),
        data.currentLayer  or 0,
        data.currentRow    or 0,
        data.currentColumn or 0,
        data.x or 0, data.y or 0, data.z or 0
    ))
    return true
end

-- Lee y deserializa el estado guardado.
-- Retorna la tabla, o nil si no existe o está corrupta.
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
        "Sesion anterior: phase=%s capa=%d fila=%d col=%d",
        tostring(data.phase),
        data.currentLayer  or 0,
        data.currentRow    or 0,
        data.currentColumn or 0
    ))
    return data
end

-- Borra el archivo de estado. Llamar al completar la sesión.
function State.clear()
    if fs.exists(Config.STATE_FILE) then
        fs.delete(Config.STATE_FILE)
        Logger.info("State cleared (sesion completada)")
    end
end

-- Guarda solo si moveCount es múltiplo del intervalo configurado.
function State.checkpoint(data)
    local count = data.moveCount or 0
    if count > 0 and count % Config.STATE_SAVE_INTERVAL == 0 then
        State.save(data)
    end
end

return State
