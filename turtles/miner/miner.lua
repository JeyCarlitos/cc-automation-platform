-- turtles/miner/miner.lua
-- Orquestador principal de Miner v1 (modo Quarry).
--
-- Máquina de estados:
--   PREPARING → SHAFT → LAYERS → RETURNING → UNLOADING
--                          ↑           |            |
--                          └───────────┘            | (si incompleto)
--                                   COMPLETE ←──────┘

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")
local State     = require("turtles.miner.state")
local Quarry    = require("turtles.miner.quarry")

local Miner = {}

-- Sesión actual
local session = {
    phase        = "IDLE",
    shaftDug     = 0,
    currentLayer = 0,
    moveCount    = 0,
}

-- ============================================================
-- Helpers internos
-- ============================================================

local function buildStateSnapshot(phase)
    local p = Movement.getPos()
    return {
        phase        = phase or session.phase,
        shaftDug     = session.shaftDug,
        currentLayer = session.currentLayer,
        moveCount    = session.moveCount,
        x            = p.x,
        y            = p.y,
        z            = p.z,
        dir          = Movement.getDir(),
    }
end

-- Navegar de vuelta al origen {0,0,0}
local function returnToBase()
    Logger.info(string.format(
        "Regresando a base desde x=%d y=%d z=%d",
        Movement.getPos().x, Movement.getPos().y, Movement.getPos().z
    ))

    -- 1. Subir hasta Y=0
    while Movement.getPos().y < 0 do
        if turtle.detectUp() then turtle.digUp() end
        Movement.up()
    end

    -- 2. Ajustar X
    local p = Movement.getPos()
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

    -- 3. Ajustar Z
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

    Movement.faceDir("north")
    Logger.info("Turtle en base")
end

-- Descargar inventario en el cofre
local function unloadInventory()
    Logger.info("Descargando inventario (" .. Config.CHEST_DIRECTION .. ")")

    local chest = Config.CHEST_DIRECTION
    if chest == "back" then
        Movement.turnLeft()
        Movement.turnLeft()
    elseif chest == "left" then
        Movement.turnLeft()
    elseif chest == "right" then
        Movement.turnRight()
    end

    Inventory.dropAll("forward")
    Movement.faceDir("north")
    Logger.info("Descarga completa")
end

-- Validar condiciones antes de salir
local function validatePreConditions()
    Logger.info("Validando condiciones iniciales...")

    if Fuel.getLevel() < Config.FUEL_MINIMUM then
        Fuel.refuelFromInventory()
        if Fuel.getLevel() < Config.FUEL_MINIMUM then
            Logger.error("Fuel critico (" .. Fuel.getLevel() .. "). Agrega combustible y reinicia.")
            return false
        end
    end

    if Inventory.isFull() then
        Logger.warn("Inventario lleno al iniciar. Descargando...")
        unloadInventory()
    end

    Logger.info("Condiciones OK. Fuel: " .. Fuel.getLevel())
    return true
end

-- Volver a la capa donde se interrumpió la minería.
-- Desciende por el pozo (columna x=0, z=0) hasta el nivel correcto.
local function travelToLayer()
    local layer     = session.currentLayer or 0
    local stepsDown = Config.SHAFT_DEPTH - layer

    if stepsDown <= 0 then return end

    Logger.info(string.format(
        "Bajando al quarry: %d bloques (capa %d/%d)",
        stepsDown, layer + 1, Config.SHAFT_DEPTH
    ))

    Movement.faceDir("north")
    for i = 1, stepsDown do
        if turtle.detectDown() then turtle.digDown() end
        if not Movement.down() then
            Logger.warn("No se pudo bajar en paso " .. i)
        end
    end

    Logger.info("En capa " .. layer)
end

-- ============================================================
-- Función principal
-- ============================================================

function Miner.run()
    Logger.info("=== CCAP Miner v1 (Quarry) iniciando ===")

    -- Intentar recuperar sesión anterior
    local savedState = State.load()
    if savedState then
        Logger.info(string.format(
            "Reanudando sesion: pozo=%d/%d capa=%d/%d",
            savedState.shaftDug     or 0, Config.SHAFT_DEPTH,
            savedState.currentLayer or 0, Config.SHAFT_DEPTH
        ))
        session.shaftDug     = savedState.shaftDug     or 0
        session.currentLayer = savedState.currentLayer or 0
        session.moveCount    = savedState.moveCount    or 0
        session.phase        = savedState.phase        or "SHAFT"
        Movement.setState(
            { x = savedState.x or 0, y = savedState.y or 0, z = savedState.z or 0 },
            savedState.dir or "north"
        )
    else
        Logger.info("Nueva sesion de quarry")
        Movement.resetState()
        session.phase        = "PREPARING"
        session.shaftDug     = 0
        session.currentLayer = 0
        session.moveCount    = 0
    end

    -- ============================================================
    -- Recuperar fase incompleta
    -- ============================================================

    if session.phase == "RETURNING" then
        Logger.info("Reanudando: completando retorno...")
        returnToBase()
        unloadInventory()
        if session.currentLayer >= Config.SHAFT_DEPTH then
            State.clear()
            Logger.info("=== Sesion completada al reanudar ===")
            return
        end
        session.phase = "SHAFT"

    elseif session.phase == "UNLOADING" then
        Logger.info("Reanudando: completando descarga...")
        returnToBase()
        unloadInventory()
        if session.currentLayer >= Config.SHAFT_DEPTH then
            State.clear()
            Logger.info("=== Sesion completada al reanudar ===")
            return
        end
        session.phase = "SHAFT"

    elseif session.phase == "PREPARING" or session.phase == "IDLE" then
        if not validatePreConditions() then
            Logger.error("No se puede iniciar. Corrige el problema y ejecuta startup.")
            return
        end
        session.phase = "SHAFT"
    end

    -- Si reanudamos en SHAFT o LAYERS con progreso, bajar al nivel correcto
    if session.shaftDug >= Config.SHAFT_DEPTH and session.currentLayer > 0 then
        travelToLayer()
    end

    -- ============================================================
    -- Bucle principal
    -- ============================================================

    while session.currentLayer < Config.SHAFT_DEPTH do

        State.save(buildStateSnapshot("SHAFT"))

        local reason = Quarry.run(session)

        -- Guardar antes de moverse
        session.phase = "RETURNING"
        State.save(buildStateSnapshot("RETURNING"))

        returnToBase()

        session.phase = "UNLOADING"
        unloadInventory()

        if reason == "COMPLETE" then
            break
        end

        -- Interrumpido por fuel o inventario: verificar y volver al quarry
        Logger.info(string.format(
            "Ciclo interrumpido (%s). Pozo=%d capa=%d",
            reason, session.shaftDug, session.currentLayer
        ))

        if not Fuel.ensureFuel(Config.SHAFT_DEPTH * 2 + Config.QUARRY_WIDTH * Config.QUARRY_LENGTH) then
            Logger.error("Sin fuel suficiente para continuar. Abortando.")
            break
        end

        travelToLayer()
    end

    -- ============================================================
    -- COMPLETE
    -- ============================================================

    session.phase = "COMPLETE"
    State.clear()

    Logger.info(string.format(
        "=== Quarry finalizado. Pozo: %d bloques. Capas: %d/%d ===",
        session.shaftDug, session.currentLayer, Config.SHAFT_DEPTH
    ))
    print("")
    print("Quarry completo! Revisa el cofre para tus recursos.")
    print("Ejecuta 'startup' para iniciar un nuevo quarry.")
end

return Miner
