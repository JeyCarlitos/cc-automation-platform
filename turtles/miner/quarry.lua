-- turtles/miner/quarry.lua
-- Algoritmo de Quarry: pozo vertical + excavación capa por capa.
--
-- Fase 1 – SHAFT:
--   Excava un pozo de SHAFT_DEPTH bloques en línea recta hacia abajo.
--
-- Fase 2 – LAYERS:
--   Desde el fondo del pozo, mina una capa QUARRY_WIDTH x QUARRY_LENGTH
--   en patrón serpentín y luego sube a la siguiente capa.
--   Repite hasta cubrir los SHAFT_DEPTH niveles de abajo hacia arriba.
--
-- Patrón serpentín por capa (con 16x16 como ejemplo):
--
--   (0,0) → → → → → → → (15,0)
--                              ↓
--   (0,1) ← ← ← ← ← ← ← (15,1)
--     ↓
--   (0,2) → → → → → → → (15,2)
--   ...
--
-- Cada fila también excava el bloque de arriba (digUp) para dejar
-- el área completamente limpia.

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")
local State     = require("turtles.miner.state")

local Quarry = {}

-- ============================================================
-- Helper: volver a la columna del pozo (x=0, z=0) en el nivel actual
-- ============================================================

local function returnToShaftColumn()
    local p = Movement.getPos()

    -- Corregir X
    if p.x > 0 then
        Movement.faceDir("west")
        while Movement.getPos().x > 0 do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    elseif p.x < 0 then
        Movement.faceDir("east")
        while Movement.getPos().x < 0 do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end

    -- Corregir Z
    p = Movement.getPos()
    if p.z > 0 then
        Movement.faceDir("north")
        while Movement.getPos().z > 0 do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    elseif p.z < 0 then
        Movement.faceDir("south")
        while Movement.getPos().z < 0 do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end
end

-- ============================================================
-- Phase 1: SHAFT
-- ============================================================

function Quarry.digShaft(sessionData)
    local depth = Config.SHAFT_DEPTH
    local dug   = sessionData.shaftDug or 0

    Logger.info(string.format("Pozo: %d/%d bloques", dug, depth))

    for i = dug + 1, depth do
        -- Fuel: necesitamos bajar lo que falta y luego subir todo de vuelta
        if not Fuel.hasSufficient((depth - i + 1) + depth) then
            Logger.warn("Fuel insuficiente para continuar el pozo en bloque " .. i)
            sessionData.shaftDug = i - 1
            return "FUEL"
        end

        if Inventory.isFull() then
            Logger.warn("Inventario lleno en pozo bloque " .. i)
            sessionData.shaftDug = i - 1
            return "INVENTORY"
        end

        -- Excavar hacia abajo (maneja grava/arena que cae)
        local digs = 0
        while turtle.detectDown() and digs < 10 do
            turtle.digDown()
            sleep(0.3)
            digs = digs + 1
        end

        if not Movement.down() then
            Logger.warn("Bloqueado en pozo bloque " .. i)
            sessionData.shaftDug = i - 1
            return "BLOCKED"
        end

        sessionData.shaftDug  = i
        sessionData.moveCount = (sessionData.moveCount or 0) + 1
        State.checkpoint(sessionData)
    end

    Logger.info("Pozo completo (" .. depth .. " bloques)")
    return "COMPLETE"
end

-- ============================================================
-- Phase 2: Una capa del quarry (serpentín 16x16)
-- ============================================================

-- Mina una capa completa y regresa a la columna del pozo (x=0, z=0).
-- La turtle debe estar en (x=0, z=0) de la capa al llamar esta función.
-- Retorna "COMPLETE", "FUEL" o "INVENTORY".
local function mineLayer(layerNum, sessionData)
    local width  = Config.QUARRY_WIDTH   -- número de filas (eje Z)
    local length = Config.QUARRY_LENGTH  -- bloques por fila (eje X)

    Logger.info(string.format("Capa %d/%d", layerNum + 1, Config.SHAFT_DEPTH))

    -- Comenzar mirando hacia el este (fila 0 va en dirección +X)
    Movement.faceDir("east")

    for row = 0, width - 1 do

        -- Verificar condiciones al inicio de cada fila
        if not Fuel.hasSufficient((width - row) * length + width + 20) then
            Logger.warn("Fuel bajo en capa " .. layerNum .. " fila " .. row)
            returnToShaftColumn()
            sessionData.currentLayer = layerNum
            return "FUEL"
        end
        if Inventory.isFull() then
            Logger.warn("Inventario lleno en capa " .. layerNum .. " fila " .. row)
            returnToShaftColumn()
            sessionData.currentLayer = layerNum
            return "INVENTORY"
        end

        -- Minar la fila (length - 1 pasos: el primer bloque ya es la columna del pozo o el bloque anterior)
        for col = 0, length - 2 do
            turtle.digUp()        -- limpiar bloque del techo
            Movement.digForward() -- excavar y avanzar
            sessionData.moveCount = (sessionData.moveCount or 0) + 1
        end
        turtle.digUp()  -- techo del último bloque de la fila

        -- Paso al siguiente row (si no es el último)
        if row < width - 1 then
            if row % 2 == 0 then
                -- Fila par → mirando este → girar al sur, avanzar 1, girar al oeste
                Movement.turnRight()
                turtle.digUp()
                Movement.digForward()
                Movement.turnRight()
            else
                -- Fila impar → mirando oeste → girar al sur, avanzar 1, girar al este
                Movement.turnLeft()
                turtle.digUp()
                Movement.digForward()
                Movement.turnLeft()
            end
            sessionData.moveCount = (sessionData.moveCount or 0) + 2
        end

        State.checkpoint(sessionData)
    end

    -- Regresar a la columna del pozo (x=0, z=0)
    returnToShaftColumn()

    Logger.debug("Capa " .. layerNum .. " completada")
    return "COMPLETE"
end

-- ============================================================
-- Función principal
-- ============================================================

function Quarry.run(sessionData)
    sessionData.shaftDug     = sessionData.shaftDug     or 0
    sessionData.currentLayer = sessionData.currentLayer or 0

    local depth = Config.SHAFT_DEPTH

    -- Fase 1: pozo
    if sessionData.shaftDug < depth then
        local reason = Quarry.digShaft(sessionData)
        if reason ~= "COMPLETE" then
            return reason
        end
    end

    -- Fase 2: capas de abajo hacia arriba
    for layer = sessionData.currentLayer, depth - 1 do
        sessionData.currentLayer = layer

        local reason = mineLayer(layer, sessionData)
        if reason ~= "COMPLETE" then
            -- mineLayer ya hizo returnToShaftColumn antes de retornar
            return reason
        end

        -- Subir a la siguiente capa (si no es la última)
        if layer < depth - 1 then
            Movement.up()
            sessionData.moveCount = (sessionData.moveCount or 0) + 1
        end

        State.checkpoint(sessionData)
    end

    sessionData.currentLayer = depth
    Logger.info("Quarry completo!")
    return "COMPLETE"
end

return Quarry
