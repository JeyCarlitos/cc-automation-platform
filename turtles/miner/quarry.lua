-- turtles/miner/quarry.lua
-- Chunk Quarry Vertical — lógica de excavación por capa.
--
-- Responsabilidades:
--   • Excavar una capa 16×16 en patrón serpentín.
--   • Reanudar desde currentRow/currentColumn tras un retorno.
--   • Bajar un bloque entre capas y detectar bedrock.
--   • Manejar lava y bloques irrompibles.
--   • Retornar señales al orquestador (miner.lua) para FUEL_LOW,
--     INVENTORY_FULL y LAYER_COMPLETE.
--
-- REGLA: todo movimiento pasa por movement.lua.

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")
local State     = require("turtles.miner.state")

local Quarry = {}

-- ============================================================
-- Bloques irrompibles conocidos
-- ============================================================

local UNBREAKABLE = {
    ["minecraft:bedrock"]                    = true,
    ["minecraft:barrier"]                    = true,
    ["minecraft:command_block"]              = true,
    ["minecraft:chain_command_block"]        = true,
    ["minecraft:repeating_command_block"]    = true,
    ["minecraft:end_portal_frame"]           = true,
    ["minecraft:reinforced_deepslate"]       = true,
}

local function isUnbreakable(name)
    return name ~= nil and UNBREAKABLE[name] == true
end

local function isLava(name)
    return name ~= nil and (name == "minecraft:lava" or name:find("lava") ~= nil)
end

-- ============================================================
-- Clasificar bloque
-- Retorna: "air" | "lava" | "unbreakable" | "normal"
-- ============================================================

local function classifyBlock(inspectFn)
    local hasBlock, data = inspectFn()
    if not hasBlock            then return "air"         end
    if isLava(data.name)       then return "lava"        end
    if isUnbreakable(data.name) then return "unbreakable" end
    return "normal"
end

-- ============================================================
-- Sellar lava
-- ============================================================

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
    -- Cualquier bloque no-combustible
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

local function sealLava(inspectFn, placeFn, dirName)
    for attempt = 1, 3 do
        local hasBlock, data = inspectFn()
        if not hasBlock or not isLava(data.name) then return true end
        Logger.warn(string.format("Lava en %s (intento %d/3)", dirName, attempt))
        local slot = findSealingSlot()
        if not slot then
            Logger.error("Sin bloques para sellar lava en " .. dirName)
            return false
        end
        turtle.select(slot)
        placeFn()
        turtle.select(1)
        sleep(0.5)
    end
    local hasBlock, data = inspectFn()
    if hasBlock and isLava(data.name) then
        Logger.error("No se pudo sellar lava en " .. dirName)
        return false
    end
    return true
end

-- ============================================================
-- Excavaciones seguras
-- ============================================================

-- Excavar frente: retorna false si irrompible (no avanza).
local function safeDigForward(session)
    local kind = classifyBlock(turtle.inspect)
    if kind == "lava" then
        if not sealLava(turtle.inspect, turtle.place, "frente") then return false end
    elseif kind == "unbreakable" then
        local _, data = turtle.inspect()
        Logger.warn("Irrompible al frente: " .. (data and data.name or "?"))
        return false
    end
    if Movement.digForward() then
        session.moveCount = (session.moveCount or 0) + 1
        return true
    end
    return false
end

-- Excavar abajo: retorna false si irrompible (bedrock).
local function safeDigDown(session)
    local kind = classifyBlock(turtle.inspectDown)
    if kind == "lava" then
        if not sealLava(turtle.inspectDown, turtle.placeDown, "abajo") then return false end
    elseif kind == "unbreakable" then
        local _, data = turtle.inspectDown()
        Logger.warn("Irrompible abajo: " .. (data and data.name or "?"))
        return false
    end
    -- Grava/arena que cae
    local digs = 0
    while turtle.detectDown() and digs < 10 do
        turtle.digDown()
        sleep(0.3)
        digs = digs + 1
    end
    if Movement.down() then
        session.moveCount = (session.moveCount or 0) + 1
        return true
    end
    return false
end

-- Excavar techo sin moverse (limpieza de altura doble).
local function safeDigUp()
    local kind = classifyBlock(turtle.inspectUp)
    if kind == "lava" then
        local slot = findSealingSlot()
        if slot then
            turtle.select(slot)
            if turtle.placeUp() then
                turtle.select(1)
                sleep(0.3)
                turtle.digUp()
                return
            end
            turtle.select(1)
        end
        Logger.warn("No se pudo sellar lava en techo")
        return
    elseif kind == "unbreakable" then
        return  -- dejar techo irrompible sin tocar
    end
    turtle.digUp()
