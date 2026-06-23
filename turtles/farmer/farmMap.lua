-- turtles/farmer/farmMap.lua
-- Persistencia del mapa de farmland descubierto por FarmScanner.
--
-- Formato en disco (textutils.serialise):
-- {
--   scannedAt = <número de día MC>,
--   plots     = { {x=int, z=int}, {x=int, z=int}, ... }
-- }
--
-- Todas las coordenadas son relativas a HOME (0,0) en el sistema de Movement.
--
-- Uso:
--   local FarmMap = require("turtles.farmer.farmMap")
--   FarmMap.save(plots)
--   local m = FarmMap.load()   -- { scannedAt=..., plots={...} } o nil
--   if FarmMap.hasMap() then ... end

local Logger = require("core.logger")

local FarmMap = {}

local MAP_FILE = "data/state/farm_map.json"

-- ============================================================
-- Helpers internos
-- ============================================================

local function ensureDirs()
    if not fs.exists("data")       then fs.makeDir("data")       end
    if not fs.exists("data/state") then fs.makeDir("data/state") end
end

-- ============================================================
-- API pública
-- ============================================================

-- Guarda el array de plots en disco.
-- plots: { {x=int, z=int}, ... }
-- Retorna true si se guardó correctamente.
function FarmMap.save(plots)
    ensureDirs()
    local data = {
        scannedAt = os.day(),
        plots     = plots,
    }
    local f = fs.open(MAP_FILE, "w")
    if not f then
        Logger.error("[FarmMap] No se pudo abrir para escritura: " .. MAP_FILE)
        return false
    end
    f.write(textutils.serialise(data))
    f.close()
    Logger.info(string.format("[FarmMap] %d plots guardados en %s", #plots, MAP_FILE))
    return true
end

-- Carga el mapa desde disco.
-- Retorna { scannedAt=..., plots={...} } o nil si no existe / está corrupto.
function FarmMap.load()
    if not fs.exists(MAP_FILE) then return nil end
    local f = fs.open(MAP_FILE, "r")
    if not f then return nil end
    local raw = f.readAll()
    f.close()
    if not raw or raw == "" then return nil end
    local data = textutils.unserialise(raw)
    if not data or not data.plots then
        Logger.warn("[FarmMap] Mapa corrupto en " .. MAP_FILE)
        return nil
    end
    return data
end

-- ¿Existe un mapa guardado con al menos un plot?
function FarmMap.hasMap()
    local m = FarmMap.load()
    return m ~= nil and #m.plots > 0
end

-- Borra el mapa del disco.
function FarmMap.clear()
    if fs.exists(MAP_FILE) then
        fs.delete(MAP_FILE)
        Logger.info("[FarmMap] Mapa borrado")
    end
end

return FarmMap
