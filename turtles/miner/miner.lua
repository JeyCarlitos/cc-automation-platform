-- turtles/miner/miner.lua
-- Orquestador — Chunk Quarry Vertical.
--
-- Máquina de estados:
--
--   PREPARING
--     ↓
--   DESCENDING_TO_START        (baja START_OFFSET_DOWN bloques)
--     ↓
--   MINING_LAYER               (serpentín 16×16)
--     ↓ INVENTORY_FULL / FUEL_LOW / LAYER_COMPLETE
--   RETURNING_TO_BASE
--     ↓
--   UNLOADING
--     ↓
--   RETURNING_TO_WORK          (si la capa no terminó)
--     ↓ (si terminó la capa)
--   DESCENDING_NEXT_LAYER
--     ↓
--   MINING_LAYER  ...repite...
--     ↓ BEDROCK
--   RETURNING_TO_BASE → UNLOADING → COMPLETE

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")
local State     = require("turtles.miner.state")
local Quarry    = require("turtles.miner.quarry")

local Miner = {}

-- ============================================================
-- Sesión (se rellena desde disco o desde cero)
-- ============================================================

local session = {
    phase           = "PREPARING",
    x               = 0, y = 0, z = 0, dir = "north",
    currentLayer    = 0,
    currentRow      = 0,
    currentColumn   = 0,
    moveCount       = 0,
    returningReason = nil,
    workPosition    = nil,
}

-- ============================================================
-- Helpers
-- ============================================================

local function snapshot(phase)
    local p = Movement.getPos()
    return {
        phase           = phase or session.phase,
        x               = p.x,
        y               = p.y,
        z               = p.z,
        dir             = Movement.getDir(),
        currentLayer    = session.currentLayer,
        currentRow      = session.currentRow,
        currentColumn   = session.currentColumn,
        moveCount       = session.moveCount,
        returningReason = session.returningReason,
        workPosition    = session.workPosition,
    }
end

-- Navega a {x=0, z=0, y=0} (punto inicial / cofre).
--
-- ORDEN CORRECTO:
--   1. Navegar horizontalmente a x=0, z=0 en el nivel actual (zona minada = aire)
--   2. Subir por el pozo central hasta y=0
--
-- NO subir primero: si la turtle está en x=7, z=3 y sube primero,
-- escava fuera del pozo y llega a la superficie en el lugar equivocado.
local function returnToBase()
    local p = Movement.getPos()
    Logger.info(string.format(
        "returnToBase: desde x=%d y=%d z=%d dir=%s",
        p.x, p.y, p.z, Movement.getDir()
    ))

    -- ── Paso 1: navegar a x=0 ────────────────────────────────────
    while Movement.getPos().x ~= 0 do
        sleep(0)
        local d = Movement.getPos().x > 0 and "west" or "east"
        Movement.faceDir(d)
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then
            -- bloqueo temporal (entidad, arena cayendo): esperar y reintentar
            sleep(0.5)
        end
    end

    -- ── Paso 2: navegar a z=0 ────────────────────────────────────
    while Movement.getPos().z ~= 0 do
        sleep(0)
        local d = Movement.getPos().z > 0 and "north" or "south"
        Movement.faceDir(d)
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then
            sleep(0.5)
        end
    end

    Logger.info(string.format(
        "En columna del pozo: x=%d z=%d y=%d — subiendo",
        Movement.getPos().x, Movement.getPos().z, Movement.getPos().y
    ))

    -- ── Paso 3: subir por el pozo hasta y=0 ─────────────────────
    local stuckCount = 0
    while Movement.getPos().y < 0 do
        sleep(0)
        local hasBlock, data = turtle.inspectUp()
        if hasBlock then
            if data and isUnbreakableLocal(data.name) then
                Logger.error("Irrompible en techo del pozo en y=" .. Movement.getPos().y)
                stuckCount = stuckCount + 1
                if stuckCount > 6 then break end
                -- Intentar moverse lateralmente para salir del irrompible
                Movement.turnRight()
                if not turtle.detect() then Movement.forward() end
            else
                turtle.digUp()
                if not Movement.up() then sleep(0.5) end
            end
        else
            if not Movement.up() then sleep(0.5) end
        end
    end

    Movement.faceDir("north")
    Logger.info(string.format(
        "BASE ALCANZADA: x=%d y=%d z=%d",
        Movement.getPos().x, Movement.getPos().y, Movement.getPos().z
    ))