end

-- ============================================================
-- Retorno a la columna de origen (x=0, z=0)
-- Si el camino horizontal está bloqueado por irrompibles, sube.
-- ============================================================

local function returnToOriginColumn()
    local MAX_CLIMB = 20

    local function navigateAxis(getVal, posDir, negDir)
        local climbed = 0
        while getVal() ~= 0 do
            sleep(0)  -- yield: turtle.inspect no hace yield por sí solo
            local targetDir = getVal() > 0 and posDir or negDir
            Movement.faceDir(targetDir)
            local kind = classifyBlock(turtle.inspect)
            if kind == "air" then
                Movement.forward()
            elseif kind == "lava" then
                sealLava(turtle.inspect, turtle.place, targetDir)
                turtle.dig()
                Movement.forward()
            elseif kind == "unbreakable" then
                if climbed >= MAX_CLIMB then
                    Logger.error("No se puede volver al origen: irrompibles")
                    return false
                end
                safeDigUp()
                Movement.up()
                climbed = climbed + 1
            else
                turtle.dig()
                Movement.forward()
            end
        end
        return true
    end

    -- Corregir X primero, luego Z
    navigateAxis(function() return Movement.getPos().x end, "west", "east")
    navigateAxis(function() return Movement.getPos().z end, "north", "south")
end

-- ============================================================
-- API pública: Quarry.descendToLayer
--
-- Desciende desde la posición actual hasta el nivel absoluto de targetLayer.
--   targetLayer 0 → y = -(START_OFFSET_DOWN)
--   targetLayer N → y = -(START_OFFSET_DOWN + N * LAYER_HEIGHT)
--
-- Funciona tanto si la turtle está en y=0 (tras RETURN_AFTER_EACH_LAYER)
-- como si está en la capa anterior (sin retorno).
--
-- Retorna: "OK" | "BEDROCK"
-- ============================================================

function Quarry.descendToLayer(session, targetLayer)
    local targetY = -(Config.START_OFFSET_DOWN + targetLayer * Config.LAYER_HEIGHT)
    Logger.info(string.format(
        "Bajando a capa %d (y=%d) desde y=%d",
        targetLayer, targetY, Movement.getPos().y
    ))

    while Movement.getPos().y > targetY do
        sleep(0)  -- yield: turtle.inspectDown no hace yield por sí solo

        local kind = classifyBlock(turtle.inspectDown)
        if kind == "unbreakable" then
            Logger.info(string.format(
                "Bloque irrompible al bajar a capa %d en y=%d",
                targetLayer, Movement.getPos().y - 1
            ))
            return "BEDROCK"
        end

        if not safeDigDown(session) then
            Logger.warn("No se pudo bajar al intentar llegar a capa " .. targetLayer)
            return "BEDROCK"  -- tratar como fin del quarry
        end
    end

    Logger.debug(string.format("En capa %d (y=%d)", targetLayer, Movement.getPos().y))
    return "OK"
end

-- ============================================================
-- API pública: Quarry.mineLayer
--
-- Mina una capa 16×16 en patrón serpentín, reanudando desde
-- session.currentRow / session.currentColumn.
--
-- Retorna:
--   "COMPLETE"       — capa terminada
--   "INVENTORY_FULL" — inventario lleno (posición guardada en workPosition)
--   "FUEL_LOW"       — combustible insuficiente (posición guardada)
-- ============================================================

