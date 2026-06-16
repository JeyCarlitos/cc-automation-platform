-- turtles/miner/miner.lua
-- Orquestador — Chunk Quarry Vertical.
--
-- Máquina de estados:
--
--   WAITING_FOR_ZONE       (nueva sesión: espera ZONE:N del controlador)
--     ↓
--   WAITING_FOR_START      (zona asignada: espera START del controlador)
--     ↓
--   MOVING_TO_QUARRY_START (camina en superficie al pozo compartido)
--     ↓
--   DESCENDING_TO_START    (baja START_OFFSET_DOWN bloques)
--     ↓  (envía AT_DEPTH al controlador)
--   MINING_LAYER           (serpentín 16×16)
--     ↓ INVENTORY_FULL / FUEL_LOW / LAYER_COMPLETE
--   RETURNING_TO_BASE
--     ↓
--   UNLOADING
--     ↓
--   RETURNING_TO_WORK      (si la capa no terminó)
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

-- ============================================================
-- Navegación segura con anti-deadlock.
--
-- Mueve la turtle desde la posición actual hasta 'target' en un eje.
--   • Bloque normal  → excavar y avanzar.
--   • Otra turtle    → esperar con jitter basado en ID propio (desincroniza
--                      turtles con el mismo destino). Tras 3 bloqueos seguidos,
--                      retrocede un bloque para ceder el paso y romper deadlock.
--   • Camino libre   → avanzar directamente.
-- ============================================================
local function navAxis(getCoord, target, plusDir, minusDir)
    local blocked = 0
    while getCoord() ~= target do
        sleep(0)
        local dir = getCoord() < target and plusDir or minusDir
        Movement.faceDir(dir)
        local hasBlock, data = turtle.inspect()
        if not hasBlock then
            if Movement.forward() then blocked = 0 else sleep(0.3) end
        elseif data and data.name and data.name:find("turtle") then
            blocked = blocked + 1
            local wait = 1 + (os.getComputerID() % 3)   -- 1, 2 o 3s según ID
            Logger.warn(string.format(
                "Turtle enfrente (bloqueo %d) — esperando %ds (ID=%d)",
                blocked, wait, os.getComputerID()
            ))
            sleep(wait)
            if blocked >= 3 then
                -- Retroceder un bloque para ceder el paso y romper el deadlock
                Movement.faceDir(getCoord() < target and minusDir or plusDir)
                if Movement.forward() then
                    Logger.info("Cediendo paso — retrocedi un bloque")
                end
                blocked = 0
                sleep(2)
            end
        else
            turtle.dig()
            if Movement.forward() then blocked = 0 else sleep(0.3) end
        end
    end
end

local Miner = {}

-- ============================================================
-- Comando inalámbrico pendiente (compartido entre coroutines)
-- ============================================================
local _pendingCommand = nil   -- {cmd, from, zoneNum?}

-- ============================================================
-- Sesión
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
    -- Asignación dinámica de zona (Opción A)
    zone            = nil,   -- número de zona (0=primera, 1=segunda, ...)
    controllerID    = nil,   -- ID rednet de la PC controladora
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
        zone            = session.zone,
        controllerID    = session.controllerID,
    }
end

-- Asigna el pozo individual de esta turtle: SHAFT_X = inicio de su zona.
-- Con pozos separados, dos turtles nunca comparten el mismo eje vertical
-- y las colisiones subterráneas son físicamente imposibles.
local function updateShaftFromZone()
    if session.zone ~= nil then
        Config.SHAFT_X = session.zone * Config.QUARRY_WIDTH
        Config.SHAFT_Z = Config.QUARRY_OFFSET_Z
        Logger.info(string.format(
            "Pozo individual zona %d: SHAFT_X=%d", session.zone, Config.SHAFT_X
        ))
    end
end

-- Navega en superficie desde la posición actual hasta el pozo de esta turtle.
local function travelToShaft()
    local sx = Config.SHAFT_X
    local sz = Config.SHAFT_Z
    if Movement.getPos().x == sx and Movement.getPos().z == sz then return end
    Logger.info(string.format("Yendo al pozo: x=%d z=%d", sx, sz))
    navAxis(function() return Movement.getPos().x end, sx, "east", "west")
    navAxis(function() return Movement.getPos().z end, sz, "south", "north")
    Logger.info("En pozo")
end

local function moveToQuarryStart()
    travelToShaft()