end

-- Descarga el inventario en el cofre y recarga combustible.
-- El cofre debe estar en la dirección Config.CHEST_DIRECTION
-- relativa al punto de origen {0,0,0} con la turtle mirando norte.
local function unloadAndRefuel()
    local p = Movement.getPos()
    Logger.info(string.format(
        "unloadAndRefuel: en x=%d y=%d z=%d, cofre=%s",
        p.x, p.y, p.z, Config.CHEST_DIRECTION
    ))

    -- Orientarse hacia el cofre
    local chest = Config.CHEST_DIRECTION
    if chest == "back" then
        Movement.faceDir("south")
    elseif chest == "left" then
        Movement.faceDir("west")
    elseif chest == "right" then
        Movement.faceDir("east")
    else  -- "front"
        Movement.faceDir("north")
    end

    Inventory.dropAll("forward")
    Fuel.refuelFromInventory()
    Movement.faceDir("north")
    Logger.info("Descarga completa. Fuel: " .. Fuel.getLevel())
end

-- Navega desde x=0,z=0 hasta workPosition.x, workPosition.z en el nivel actual.
local function travelToWorkXZ(wp)
    -- Corregir X
    while Movement.getPos().x ~= wp.x do
        sleep(0)
        Movement.faceDir(Movement.getPos().x < wp.x and "east" or "west")
        if turtle.detect() then turtle.dig() end
        Movement.forward()
    end
    -- Corregir Z
    while Movement.getPos().z ~= wp.z do
        sleep(0)
        Movement.faceDir(Movement.getPos().z < wp.z and "south" or "north")
        if turtle.detect() then turtle.dig() end
        Movement.forward()
    end
    Movement.faceDir(wp.dir)
    Logger.info(string.format("Posicion restaurada x=%d y=%d z=%d dir=%s",
        wp.x, wp.y, wp.z, wp.dir))
end

-- Validar condiciones de inicio.
local function validatePreConditions()
    Logger.info("Validando condiciones iniciales...")
    if Fuel.getLevel() < Config.FUEL_MINIMUM then
        Fuel.refuelFromInventory()
        if Fuel.getLevel() < Config.FUEL_MINIMUM then
            Logger.error("Fuel critico (" .. Fuel.getLevel() .. "). Agrega combustible.")
            return false
        end
    end
    if Inventory.isFull() then
        Logger.warn("Inventario lleno al iniciar. Descargando...")
        unloadAndRefuel()
    end
    Logger.info("Condiciones OK. Fuel: " .. Fuel.getLevel())
    return true
end

-- ============================================================
-- Nota: isUnbreakableLocal es una copia local para no
-- requerir quarry.lua desde miner.lua en ascendToBase.
-- ============================================================

local UNBREAKABLE_LOCAL = {
    ["minecraft:bedrock"] = true, ["minecraft:barrier"] = true,
    ["minecraft:command_block"] = true, ["minecraft:chain_command_block"] = true,
    ["minecraft:repeating_command_block"] = true,
    ["minecraft:end_portal_frame"] = true, ["minecraft:reinforced_deepslate"] = true,
}
isUnbreakableLocal = function(name)
    return name ~= nil and UNBREAKABLE_LOCAL[name] == true
end

-- ============================================================
-- Función principal
-- ============================================================

