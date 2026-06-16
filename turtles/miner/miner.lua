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
local Network   = require("core.network")

local Miner = {}

-- ============================================================
-- Comando inalámbrico pendiente (compartido entre coroutines)
-- Escribir solo desde commandListener, leer desde el bucle principal.
-- ============================================================
local _pendingCommand = nil   -- {cmd="RETURN"|"DEPOSIT"|"STATUS", from=id}

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

-- Regresa al cofre (HOME = 0,0,0) desde cualquier posición subterránea.
--
-- ORDEN:
--   1. Navegar al pozo compartido (SHAFT_X, SHAFT_Z) en profundidad
--   2. Subir por el pozo hasta y=0
--   3. Navegar en superficie del pozo a HOME (0,0)
--
-- Con SHAFT=(0,0) los pasos 1 y 3 son instantáneos.
local function returnToBase()
    local p = Movement.getPos()
    Logger.info(string.format(
        "returnToBase: desde x=%d y=%d z=%d dir=%s",
        p.x, p.y, p.z, Movement.getDir()
    ))

    local sx = Config.SHAFT_X
    local sz = Config.SHAFT_Z

    -- ── Paso 1: navegar al pozo compartido en profundidad ────────────────────────
    while Movement.getPos().x ~= sx do
        sleep(0)
        local d = Movement.getPos().x > sx and "west" or "east"
        Movement.faceDir(d)
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then sleep(0.5) end
    end
    while Movement.getPos().z ~= sz do
        sleep(0)
        local d = Movement.getPos().z > sz and "north" or "south"
        Movement.faceDir(d)
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then sleep(0.5) end
    end

    Logger.info(string.format(
        "En pozo compartido: x=%d z=%d y=%d — subiendo",
        Movement.getPos().x, Movement.getPos().z, Movement.getPos().y
    ))

    -- ── Paso 2: subir por el pozo hasta y=0 ──────────────────────────────────────
    local stuckCount = 0
    while Movement.getPos().y < 0 do
        sleep(0)
        local hasBlock, data = turtle.inspectUp()
        if hasBlock then
            if data and isUnbreakableLocal(data.name) then
                Logger.error("Irrompible en techo del pozo en y=" .. Movement.getPos().y)
                stuckCount = stuckCount + 1
                if stuckCount > 6 then break end
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

    -- ── Paso 3: navegar en superficie del pozo a HOME (0,0) ─────────────────────
    if sx ~= 0 or sz ~= 0 then
        while Movement.getPos().x ~= 0 do
            sleep(0)
            local d = Movement.getPos().x > 0 and "west" or "east"
            Movement.faceDir(d)
            if turtle.detect() then turtle.dig() end
            if not Movement.forward() then sleep(0.5) end
        end
        while Movement.getPos().z ~= 0 do
            sleep(0)
            local d = Movement.getPos().z > 0 and "north" or "south"
            Movement.faceDir(d)
            if turtle.detect() then turtle.dig() end
            if not Movement.forward() then sleep(0.5) end
        end
    end

    Movement.faceDir("north")
    Logger.info(string.format(
        "BASE ALCANZADA: x=%d y=%d z=%d",
        Movement.getPos().x, Movement.getPos().y, Movement.getPos().z
    ))
end

-- Navega en superficie desde la posición actual hasta el pozo compartido
-- (Config.SHAFT_X, Config.SHAFT_Z). Con SHAFT=(0,0) es instantáneo.
local function travelToShaft()
    local sx = Config.SHAFT_X
    local sz = Config.SHAFT_Z
    if Movement.getPos().x == sx and Movement.getPos().z == sz then return end
    Logger.info(string.format("Yendo al pozo compartido: x=%d z=%d", sx, sz))
    while Movement.getPos().x ~= sx do
        sleep(0)
        Movement.faceDir(Movement.getPos().x < sx and "east" or "west")
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then sleep(0.5) end
    end
    while Movement.getPos().z ~= sz do
        sleep(0)
        Movement.faceDir(Movement.getPos().z < sz and "south" or "north")
        if turtle.detect() then turtle.dig() end
        if not Movement.forward() then sleep(0.5) end
    end
    Logger.info("En pozo compartido")
end

-- Mueve la turtle al pozo compartido antes de descender.
-- Si SHAFT=(0,0) y HOME=(0,0) no hace ningún movimiento.
local function moveToQuarryStart()
    travelToShaft()
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
-- Listener de comandos inalámbricos
-- Corre en paralelo con la minería usando parallel.waitForAny.
-- Escribe en _pendingCommand; el bucle principal lo lee y lo procesa.
-- ============================================================

