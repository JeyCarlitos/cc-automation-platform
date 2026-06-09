-- turtles/miner/quarry.lua
-- Quarry: pozo vertical + excavación capa por capa con manejo de lava.
--
-- Cuando detecta lava en cualquier dirección:
--   1. Busca un bloque sólido en el inventario (cobblestone, piedra, dirt…)
--   2. Lo coloca donde estaba la lava (la reemplaza)
--   3. Excava el bloque colocado y continúa normalmente
--   4. Reintenta hasta 3 veces por si la lava fluye de nuevo
--
-- Requisito: tener al menos algunos bloques sólidos en el inventario
-- (cobblestone, dirt, etc.) antes de iniciar en zonas con lava.
-- La propia turtle acumula cobblestone mientras mina.

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")
local State     = require("turtles.miner.state")

local Quarry = {}

-- ============================================================
-- Helpers: detección y sellado de lava
-- ============================================================

local function isLava(name)
    return name ~= nil and (name == "minecraft:lava" or name:find("lava") ~= nil)
end

-- Busca un bloque sólido en el inventario para sellar lava.
-- Prefiere cobblestone/stone/dirt. Si no hay, usa cualquier no-combustible.
local function findSealingSlot()
    local preferred = { "cobblestone", "stone", "dirt", "gravel", "netherrack", "deepslate" }

    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local d = turtle.getItemDetail(slot)
            if d then
                for _, p in ipairs(preferred) do
                    if d.name:find(p) then return slot end
                end
            end
        end
    end

    -- Segunda pasada: cualquier bloque que no sea combustible
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            if not turtle.refuel(0) then
                turtle.select(1)
                return slot
            end
        end
    end

    turtle.select(1)
    return nil
end

-- Sella lava en una dirección colocando un bloque sólido.
-- Reintenta hasta 3 veces (lava puede fluir de vuelta).
-- Retorna true si la dirección está segura para proceder.
local function sealLava(inspectFn, placeFn, dirName)
    for attempt = 1, 3 do
        local hasBlock, data = inspectFn()
        if not hasBlock or not isLava(data.name) then
            return true  -- sin lava, seguro
        end

        Logger.warn(string.format("Lava en %s (intento %d/3)", dirName, attempt))

        local slot = findSealingSlot()
        if not slot then
            Logger.error("Sin bloques para sellar lava en " .. dirName)
            return false
        end

        turtle.select(slot)
        if not placeFn() then
            Logger.warn("No se pudo colocar bloque en " .. dirName)
        end
        turtle.select(1)
        sleep(0.5)  -- esperar a que la lava adyacente fluya y se estabilice
    end

    -- Verificación final
    local hasBlock, data = inspectFn()
    if hasBlock and isLava(data.name) then
        Logger.error("No se pudo sellar lava en " .. dirName .. " tras 3 intentos")
        return false
    end

    Logger.info("Lava sellada en " .. dirName)
    return true
end

-- ============================================================
-- Wrappers de excavación seguros contra lava
-- ============================================================

-- Sella lava si hay, luego excava y avanza.
local function safeDigForward(sessionData)
    sealLava(turtle.inspect, turtle.place, "frente")
    if Movement.digForward() then
        if sessionData then
            sessionData.moveCount = (sessionData.moveCount or 0) + 1
        end
        return true
    end
    return false
end

-- Sella lava si hay, luego excava y baja.
local function safeDigDown(sessionData)
    if not sealLava(turtle.inspectDown, turtle.placeDown, "abajo") then
        return false
    end
    if Movement.digDown() then
        if sessionData then
            sessionData.moveCount = (sessionData.moveCount or 0) + 1
        end
        return true
    end
    return false
end

-- Sella lava en el techo si hay, luego excava hacia arriba.
-- Si no se puede sellar, deja el techo sin excavar (seguridad > cobertura).
local function safeDigUp()
    local hasBlock, data = turtle.inspectUp()
    if hasBlock and isLava(data.name) then
        Logger.warn("Lava en techo - sellando")
        local slot = findSealingSlot()
        if slot then
            turtle.select(slot)
            if turtle.placeUp() then
                turtle.select(1)
                sleep(0.3)
                -- Ahora el techo es un bloque sólido, excavar normalmente
                turtle.digUp()
                return
            end
            turtle.select(1)
        end
        Logger.warn("No se pudo sellar techo con lava - dejando")
        return
    end
    -- Sin lava: excavar normalmente
    turtle.digUp()
end

-- ============================================================
-- Helper: volver a columna del pozo (x=0, z=0)
-- ============================================================

local function returnToShaftColumn()
    local p = Movement.getPos()

    if p.x > 0 then
        Movement.faceDir("west")
        while Movement.getPos().x > 0 do
            sealLava(turtle.inspect, turtle.place, "frente")
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    elseif p.x < 0 then
        Movement.faceDir("east")
        while Movement.getPos().x < 0 do
            sealLava(turtle.inspect, turtle.place, "frente")
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end

    p = Movement.getPos()
    if p.z > 0 then
        Movement.faceDir("north")
        while Movement.getPos().z > 0 do
            sealLava(turtle.inspect, turtle.place, "frente")
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    elseif p.z < 0 then
        Movement.faceDir("south")
        while Movement.getPos().z < 0 do
            sealLava(turtle.inspect, turtle.place, "frente")
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
        if not Fuel.hasSufficient((depth - i + 1) + depth) then
            Logger.warn("Fuel insuficiente en pozo bloque " .. i)
            sessionData.shaftDug = i - 1
            return "FUEL"
        end

        if Inventory.isFull() then
            Logger.warn("Inventario lleno en pozo bloque " .. i)
            sessionData.shaftDug = i - 1
            return "INVENTORY"
        end

        -- Excavar con protección contra lava y grava/arena
        if not safeDigDown(sessionData) then
            -- safeDigDown ya loggeó el error
            sessionData.shaftDug = i - 1
            return "BLOCKED"
        end

        sessionData.shaftDug = i
        State.checkpoint(sessionData)
    end

    Logger.info("Pozo completo (" .. depth .. " bloques)")
    return "COMPLETE"
end

-- ============================================================
-- Phase 2: Una capa del quarry (serpentín seguro contra lava)
-- ============================================================

local function mineLayer(layerNum, sessionData)
    local width  = Config.QUARRY_WIDTH
    local length = Config.QUARRY_LENGTH

    Logger.info(string.format("Capa %d/%d", layerNum + 1, Config.SHAFT_DEPTH))

    Movement.faceDir("east")

    for row = 0, width - 1 do
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

        -- Minar la fila
        for col = 0, length - 2 do
            safeDigUp()
            safeDigForward(sessionData)
        end
        safeDigUp()  -- techo del último bloque

        -- Paso al siguiente row
        if row < width - 1 then
            if row % 2 == 0 then
                -- Mirando este → sur, avanzar 1, oeste
                Movement.turnRight()
                safeDigUp()
                safeDigForward(sessionData)
                Movement.turnRight()
            else
                -- Mirando oeste → sur, avanzar 1, este
                Movement.turnLeft()
                safeDigUp()
                safeDigForward(sessionData)
                Movement.turnLeft()
            end
        end

        State.checkpoint(sessionData)
    end

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
            return reason
        end

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