function Miner.run()
    Logger.info("=== CCAP Miner v2 (Chunk Quarry Vertical) ===")

    -- Fases válidas del nuevo sistema. Cualquier otra (ej. "SHAFT" del código viejo)
    -- se descarta para evitar loops infinitos sin yield.
    local VALID_PHASES = {
        PREPARING=true, IDLE=true, DESCENDING_TO_START=true, MINING_LAYER=true,
        RETURNING_TO_BASE=true, UNLOADING=true, RETURNING_TO_WORK=true,
        DESCENDING_NEXT_LAYER=true, COMPLETE=true, ERROR=true,
    }

    -- Intentar recuperar sesión anterior
    local saved = State.load()
    if saved then
        local loadedPhase = saved.phase or "PREPARING"
        if not VALID_PHASES[loadedPhase] then
            Logger.warn(string.format(
                "Fase '%s' no reconocida (sesion de version anterior). Reiniciando.",
                tostring(loadedPhase)
            ))
            State.clear()
            saved = nil
        end
    end

    if saved then
        session.phase           = saved.phase           or "PREPARING"
        session.currentLayer    = saved.currentLayer    or 0
        session.currentRow      = saved.currentRow      or 0
        session.currentColumn   = saved.currentColumn   or 0
        session.moveCount       = saved.moveCount       or 0
        session.returningReason = saved.returningReason
        session.workPosition    = saved.workPosition
        Movement.setState(
            { x = saved.x or 0, y = saved.y or 0, z = saved.z or 0 },
            saved.dir or "north"
        )
        Logger.info(string.format(
            "Reanudando: phase=%s capa=%d fila=%d col=%d",
            session.phase, session.currentLayer,
            session.currentRow, session.currentColumn
        ))
    else
        Movement.resetState()
        Logger.info("Nueva sesion de quarry")
    end

    -- ============================================================
    -- Resolver fases de retorno incompletas al reanudar
    -- ============================================================

    local phase = session.phase

    if phase == "RETURNING_TO_BASE" then
        returnToBase()
        unloadAndRefuel()
        phase = (session.returningReason == "LAYER_COMPLETE" or
                 session.returningReason == nil)
                and "DESCENDING_NEXT_LAYER"
                or  "RETURNING_TO_WORK"
        session.phase = phase

    elseif phase == "UNLOADING" then
        unloadAndRefuel()
        phase = (session.returningReason == "LAYER_COMPLETE" or
                 session.returningReason == nil)
                and "DESCENDING_NEXT_LAYER"
                or  "RETURNING_TO_WORK"
        session.phase = phase

    elseif phase == "PREPARING" or phase == "IDLE" then
        if not validatePreConditions() then return end
        session.phase = "DESCENDING_TO_START"
        phase = session.phase
    end

    -- ============================================================
    -- Reanudar fases activas
    -- ============================================================

    if phase == "RETURNING_TO_WORK" then
        -- Bajar al nivel correcto y reposicionarse
        Quarry.descendToLayer(session, session.currentLayer)
        if session.workPosition then
            travelToWorkXZ(session.workPosition)
        end
        phase = "MINING_LAYER"
        session.phase = phase

    elseif phase == "DESCENDING_TO_START" then
        -- El bucle principal maneja esta fase
        -- (no hacer nada aquí, dejar que entre al while)

    elseif phase == "DESCENDING_NEXT_LAYER" then
        local nextLayer = session.currentLayer + 1
        -- Verificar límite de capas al reanudar
        if Config.MAX_LAYERS and nextLayer >= Config.MAX_LAYERS then
            Logger.info("Límite de capas alcanzado al reanudar. Regresando a base.")
            returnToBase()
            unloadAndRefuel()
            State.clear()
            print("Quarry completo! Limite de capas alcanzado.")
            return
        end
        local result = Quarry.descendToLayer(session, nextLayer)
        if result == "BEDROCK" then
            State.save(snapshot("RETURNING_TO_BASE"))
            session.returningReason = "LAYER_COMPLETE"
            returnToBase()
            unloadAndRefuel()
            State.clear()
            Logger.info("=== Quarry finalizado por bedrock al reanudar ===")
            print("Quarry completo! Bedrock encontrado.")
            return
        end
        session.currentLayer    = nextLayer
        session.currentRow      = 0
        session.currentColumn   = 0
        session.phase = "MINING_LAYER"
        phase = "MINING_LAYER"
    end

    -- ============================================================
    -- Bucle principal
    -- ============================================================

    while phase ~= "COMPLETE" and phase ~= "ERROR" do
        sleep(0)  -- yield de seguridad: evita "Too long without yielding"

        -- ── DESCENDING_TO_START ────────────────────────────────
        if phase == "DESCENDING_TO_START" then
            State.save(snapshot("DESCENDING_TO_START"))
            -- Desciende a la Y absoluta de la capa 0: y = -(START_OFFSET_DOWN)
            local result = Quarry.descendToLayer(session, 0)
            if result == "BEDROCK" then
                Logger.warn("Bedrock al bajar al offset inicial. Terminando.")
                returnToBase()
                unloadAndRefuel()
                phase = "COMPLETE"
            else
                session.currentLayer = 0
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
            end

        -- ── MINING_LAYER ───────────────────────────────────────
        elseif phase == "MINING_LAYER" then
            State.save(snapshot("MINING_LAYER"))
            Logger.info(string.format("=== Capa %d ===", session.currentLayer))

            local result = Quarry.mineLayer(session)

            if result == "INVENTORY_FULL" or result == "FUEL_LOW" then
                -- Regresar al cofre y volver exactamente donde estaba
                session.returningReason = result
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()

                session.phase = "UNLOADING"
                unloadAndRefuel()

                -- Verificar fuel suficiente para continuar
                local fuelNeeded = Config.QUARRY_WIDTH * Config.QUARRY_LENGTH + 50
                if not Fuel.ensureFuel(fuelNeeded) then
                    Logger.error("Sin fuel suficiente tras reabastecimiento. Abortando.")
                    phase = "ERROR"
                    break
                end

                -- Volver al punto exacto de trabajo
                session.phase = "RETURNING_TO_WORK"
                State.save(snapshot("RETURNING_TO_WORK"))
                if session.workPosition then
                    local wp = session.workPosition
                    -- Usar descendToLayer para llegar a la Y correcta con detección de bedrock
                    Quarry.descendToLayer(session, session.currentLayer)
                    travelToWorkXZ(wp)
                end
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"

            else  -- result == "COMPLETE"
                -- Capa terminada — solo subir si RETURN_AFTER_EACH_LAYER está activo
                if Config.RETURN_AFTER_EACH_LAYER then
                    session.returningReason = "LAYER_COMPLETE"
                    session.phase = "RETURNING_TO_BASE"
                    State.save(snapshot("RETURNING_TO_BASE"))
                    returnToBase()

                    session.phase = "UNLOADING"
                    unloadAndRefuel()
                end

                -- Intentar bajar a la siguiente capa
                session.phase = "DESCENDING_NEXT_LAYER"
                State.save(snapshot("DESCENDING_NEXT_LAYER"))
                phase = "DESCENDING_NEXT_LAYER"
            end

        -- ── DESCENDING_NEXT_LAYER ──────────────────────────────
        elseif phase == "DESCENDING_NEXT_LAYER" then
            local nextLayer = session.currentLayer + 1

            -- Verificar límite de capas (MAX_LAYERS)
            if Config.MAX_LAYERS and nextLayer >= Config.MAX_LAYERS then
                Logger.info(string.format(
                    "Límite de capas alcanzado (%d). Finalizando quarry.",
                    Config.MAX_LAYERS
                ))
                session.returningReason = "LAYER_COMPLETE"
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                phase = "COMPLETE"
            else
                -- La siguiente capa tiene un Y absoluto basado en su número.
                -- Funciona tanto si la turtle está en y=0 (RETURN_AFTER_EACH_LAYER)
                -- como si está en la capa anterior (sin retorno entre capas).
                local result = Quarry.descendToLayer(session, nextLayer)

                if result == "BEDROCK" then
                    Logger.info("Bedrock encontrado: quarry terminado")
                    session.returningReason = "LAYER_COMPLETE"
                    session.phase = "RETURNING_TO_BASE"
                    State.save(snapshot("RETURNING_TO_BASE"))
                    returnToBase()
                    unloadAndRefuel()
                    phase = "COMPLETE"
                else
                    session.currentLayer    = nextLayer
                    session.currentRow      = 0
                    session.currentColumn   = 0
                    session.workPosition    = nil
                    session.phase = "MINING_LAYER"
                    phase = "MINING_LAYER"
                    Logger.info(string.format("En capa %d", nextLayer))
                end
            end

        else
            -- Fase no reconocida: no debería llegar aquí, pero si ocurre
            -- evitamos un loop infinito sin yield.
            Logger.error("Fase no reconocida en bucle: " .. tostring(phase))
            phase = "ERROR"
        end
    end

    -- ============================================================
    -- Fin
    -- ============================================================

    if phase == "COMPLETE" then
        State.clear()
        Logger.info(string.format(
            "=== Quarry completado. %d capas minadas ===",
            session.currentLayer
        ))
        print("")
        print("Quarry completo!")
        print("Capas minadas: " .. session.currentLayer)
        print("Ejecuta 'startup' para iniciar un nuevo quarry.")
    else
        Logger.error("Quarry abortado en fase ERROR")
        State.save(snapshot("ERROR"))
        print("ERROR: quarry abortado. Revisa data/logs/miner.log")
    end
end

return Miner
