-- turtles/farmer/farmerState.lua
-- Persistencia del estado de sesión de la Farming Turtle.
--
-- Guarda posición, dirección, fase e índice de plot para reanudar tras apagón.
--
-- Formato en disco:
-- {
--   phase            = "FARMING" | "RETURNING" | "UNLOADING" | "WAITING",
--   currentPlotIndex = int,
--   cycle            = int,
--   returningReason  = string | nil,
--   x = int, y = int, z = int,
--   dir = "north" | "south" | "east" | "west"
-- }
--
-- Uso:
--   local FarmerState = require("turtles.farmer.farmerState")
--   FarmerState.save(session)
--   local saved = FarmerState.load()

local Config   = require("config.config")
local Logger   = require("core.logger")
local Movement = require("core.movement")

local FarmerState = {}

local STATE_FILE = Config.FARMER_STATE_FILE or "data/state/farmer.json"

-- ============================================================
-- Helpers internos
-- ============================================================

local function ensureDirs()
    if not fs.exists("data")       then fs.makeDir("data")       end
    if not fs.exists("data/state") then fs.makeDir("data/state") end
end

-- Inyecta la posición actual de Movement en la tabla sess.
local function capturePos(sess)
    local p  = Movement.getPos()
    sess.x   = p.x
    sess.y   = p.y
    sess.z   = p.z
    sess.dir = Movement.getDir()
    return sess
end

-- ============================================================
-- API pública
-- ============================================================

-- Guarda el estado actual a disco.
-- sess debe tener: phase, currentPlotIndex, cycle, returningReason (puede ser nil).
-- La posición se captura automáticamente de Movement.
-- Retorna true si se guardó correctamente.
function FarmerState.save(sess)
    ensureDirs()
    local data = capturePos({
        phase            = sess.phase,
        currentPlotIndex = sess.currentPlotIndex,
        cycle            = sess.cycle,
        returningReason  = sess.returningReason,
    })
    local f = fs.open(STATE_FILE, "w")
    if not f then
        Logger.error("[FarmerState] No se pudo abrir: " .. STATE_FILE)
        return false
    end
    f.write(textutils.serialise(data))
    f.close()
    return true
end

-- Carga el estado desde disco.
-- Retorna tabla con los campos o nil si no existe / está corrupto.
function FarmerState.load()
    if not fs.exists(STATE_FILE) then return nil end
    local f = fs.open(STATE_FILE, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    if not raw or raw == "" then return nil end
    local data = textutils.unserialise(raw)
    if not data then
        Logger.warn("[FarmerState] Estado corrupto, ignorando")
        return nil
    end
    return data
end

-- ¿Existe un archivo de estado guardado?
function FarmerState.exists()
    return fs.exists(STATE_FILE)
end

-- Borra el archivo de estado del disco.
function FarmerState.clear()
    if fs.exists(STATE_FILE) then
        fs.delete(STATE_FILE)
        Logger.info("[FarmerState] Estado borrado")
    end
end

return FarmerState