end

-- Regresa al cofre (HOME = 0,0,0) desde cualquier posición subterránea.
local function returnToBase()
    local p = Movement.getPos()
    Logger.info(string.format(
        "returnToBase: desde x=%d y=%d z=%d dir=%s",
        p.x, p.y, p.z, Movement.getDir()
    ))

    local sx = Config.SHAFT_X
    local sz = Config.SHAFT_Z

    -- Paso 1: navegar al pozo individual en profundidad
    navAxis(function() return Movement.getPos().x end, sx, "east", "west")
    navAxis(function() return Movement.getPos().z end, sz, "south", "north")

    Logger.info(string.format(
        "En pozo x=%d z=%d y=%d — subiendo",
        Movement.getPos().x, Movement.getPos().z, Movement.getPos().y
    ))

    -- Paso 2: subir por el pozo hasta y=0
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
            elseif data.name and data.name:find("turtle") then
                -- Con pozos individuales esto no debería ocurrir, pero por si acaso
                Logger.warn("Turtle arriba en el pozo — esperando 3s")
                sleep(3)
            else
                turtle.digUp()
                if not Movement.up() then sleep(0.5) end
            end
        else
            if not Movement.up() then sleep(0.5) end
        end
    end

    -- Paso 3: navegar en superficie del pozo a HOME (0,0)
    if sx ~= 0 or sz ~= 0 then
        navAxis(function() return Movement.getPos().x end, 0, "east", "west")
        navAxis(function() return Movement.getPos().z end, 0, "south", "north")
    end

    Movement.faceDir("north")
    Logger.info(string.format(
        "BASE ALCANZADA: x=%d y=%d z=%d",
        Movement.getPos().x, Movement.getPos().y, Movement.getPos().z
    ))
end

local function unloadAndRefuel()
    local p = Movement.getPos()
    Logger.info(string.format(
        "unloadAndRefuel: en x=%d y=%d z=%d, cofre=%s",
        p.x, p.y, p.z, Config.CHEST_DIRECTION
    ))

    local chest = Config.CHEST_DIRECTION
    if chest == "back" then
        Movement.faceDir("south")
    elseif chest == "left" then
        Movement.faceDir("west")
    elseif chest == "right" then
        Movement.faceDir("east")
    else
        Movement.faceDir("north")
    end

    Inventory.dropAll("forward")
    Fuel.refuelFromInventory()
    Movement.faceDir("north")
    Logger.info("Descarga completa. Fuel: " .. Fuel.getLevel())
end

local function travelToWorkXZ(wp)
    navAxis(function() return Movement.getPos().x end, wp.x, "east", "west")
    navAxis(function() return Movement.getPos().z end, wp.z, "south", "north")
    if wp.dir then Movement.faceDir(wp.dir) end
    Logger.info(string.format("Posicion restaurada x=%d y=%d z=%d dir=%s",
        wp.x, wp.y, wp.z, tostring(wp.dir)))
end

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

-- Helper para enviar notificaciones al controlador
local function notifyController(msg)
    if session.controllerID then
        local label = os.getComputerLabel() or ("ID:" .. os.getComputerID())
        Network.send(session.controllerID, string.format("[%s] %s", label, msg))
    end
end

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
-- ============================================================

local function commandListener()
    if not Network.open() then return end
    Logger.info("Red: escuchando comandos")
    while true do
        local senderID, msg = Network.receive()
        if senderID and msg then
            local upper = string.upper(msg)

            -- ZONE:N — asignación de zona por el controlador
            local zoneNum = upper:match("^ZONE:(%d+)$")
            if zoneNum then
                _pendingCommand = { cmd = "ZONE", zoneNum = tonumber(zoneNum), from = senderID }
                Network.send(senderID, "ACK:ZONE:" .. zoneNum)

            -- START — controlador autoriza el descenso
            elseif upper == "START" then
                _pendingCommand = { cmd = "START", from = senderID }
                Network.send(senderID, "ACK:START")

            elseif upper == "STATUS" or upper == "RETURN" or upper == "DEPOSIT"
                or upper == "UPDATE" or upper == "REBOOT" then
                _pendingCommand = { cmd = upper, from = senderID }
                Network.send(senderID, "ACK:" .. upper)

            else
                Network.send(senderID, "ERR:cmd desconocido:" .. msg)
            end
        end
    end
end