function Quarry.mineLayer(session)
    local W = Config.QUARRY_WIDTH   -- 16 filas (Z)
    local L = Config.QUARRY_LENGTH  -- 16 bloques por fila (X)

    local startRow = session.currentRow    or 0
    local startCol = session.currentColumn or 0

    Logger.info(string.format(
        "Capa %d: minando desde fila %d col %d",
        session.currentLayer, startRow, startCol
    ))

    -- Helper: sincronizar x,y,z,dir del objeto session con la posición real del tracker.
    -- CRÍTICO: session.x/y/z/dir NO se actualizan automáticamente al moverse.
    -- Sin esto, State.save(session) / State.checkpoint(session) guardan 0,0,0 y al
    -- reanudar Movement.setState restaura el origen en vez de la posición real.
    local function syncPos()
        local p = Movement.getPos()
        session.x   = p.x
        session.y   = p.y
        session.z   = p.z
        session.dir = Movement.getDir()
    end

    -- Helper: guardar workPosition y retornar al origen
    local function saveAndReturn(reason)
        local p = Movement.getPos()
        session.workPosition = {
            x             = p.x,
            y             = p.y,
            z             = p.z,
            dir           = Movement.getDir(),
            currentLayer  = session.currentLayer,
            currentRow    = session.currentRow,
            currentColumn = session.currentColumn,
        }
        session.returningReason = reason
        syncPos()
        State.save(session)

        returnToOriginColumn()
        return reason
    end

    -- Orientación inicial de la capa.
    -- Fila par → minamos hacia +X (east). Fila impar → hacia -X (west).
    -- Al reanudar a mitad de fila debemos orientarnos correctamente.
    local function rowDir(row)
        return (row % 2 == 0) and "east" or "west"
    end

    for row = startRow, W - 1 do
        session.currentRow = row

        -- Fila par: de col 0→L-1 (east). Fila impar: de col L-1→0 (west).
        local colStart, colEnd, colStep
        if row % 2 == 0 then
            colStart = (row == startRow) and startCol or 0
            colEnd   = L - 2   -- L-1 avances para cubrir L bloques
            colStep  = 1
        else
            colStart = (row == startRow) and startCol or (L - 2)
            colEnd   = 0
            colStep  = -1
        end

        -- Orientar al inicio de la fila
        Movement.faceDir(rowDir(row))

        -- Minar los bloques de la fila
        local col = colStart
        while (colStep == 1 and col <= colEnd) or (colStep == -1 and col >= colEnd) do
            sleep(0)  -- yield de seguridad por iteración
            session.currentColumn = col

            -- Verificar fuel e inventario antes de cada paso
            local fuelNeeded = (W - row) * L + W + 20
            if not Fuel.hasSufficient(fuelNeeded) then
                Logger.warn(string.format("Fuel bajo en capa %d fila %d col %d",
                    session.currentLayer, row, col))
                return saveAndReturn("FUEL_LOW")
            end
            if Inventory.isFull() then
                Logger.warn(string.format("Inventario lleno en capa %d fila %d col %d",
                    session.currentLayer, row, col))
                return saveAndReturn("INVENTORY_FULL")
            end

            safeDigUp()

            -- Avanzar (ignorar irrompibles: volver al origen de la fila no es necesario,
            -- simplemente dejamos ese bloque y saltamos la celda)
            local kind = classifyBlock(turtle.inspect)
            if kind == "unbreakable" then
                Logger.warn(string.format("Bloque irrompible en fila %d col %d — saltando celda", row, col))
                -- No avanzamos, pero sí continuamos el loop (la turtle se queda en sitio)
                -- Esto significa que esa celda queda sin minar pero no bloqueamos el progreso.
                -- En la siguiente iteración el loop terminará o girará a la siguiente fila.
                -- Para que el pattern no se rompa, aquí abortamos la fila y vamos a la siguiente.
                break
            end

            if not safeDigForward(session) then
                Logger.warn("No se pudo avanzar en fila " .. row .. " — abortando fila")
                break
            end

            syncPos()
            State.checkpoint(session)
            col = col + colStep
        end

        -- safeDigUp en el último bloque de la fila (posición actual)
        safeDigUp()

        -- Girar y avanzar a la siguiente fila (excepto en la última)
        if row < W - 1 then
            if row % 2 == 0 then
                -- Terminamos mirando east, giramos south para avanzar en Z
                Movement.faceDir("south")
            else
                -- Terminamos mirando west, giramos south para avanzar en Z
                Movement.faceDir("south")
            end

            -- Verificar obstáculo al avanzar entre filas
            local kind = classifyBlock(turtle.inspect)
            if kind == "unbreakable" then
                Logger.warn("Irrompible al avanzar a fila " .. (row+1) .. " — abortando capa")
                session.currentRow    = row + 1
                session.currentColumn = 0
                returnToOriginColumn()
                session.returningReason = "LAYER_COMPLETE"
                return "COMPLETE"
            end
            safeDigUp()
            if not safeDigForward(session) then
                Logger.warn("No se pudo avanzar a la fila " .. (row+1))
            end

            syncPos()
            State.checkpoint(session)
        end
    end

    -- Capa completada: volver al origen de la columna
    session.currentRow    = 0
    session.currentColumn = 0
    returnToOriginColumn()

    Logger.info(string.format("Capa %d completada", session.currentLayer))
    return "COMPLETE"
end

return Quarry
