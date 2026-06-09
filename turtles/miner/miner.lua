-- turtles/miner/miner.lua
-- Orquestador principal del Miner v1.
--
-- Máquina de estados:
--
--   PREPARING → MINING → RETURNING → UNLOADING
--                 ↑          |             |
--                 └──────────┘             |  (si minería incompleta: fuel/inventario)
--                             COMPLETE ←──┘  (si minería completa)
--
-- Este módulo coordina todos los demás: inicialización, minería,
-- retorno a base, descarga en cofre y persistencia de estado.

local Config       = require("config.config")
local Logger       = require("core.logger")
local Movement     = require("core.movement")
local Fuel         = require("core.fuel")
local Inventory    = require("core.inventory")
local State        = require("turtles.miner.state")
local BranchMining = require("turtles.miner.branchMining")

local Miner = {}

-- ============================================================
-- Datos de sesión
-- ============================================================

-- Tabla que se pasa y modifica a lo largo de la sesión.
-- Representa el estado actual de la operación de minería.
local session = {
    phase        = "IDLE",
    mainProgress = 0,
    moveCount    = 0,
}

-- ============================================================
-- Helpers internos
-- ============================================================

-- Construye la tabla completa de estado para persistencia.
local function buildStateSnapshot(phase)
    local p = Movement.getPos()
    return {
        phase        = phase or session.phase,
        mainProgress = session.mainProgress,
        moveCount    = session.moveCount,
        x            = p.x,
        y            = p.y,
        z            = p.z,
        dir          = Movement.getDir(),
    }
end

-- Navega de vuelta al origen {x=0, y=0, z=0} desde la posición actual.
-- Estrategia: corregir Y → corregir X → corregir Z.
-- Excava si encuentra bloques en el camino (podría haber habido un derrumbe).
local function returnToBase()
    local p = Movement.getPos()
    Logger.info(string.format(
        "Regresando a base desde x=%d y=%d z=%d",
        p.x, p.y, p.z
    ))

    -- 1. Ajustar altura (eje Y)
    p = Movement.getPos()
    while p.y > 0 do
        if not Movement.up() then
            turtle.digUp()
            Movement.up()
        end
        p = Movement.getPos()
    end
    while p.y < 0 do
        if not Movement.down() then
            turtle.digDown()
            Movement.down()
        end
        p = Movement.getPos()
    end

    -- 2. Ajustar X
    p = Movement.getPos()
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

    -- 3. Ajustar Z (regresar por el túnel principal)
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

    -- Orientarse hacia el túnel (norte) al llegar
    Movement.faceDir("north")
    Logger.info("Turtle en base")
end

-- Descarga el inventario en el cofre.
-- El cofre debe estar en Config.CHEST_DIRECTION relativo al origen.
local function unloadInventory()
    Logger.info("Descargando inventario en cofre (" .. Config.CHEST_DIRECTION .. ")")

    -- Orientarse hacia el cofre
    local chest = Config.CHEST_DIRECTION
    if chest == "back" then
        Movement.turnLeft()
        Movement.turnLeft()
    elseif chest == "left" then
        Movement.turnLeft()
    elseif chest == "right" then
        Movement.turnRight()
    end
    -- "forward": ya está mirando al frente, no gira

    -- Tirar todos los ítems no combustibles
    local dropped = Inventory.dropAll("forward")

    -- Volver a mirar hacia el túnel (norte)
    Movement.faceDir("north")

    Logger.info("Descarga completa. Stacks enviados al cofre: " .. dropped)
end

-- Verifica fuel e inventario antes de salir a minar.
-- Intenta refuel automático si el nivel está bajo.
-- Retorna true si todo está OK para comenzar.
local function validatePreConditions()
    Logger.info("Validando condiciones iniciales...")

    -- Fuel: necesitamos al menos para recorrer el túnel completo + ramas + retorno
    local fuelNeeded = Config.TUNNEL_LENGTH
                     + (Config.BRANCH_LENGTH * 2 * (Config.TUNNEL_LENGTH / Config.BRANCH_SPACING))
    if not Fuel.ensureFuel(fuelNeeded) then
        -- No abortamos: si el fuel es bajo pero suficiente para un parcial,
        -- BranchMining.run() se detendrá y retornará con "FUEL".
        -- Solo abortamos si ni siquiera alcanza para el mínimo.
        if Fuel.getLevel() < Config.FUEL_MINIMUM then
            Logger.error("Fuel crítico (" .. Fuel.getLevel() .. "). Agrega combustible y reinicia.")
            return false
        end
        Logger.warn("Fuel bajo. La turtle minará hasta agotar y regresará.")
    end

    -- Inventario: si está lleno al inicio, descargar antes de salir
    if Inventory.isFull() then
        Logger.warn("Inventario lleno al iniciar. Descargando...")
        unloadInventory()
    end

    Logger.info(string.format(
        "Condiciones OK. Fuel: %d | Slots libres: %d",
        Fuel.getLevel(),
        Inventory.freeSlots()
    ))
    return true
end