-- ============================================================
-- Función principal de minería
-- ============================================================

local function minerMain()
    Logger.info("=== CCAP Miner v2 (Chunk Quarry Vertical) ===")

    local VALID_PHASES = {
        PREPARING=true, IDLE=true,
        WAITING_FOR_ZONE=true, WAITING_FOR_START=true,
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
        session.zone            = saved.zone
        session.controllerID    = saved.controllerID
        Movement.setState(
            { x = saved.x or 0, y = saved.y or 0, z = saved.z or 0 },
            saved.dir or "north"
        )

        -- Restaurar zona en Config si fue asignada dinámicamente
        if session.zone ~= nil then
            Config.QUARRY_OFFSET_X = session.zone * Config.QUARRY_WIDTH
            updateShaftFromZone()   -- pozo individual por zona
            Logger.info(string.format(
                "Zona restaurada: %d (QUARRY_OFFSET_X=%d SHAFT_X=%d)",
                session.zone, Config.QUARRY_OFFSET_X, Config.SHAFT_X
            ))
        end

        Logger.info(string.format(
            "Reanudando: phase=%s capa=%d zona=%s",
            session.phase, session.currentLayer,
            tostring(session.zone)
        ))
    else
        Movement.resetState()
        Logger.info("Nueva sesion de quarry")

        -- Nueva sesión: registrarse con el controlador para obtener zona
        if Network.open() then
            Logger.info("Enviando REGISTER al controlador...")
            Network.broadcast("REGISTER")
            session.phase = "WAITING_FOR_ZONE"
        else
            -- Sin modem: usar QUARRY_OFFSET_X de config directamente
            Logger.warn("Sin modem. Zona fija: QUARRY_OFFSET_X=" .. Config.QUARRY_OFFSET_X)
            session.phase = "PREPARING"
        end
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

    elseif phase == "ERROR" then
        -- Recuperación automática: refuelizar del inventario y volver a minar.
        -- Útil cuando la sesión terminó en ERROR por falta de combustible.
        Logger.warn(string.format(
            "Recuperando de ERROR (capa %d, zona %s) — intentando refuelizar...",
            session.currentLayer, tostring(session.zone)
        ))
        Fuel.refuelFromInventory()
        if Fuel.getLevel() < Config.FUEL_MINIMUM then
            Logger.error("Sin combustible suficiente para recuperar.")
            print("Sin combustible. Agrega carbon al inventario y ejecuta startup de nuevo.")
            return
        end
        Logger.info("Fuel OK (" .. Fuel.getLevel() .. "). Regresando a base...")
        returnToBase()
        unloadAndRefuel()
        -- Reanudar desde el inicio de la capa donde estaba (no perder progreso de capas)
        session.currentRow      = 0
        session.currentColumn   = 0
        session.workPosition    = nil
        session.returningReason = nil
        phase = "RETURNING_TO_WORK"
        session.phase = phase
        State.save(snapshot(phase))
        Logger.info(string.format(
            "Recuperado. Reanudando desde capa %d.", session.currentLayer
        ))
    end

    -- ============================================================
    -- Reanudar fases activas
    -- ============================================================

    if phase == "RETURNING_TO_WORK" then
        travelToShaft()
        Quarry.descendToLayer(session, session.currentLayer)
        if session.workPosition then
            travelToWorkXZ(session.workPosition)
        end
        phase = "MINING_LAYER"
        session.phase = phase

    elseif phase == "MOVING_TO_QUARRY_START" then
        moveToQuarryStart()
        phase = "DESCENDING_TO_START"
        session.phase = phase

    elseif phase == "MINING_LAYER" then
        if saved and saved.x ~= nil then
            Logger.info(string.format(
                "Reanudando MINING_LAYER capa=%d: navegando a x=%d y=%d z=%d",
                session.currentLayer, saved.x, saved.y, saved.z
            ))
            if Movement.getPos().y >= 0 then
                travelToShaft()
            end
            Quarry.descendToLayer(session, session.currentLayer)
            travelToWorkXZ({ x=saved.x, y=saved.y, z=saved.z, dir=saved.dir or "north" })
        end

    elseif phase == "DESCENDING_TO_START" then
        -- el bucle principal lo maneja

    elseif phase == "DESCENDING_NEXT_LAYER" then
        local nextLayer = session.currentLayer + 1
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

    -- WAITING_FOR_ZONE / WAITING_FOR_START: el bucle principal los maneja
    end

    -- ============================================================
    -- Bucle principal
    -- ============================================================

    while phase ~= "COMPLETE" and phase ~= "ERROR" do
        sleep(0)

        -- ── COMANDOS INALÁMBRICOS ──────────────────────────────
        if _pendingCommand then
            local cmd      = _pendingCommand.cmd
            local senderID = _pendingCommand.from
            local zoneNum  = _pendingCommand.zoneNum  -- solo para ZONE
            _pendingCommand = nil

            -- ── ZONE:N — asignación dinámica de zona ──────────
            if cmd == "ZONE" then
                if phase == "WAITING_FOR_ZONE" and zoneNum ~= nil then
                    session.zone         = zoneNum
                    session.controllerID = senderID
                    Config.QUARRY_OFFSET_X = zoneNum * Config.QUARRY_WIDTH
                    updateShaftFromZone()   -- pozo individual por zona
                    Logger.info(string.format(
                        "Zona %d asignada. QUARRY_OFFSET_X=%d SHAFT_X=%d",
                        zoneNum, Config.QUARRY_OFFSET_X, Config.SHAFT_X
                    ))
                    local label = os.getComputerLabel() or ("ID:" .. os.getComputerID())
                    Network.send(senderID, string.format(
                        "[%s] ZONE:%d confirmada — esperando START", label, zoneNum
                    ))
                    session.phase = "WAITING_FOR_START"
                    phase = "WAITING_FOR_START"
                    State.save(snapshot(phase))
                end

            -- ── START — autorización de descenso ──────────────
            elseif cmd == "START" then
                if phase == "WAITING_FOR_START" then
                    session.controllerID = senderID
                    Logger.info("START recibido — zona " .. tostring(session.zone))
                    if not validatePreConditions() then
                        notifyController("ERROR:pre-condiciones fallidas")
                        phase = "ERROR"
                    else
                        session.phase = "MOVING_TO_QUARRY_START"
                        phase = "MOVING_TO_QUARRY_START"
                        State.save(snapshot(phase))
                    end
                end

            elseif cmd == "STATUS" then
                local p     = Movement.getPos()
                local label = os.getComputerLabel() or ("ID:" .. os.getComputerID())
                Network.send(senderID, string.format(
                    "[%s] phase=%s zone=%s layer=%d fuel=%d free=%d x=%d y=%d z=%d",
                    label, phase, tostring(session.zone),
                    session.currentLayer, Fuel.getLevel(),
                    16 - Inventory.usedSlots(), p.x, p.y, p.z
                ))

            elseif cmd == "UPDATE" then
                Logger.info("UPDATE: descargando código y reiniciando")
                notifyController("UPDATE — actualizando...")
                sleep(0.5)
                if shell then pcall(shell.run, "update") end
                os.reboot()

            elseif cmd == "REBOOT" then
                Logger.info("REBOOT: reiniciando por comando remoto")
                notifyController("REBOOT — reiniciando...")
                sleep(0.5)
                os.reboot()

            elseif cmd == "RETURN" then
                Logger.info("RETURN: regresando a base por comando remoto")
                session.returningReason = "COMMAND_RETURN"
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                notifyController("DONE:en base, sesion detenida")
                phase = "COMPLETE"

            elseif cmd == "DEPOSIT" then
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
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()
                unloadAndRefuel()
                session.phase = "RETURNING_TO_WORK"
                State.save(snapshot("RETURNING_TO_WORK"))
                if session.workPosition then
                    travelToShaft()
                    Quarry.descendToLayer(session, session.currentLayer)
                    travelToWorkXZ(session.workPosition)
                end
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
                notifyController("DONE:descarga completada, reanudando")
            end
        end

        if phase == "COMPLETE" or phase == "ERROR" then break end

        -- ── WAITING_FOR_ZONE ───────────────────────────────────
        -- commandListener recibe ZONE:N y lo pone en _pendingCommand.
        -- El bloque de comandos de arriba ya lo procesa; aquí solo cedemos CPU.
        if phase == "WAITING_FOR_ZONE" then
            sleep(0.5)

        -- ── WAITING_FOR_START ──────────────────────────────────
        -- commandListener recibe START y lo pone en _pendingCommand.
        elseif phase == "WAITING_FOR_START" then
            sleep(0.5)

        -- ── MOVING_TO_QUARRY_START ─────────────────────────────
        elseif phase == "MOVING_TO_QUARRY_START" then
            State.save(snapshot("MOVING_TO_QUARRY_START"))
            moveToQuarryStart()
            session.phase = "DESCENDING_TO_START"
            phase = "DESCENDING_TO_START"

        -- ── DESCENDING_TO_START ────────────────────────────────
        elseif phase == "DESCENDING_TO_START" then
            State.save(snapshot("DESCENDING_TO_START"))
            local result = Quarry.descendToLayer(session, 0)
            if result == "BEDROCK" then
                Logger.warn("Bedrock al bajar al offset inicial. Terminando.")
                returnToBase()
                unloadAndRefuel()
                phase = "COMPLETE"
            else
                -- Caminar del pozo a la zona de minería (si son distintos)
                local ox = Config.QUARRY_OFFSET_X
                local oz = Config.QUARRY_OFFSET_Z
                if ox ~= Config.SHAFT_X or oz ~= Config.SHAFT_Z then
                    Logger.info(string.format(
                        "Caminando del pozo a zona %d: x=%d z=%d",
                        session.zone or 0, ox, oz
                    ))
                    travelToWorkXZ({ x=ox, y=Movement.getPos().y, z=oz, dir="east" })
                end

                -- Notificar al controlador: listo para minar, puede bajar la siguiente
                notifyController(string.format(
                    "AT_DEPTH zona=%d y=%d",
                    session.zone or 0, Movement.getPos().y
                ))

                session.currentLayer = 0
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"
            end

        -- ── MINING_LAYER ───────────────────────────────────────
        elseif phase == "MINING_LAYER" then
            State.save(snapshot("MINING_LAYER"))
            Logger.info(string.format("=== Capa %d (zona %s) ===",
                session.currentLayer, tostring(session.zone)))

            local result = Quarry.mineLayer(session)

            if result == "EMPTY" then
                session.phase = "DESCENDING_NEXT_LAYER"
                State.save(snapshot("DESCENDING_NEXT_LAYER"))
                phase = "DESCENDING_NEXT_LAYER"

            elseif result == "INVENTORY_FULL" or result == "FUEL_LOW" then
                session.returningReason = result
                session.phase = "RETURNING_TO_BASE"
                State.save(snapshot("RETURNING_TO_BASE"))
                returnToBase()

                session.phase = "UNLOADING"
                unloadAndRefuel()

                local fuelNeeded = Config.QUARRY_WIDTH * Config.QUARRY_LENGTH + 50
                if not Fuel.ensureFuel(fuelNeeded) then
                    Logger.error("Sin fuel suficiente tras reabastecimiento. Abortando.")
                    phase = "ERROR"
                    break
                end

                session.phase = "RETURNING_TO_WORK"
                State.save(snapshot("RETURNING_TO_WORK"))
                if session.workPosition then
                    travelToShaft()
                    Quarry.descendToLayer(session, session.currentLayer)
                    travelToWorkXZ(session.workPosition)
                end
                session.phase = "MINING_LAYER"
                phase = "MINING_LAYER"

            else  -- COMPLETE
                if Config.RETURN_AFTER_EACH_LAYER then
                    session.returningReason = "LAYER_COMPLETE"
                    session.phase = "RETURNING_TO_BASE"
                    State.save(snapshot("RETURNING_TO_BASE"))
                    returnToBase()
                    session.phase = "UNLOADING"
                    unloadAndRefuel()
                end
                session.phase = "DESCENDING_NEXT_LAYER"
                State.save(snapshot("DESCENDING_NEXT_LAYER"))
                phase = "DESCENDING_NEXT_LAYER"
            end

        -- ── DESCENDING_NEXT_LAYER ──────────────────────────────
        elseif phase == "DESCENDING_NEXT_LAYER" then
            local nextLayer = session.currentLayer + 1

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
            Logger.error("Fase no reconocida en bucle: " .. tostring(phase))
            phase = "ERROR"
        end
    end

    -- ============================================================
    -- Fin
    -- ============================================================

    if phase == "COMPLETE" then
        State.clear()
        notifyController(string.format(
            "COMPLETE zona=%d capas=%d",
            session.zone or 0, session.currentLayer
        ))
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

-- ============================================================
-- Punto de entrada público
-- ============================================================

function Miner.run()
    parallel.waitForAny(commandListener, minerMain)
end

return Miner