local function commandListener()
    if not Network.open() then
        -- Sin modem: esta coroutine simplemente termina (no bloquea la minería)
        return
    end
    Logger.info("Red: escuchando comandos (RETURN / DEPOSIT / STATUS)")
    while true do
        local senderID, msg = Network.receive()
        if senderID and msg then
            local cmd = string.upper(msg)
            Logger.info("Comando remoto de [" .. tostring(senderID) .. "]: " .. cmd)
            if cmd == "RETURN" or cmd == "DEPOSIT" or cmd == "STATUS"
            or cmd == "UPDATE" or cmd == "REBOOT" then
                _pendingCommand = { cmd = cmd, from = senderID }
                Network.send(senderID, "ACK:" .. cmd)
            else
                Network.send(senderID, "ERR:cmd desconocido:" .. msg)
            end
        end
    end
end

-- ============================================================
-- Función principal
-- ============================================================

-- ============================================================
-- Lógica principal de minería (se ejecuta como coroutine con parallel)
-- ============================================================

local function minerMain()
    Logger.info("=== CCAP Miner v2 (Chunk Quarry Vertical) ===")

    -- Fases válidas del nuevo sistema. Cualquier otra (ej. "SHAFT" del código viejo)
    -- se descarta para evitar loops infinitos sin yield.
    local VALID_PHASES = {
        PREPARING=true, IDLE=true,
        MOVING_TO_QUARRY_START=true,
        DESCENDING_TO_START=true, MINING_LAYER=true,
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
        session.phase = "MOVING_TO_QUARRY_START"
        phase = session.phase
    end

    -- ============================================================
    -- Reanudar fases activas
    -- ============================================================

    if phase == "RETURNING_TO_WORK" then
        -- Ir al pozo, bajar al nivel correcto y reposicionarse
        travelToShaft()
        Quarry.descendToLayer(session, session.currentLayer)
        if session.workPosition then
            travelToWorkXZ(session.workPosition)
        end
        phase = "MINING_LAYER"
        session.phase = phase

    elseif phase == "MOVING_TO_QUARRY_START" then
        -- Reanudar navegación superficial al inicio del quarry
        moveToQuarryStart()
        phase = "DESCENDING_TO_START"
        session.phase = phase

    elseif phase == "MINING_LAYER" then
        -- Fix de reanudación: la turtle puede haber sido detenida en cualquier punto
        -- de la capa. Bajamos al nivel correcto y navegamos a la posición exacta
        -- guardada en el último checkpoint antes de continuar el serpentín.
        if saved and saved.x ~= nil then
            Logger.info(string.format(
                "Reanudando MINING_LAYER capa=%d: navegando a x=%d y=%d z=%d",
                session.currentLayer, saved.x, saved.y, saved.z
            ))
            -- Si el tracker restauró la posición en HOME (y=0), ir al pozo primero.
            if Movement.getPos().y >= 0 then
                travelToShaft()
            end
            Quarry.descendToLayer(session, session.currentLayer)
            travelToWorkXZ({ x=saved.x, y=saved.y, z=saved.z, dir=saved.dir or "north" })
        end
        -- phase sigue en MINING_LAYER → entra al while normalmente

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

        -- ── COMANDOS INALÁMBRICOS ──────────────────────────────
        -- Se procesan entre fases para no interrumpir operaciones atómicas.
        if _pendingCommand then
            local cmd      = _pendingCommand.cmd
            local senderID = _pendingCommand.from
            _pendingCommand = nil
            Logger.info("Procesando comando: " .. cmd)

            if cmd == "STATUS" then
                local p     = Movement.getPos()
                local label = os.getComputerLabel() or ("ID:" .. os.getComputerID())
                local statusMsg = string.format(
                    "[%s] phase=%s layer=%d fuel=%d free=%d x=%d y=%d z=%d",
                    label, phase, session.currentLayer, Fuel.getLevel(),
                    16 - Inventory.usedSlots(), p.x, p.y, p.z
                )
                Network.send(senderID, statusMsg)

            elseif cmd == "UPDATE" then
                Logger.info("UPDATE: descargando código y reiniciando por comando remoto")
                Network.send(senderID, "ACK:UPDATE — actualizando en " .. (os.getComputerLabel() or os.getComputerID()))
                sleep(0.5)
                if shell then
                    pcall(shell.run, "update")
                end
                os.reboot()

            elseif cmd == "REBOOT" then
                Logger.info("REBOOT: reiniciando por comando remoto")
                Network.send(senderID, "ACK:REBOOT — reiniciando en " .. (os.getComputerLabel() or os.getComputerID()))
                sleep(0.5)
                os.reboot()

            elseif cmd == "RETURN" then
                -- Regresar a base y terminar la sesión
                Logger.info("RETURN: regresando a base por comando remoto")
                session.returningReason = "COMMAND_RETURN"
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                Network.send(senderID, "DONE:en base, sesion detenida")
                phase = "COMPLETE"

            elseif cmd == "DEPOSIT" then
                -- Guardar posición actual, ir a descargar y volver
                Logger.info("DEPOSIT: yendo a descargar y volviendo al trabajo")
                local p = Movement.getPos()
                session.workPosition = {
                    x = p.x, y = p.y, z = p.z,
                    dir = Movement.getDir(),
                    currentLayer  = session.currentLayer,
                    currentRow    = session.currentRow,
                    currentColumn = session.currentColumn,
                }
                session.returningReason = "COMMAND_DEPOSIT"
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                -- Volver al punto de trabajo
                session.phase = "RETURNING_TO_WORK"
                State.save(snapshot("RETURNING_TO_WORK"))
                if session.workPosition then
                    travelToShaft()
                    Quarry.descendToLayer(session, session.currentLayer)
                    travelToWorkXZ(session.workPosition)
                end
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
                Network.send(senderID, "DONE:descarga completada, reanudando")
            end
        end

        if phase == "COMPLETE" or phase == "ERROR" then break end

        -- ── MOVING_TO_QUARRY_START ─────────────────────────────
        if phase == "MOVING_TO_QUARRY_START" then
            State.save(snapshot("MOVING_TO_QUARRY_START"))
            moveToQuarryStart()
            session.phase = "DESCENDING_TO_START"
            phase = "DESCENDING_TO_START"

        -- ── DESCENDING_TO_START ────────────────────────────────
        elseif phase == "DESCENDING_TO_START" then
            State.save(snapshot("DESCENDING_TO_START"))
            -- Desciende a la Y absoluta de la capa 0: y = -(START_OFFSET_DOWN)
            local result = Quarry.descendToLayer(session, 0)
            if result == "BEDROCK" then
                Logger.warn("Bedrock al bajar al offset inicial. Terminando.")
                returnToBase()
                unloadAndRefuel()
                phase = "COMPLETE"
            else
                -- Turtle está en el pozo (SHAFT_X, y0, SHAFT_Z).
                -- Si la zona de minería está en otra posición, caminar hasta ella.
                local ox = Config.QUARRY_OFFSET_X
                local oz = Config.QUARRY_OFFSET_Z
                if ox ~= Config.SHAFT_X or oz ~= Config.SHAFT_Z then
                    Logger.info(string.format(
                        "Caminando del pozo a zona de minería: x=%d z=%d", ox, oz))
                    travelToWorkXZ({
                        x   = ox,
                        y   = Movement.getPos().y,
                        z   = oz,
                        dir = "east",
                    })
                end
                session.currentLayer = 0
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
            end

        -- ── MINING_LAYER ───────────────────────────────────────
        elseif phase == "MINING_LAYER" then
            State.save(snapshot("MINING_LAYER"))
            Logger.info(string.format("=== Capa %d ===", session.currentLayer))

            local result = Quarry.mineLayer(session)

            -- Capa vacía (cueva / ya excavada): bajar directo al siguiente nivel
            if result == "EMPTY" then
                Logger.info(string.format("Capa %d vacia, bajando al siguiente nivel", session.currentLayer))
                session.phase = "DESCENDING_NEXT_LAYER"
                State.save(snapshot("DESCENDING_NEXT_LAYER"))
                phase = "DESCENDING_NEXT_LAYER"

            elseif result == "INVENTORY_FULL" or result == "FUEL_LOW" then
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
                    travelToShaft()
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
end  -- fin de minerMain

-- ============================================================
-- Punto de entrada público
-- Corre la minería y el listener inalámbrico en paralelo.
-- Si no hay modem, commandListener termina inmediatamente y
-- minerMain sigue solo — la minería no se ve afectada.
-- ============================================================

function Miner.run()
    parallel.waitForAny(commandListener, minerMain)
end

return Miner