-- Viaja de vuelta al punto donde se detuvo la minería (sin excavar).
-- El túnel ya está excavado, así que solo avanza.
local function travelToProgress(targetBlock)
    if targetBlock <= 0 then return end
    Logger.info("Viajando al bloque " .. targetBlock .. " del tunel...")
    Movement.faceDir("north")
    for i = 1, targetBlock do
        if not Movement.forward() then
            -- Si hay un bloque (derrumbe), excavar
            turtle.dig()
            Movement.forward()
        end
    end
    Logger.info("Posicion de reanudacion alcanzada")
end

-- ============================================================
-- Función principal
-- ============================================================

function Miner.run()
    Logger.info("=== CCAP Miner v1 iniciando ===")

    -- Intentar recuperar sesión anterior
    local savedState = State.load()
    if savedState then
        Logger.info("Reanudando sesion. Progreso: " .. (savedState.mainProgress or 0) .. " bloques")
        session.mainProgress = savedState.mainProgress or 0
        session.moveCount    = savedState.moveCount    or 0
        session.phase        = savedState.phase        or "MINING"
        Movement.setState(
            { x = savedState.x or 0, y = savedState.y or 0, z = savedState.z or 0 },
            savedState.dir or "north"
        )
    else
        Logger.info("Nueva sesion de mineria")
        Movement.resetState()
        session.phase        = "PREPARING"
        session.mainProgress = 0
        session.moveCount    = 0
    end

    -- ============================================================
    -- Recuperar fase incompleta si la turtle fue interrumpida
    -- ============================================================

    -- Si la turtle fue apagada mientras regresaba, terminar el retorno primero.
    -- Movement.setState ya restauró la posición correcta del crash/apagado.
    if session.phase == "RETURNING" then
        Logger.info("Reanudando: completando retorno a base...")
        returnToBase()
        unloadInventory()
        -- Si la minería ya estaba completa al momento del crash, terminar.
        if session.mainProgress >= Config.TUNNEL_LENGTH then
            session.phase = "COMPLETE"
            State.clear()
            Logger.info("=== Sesion completada al reanudar ===")
            return
        end
        session.phase = "MINING"

    -- Si fue apagada mientras descargaba, completar la descarga.
    elseif session.phase == "UNLOADING" then
        Logger.info("Reanudando: completando descarga...")
        returnToBase()  -- por si acaso no llegó a base
        unloadInventory()
        if session.mainProgress >= Config.TUNNEL_LENGTH then
            session.phase = "COMPLETE"
            State.clear()
            Logger.info("=== Sesion completada al reanudar ===")
            return
        end
        session.phase = "MINING"

    -- Primera ejecución: validar condiciones antes de salir.
    elseif session.phase == "PREPARING" or session.phase == "IDLE" then
        if not validatePreConditions() then
            Logger.error("No se puede iniciar. Corrige el problema y ejecuta startup.")
            return
        end
        session.phase = "MINING"
    end

    -- Si reanudamos en MINING con progreso > 0, viajar al punto donde quedamos.
    -- Nota: si la turtle fue interrumpida físicamente dentro de una rama,
    -- puede necesitar reposicionamiento manual. Ver documentación.
    if session.phase == "MINING" and session.mainProgress > 0 then
        travelToProgress(session.mainProgress)
    end

    -- ============================================================
    -- Bucle principal: MINING → RETURNING → UNLOADING → (repetir o COMPLETE)
    -- ============================================================

    while session.mainProgress < Config.TUNNEL_LENGTH do

        -- Guardar estado al inicio de cada ciclo
        session.phase = "MINING"
        State.save(buildStateSnapshot("MINING"))

        -- Minar hasta completar, quedarse sin fuel o llenar inventario
        local reason = BranchMining.run(session)

        -- Guardar estado inmediatamente antes de moverse de vuelta
        session.phase = "RETURNING"
        State.save(buildStateSnapshot("RETURNING"))

        -- Regresar a base
        returnToBase()

        -- Descargar inventario
        session.phase = "UNLOADING"
        unloadInventory()

        -- ¿Terminamos?
        if reason == "COMPLETE" then
            Logger.info("Minería completada.")
            break
        end

        -- Sesión interrumpida por fuel o inventario: preparar para continuar
        Logger.info(string.format(
            "Sesion interrumpida (%s). Progreso: %d/%d bloques.",
            reason, session.mainProgress, Config.TUNNEL_LENGTH
        ))

        -- Verificar fuel para el siguiente ciclo
        if not Fuel.ensureFuel(Config.BRANCH_SPACING + Config.BRANCH_LENGTH * 2) then
            Logger.error("Sin fuel suficiente para continuar tras descarga. Abortando.")
            break
        end

        -- Volver al punto de reanudación
        travelToProgress(session.mainProgress)
    end

    -- ============================================================
    -- COMPLETE
    -- ============================================================

    session.phase = "COMPLETE"
    State.clear()

    Logger.info(string.format(
        "=== Sesion finalizada. Bloques minados: %d/%d ===",
        session.mainProgress,
        Config.TUNNEL_LENGTH
    ))
    print("")
    print("Mineria completa! Revisa el cofre para tus recursos.")
    print("Ejecuta 'startup' para iniciar una nueva sesion.")
end

return Miner
