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

-- Sube hasta y == 0 excavando lo necesario (el pozo ya está despejado).
local function ascendToBase()
    Logger.info(string.format(
        "Subiendo a base desde y=%d (x=%d z=%d)",
        Movement.getPos().y, Movement.getPos().x, Movement.getPos().z
    ))
    local stuckCount = 0
    while Movement.getPos().y < 0 do
        local hasBlock, data = turtle.inspectUp()
        if hasBlock then
            if data and isUnbreakableLocal(data.name) then
                -- Bedrock en techo: intentar escape lateral
                Logger.warn("Techo irrompible al subir — buscando escape lateral")
                local escaped = false
                for _ = 1, 4 do
                    Movement.turnRight()
                    if not turtle.detect() then
                        Movement.forward()
                        escaped = true
                        break
                    end
                end
                if not escaped then
                    stuckCount = stuckCount + 1
                    if stuckCount > 10 then
                        Logger.error("Atrapado bajo bloque irrompible, abortando subida")
                        break
                    end
                end
            else
                turtle.digUp()
                Movement.up()
            end
        else
            Movement.up()
        end
    end
    Logger.info("En Y=0")
end

-- Sube a base orientándose al cofre y descarga todo.
local function returnToBase()
    -- 1. Navegar al origen de la columna (x=0, z=0) en el nivel actual.
    --    Usamos la misma lógica que quarry.lua pero aquí en miner para
    --    no re-requerir quarry (que tiene esa función local).
    --    En cambio, simplemente subimos primero (el pozo está despejado).

    -- Subir hasta Y=0
    ascendToBase()

    -- Ajustar X
    local function digAndMove(dir)
        Movement.faceDir(dir)
        if turtle.detect() then turtle.dig() end
        Movement.forward()
    end

    while Movement.getPos().x > 0 do digAndMove("west")  end
    while Movement.getPos().x < 0 do digAndMove("east")  end
    while Movement.getPos().z > 0 do digAndMove("north") end
    while Movement.getPos().z < 0 do digAndMove("south") end

    Movement.faceDir("north")
    Logger.info("Turtle en base {0,0,0}")
end

-- Descargar inventario y reabastecer fuel.
local function unloadAndRefuel()
    Logger.info("Descargando inventario (" .. Config.CHEST_DIRECTION .. ")")

    local chest = Config.CHEST_DIRECTION
    if chest == "back" then
        Movement.faceDir("south")
    elseif chest == "left" then
        Movement.faceDir("west")
    elseif chest == "right" then
        Movement.faceDir("east")
    elseif chest == "front" then
        Movement.faceDir("north")
    end

    Inventory.dropAll("forward")
    Fuel.refuelFromInventory()
    Movement.faceDir("north")
    Logger.info("Descarga completa. Fuel: " .. Fuel.getLevel())
end

-- Baja desde y=0 hasta la Y objetivo (columna del pozo despejada).
local function descendToY(targetY)
    Logger.info(string.format("Bajando a y=%d desde y=%d", targetY, Movement.getPos().y))
    Movement.faceDir("north")
    while Movement.getPos().y > targetY do
        if turtle.detectDown() then turtle.digDown() end
        Movement.down()
    end
    Logger.info("Llegué a y=" .. Movement.getPos().y)
end

-- Moverse desde x=0,z=0 hasta workPosition.x, workPosition.z en el nivel actual.
local function travelToWorkXZ(wp)
    local function moveAxis(targetVal, posDir, negDir)
        while Movement.getPos().x ~= wp.x or Movement.getPos().z ~= wp.z do
            local cur
            if posDir == "east" or posDir == "west" then
                cur = Movement.getPos().x
            else
                cur = Movement.getPos().z
            end
            if cur == targetVal then return end
            local d = (cur < targetVal) and posDir or negDir
            Movement.faceDir(d)
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end

    -- Corregir X
    local cx = Movement.getPos().x
    if cx ~= wp.x then
        Movement.faceDir(cx < wp.x and "east" or "west")
        while Movement.getPos().x ~= wp.x do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end

    -- Corregir Z
    local cz = Movement.getPos().z
    if cz ~= wp.z then
        Movement.faceDir(cz < wp.z and "south" or "north")
        while Movement.getPos().z ~= wp.z do
            if turtle.detect() then turtle.dig() end
            Movement.forward()
        end
    end

    Movement.faceDir(wp.dir)
    Logger.info(string.format("Posición de trabajo restaurada x=%d y=%d z=%d dir=%s",
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
        -- Ya estamos en base; bajar y reposicionarse
        if session.workPosition then
            local wp = session.workPosition
            descendToY(wp.y)
            travelToWorkXZ(wp)
        end
        phase = "MINING_LAYER"
        session.phase = phase

    elseif phase == "DESCENDING_TO_START" then
        -- Bajar el offset inicial
        local targetY = -Config.START_OFFSET_DOWN
        if Movement.getPos().y > targetY then
            descendToY(targetY)
        end
        session.phase = "MINING_LAYER"
        phase = "MINING_LAYER"

    elseif phase == "DESCENDING_NEXT_LAYER" then
        -- Bajar una capa desde el nivel actual
        local result = Quarry.descendOneLayer(session)
        if result == "BEDROCK" then
            -- Terminar: volver a base
            State.save(snapshot("RETURNING_TO_BASE"))
            session.returningReason = "LAYER_COMPLETE"
            returnToBase()
            unloadAndRefuel()
            State.clear()
            Logger.info("=== Quarry finalizado por bedrock al reanudar ===")
            print("Quarry completo! Bloque irrompible encontrado al bajar.")
            return
        end
        session.currentLayer    = session.currentLayer + 1
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
            local targetY = -Config.START_OFFSET_DOWN
            if Movement.getPos().y > targetY then
                descendToY(targetY)
            end
            session.currentLayer = 0
            session.phase = "MINING_LAYER"
            phase = "MINING_LAYER"

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
                    descendToY(wp.y)
                    travelToWorkXZ(wp)
                end
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"

            else  -- result == "COMPLETE"
                -- Capa terminada
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
            local result = Quarry.descendOneLayer(session)

            if result == "BEDROCK" then
                Logger.info("Bedrock encontrado: quarry terminado")
                -- Último retorno a base
                session.returningReason = "LAYER_COMPLETE"
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                phase = "COMPLETE"
            else
                session.currentLayer    = session.currentLayer + 1
                session.currentRow      = 0
                session.currentColumn   = 0
                session.workPosition    = nil
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
                Logger.info(string.format("Bajé a capa %d", session.currentLayer))
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
