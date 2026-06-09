-- turtles/miner/branchMining.lua
-- Algoritmo de Branch Mining.
--
-- Patrón:
--   Túnel principal →→→→→→→→→→→→→→→→→→→→→→
--                    ↑     ↑     ↑     ↑
--                  rama  rama  rama  rama   (izquierda y derecha en cada punto)
--
-- La turtle:
--   1. Avanza BRANCH_SPACING bloques por el túnel principal.
--   2. Excava una rama izquierda de BRANCH_LENGTH bloques y regresa.
--   3. Excava una rama derecha de BRANCH_LENGTH bloques y regresa.
--   4. Repite hasta completar TUNNEL_LENGTH bloques.
--
-- Cada movimiento actualiza sessionData.moveCount para persistencia.
-- Si detecta fuel bajo o inventario lleno, detiene la minería y retorna
-- la razón ("FUEL" | "INVENTORY") para que miner.lua gestione el retorno.
--
-- Este módulo NO conoce nada sobre persistencia, retorno ni descarga.
-- Solo mina. miner.lua coordina el resto.

local Config    = require("config.config")
local Logger    = require("core.logger")
local Movement  = require("core.movement")
local Fuel      = require("core.fuel")
local Inventory = require("core.inventory")

local BranchMining = {}

-- ============================================================
-- Helpers internos
-- ============================================================

-- Excava techo + frente y avanza un bloque.
-- El túnel tiene 2 bloques de alto para que la turtle pueda moverse sin obstrucción.
local function digAndStep(sessionData)
    turtle.digUp()         -- techo del túnel
    turtle.dig()           -- bloque frontal (por si fue colocado por caída)
    if Movement.forward() then
        sessionData.moveCount = (sessionData.moveCount or 0) + 1
        return true
    end
    return false
end

-- ============================================================
-- Rama lateral
-- ============================================================

-- Excava una rama en 'side' ("left" | "right") y regresa al punto de entrada.
-- No interrumpe por inventario lleno (las ramas son cortas).
-- Sí interrumpe por fuel crítico: deja de avanzar y regresa lo que pudo.
local function mineBranch(side, sessionData)
    Logger.debug("Rama " .. side .. " (" .. Config.BRANCH_LENGTH .. " bloques)")

    -- Girar hacia la rama
    if side == "left" then
        Movement.turnLeft()
    else
        Movement.turnRight()
    end

    -- Avanzar dentro de la rama, contando pasos reales
    local stepped = 0
    for i = 1, Config.BRANCH_LENGTH do
        -- Fuel suficiente para: bloques restantes de rama + retorno al túnel
        if not Fuel.hasSufficient(Config.BRANCH_LENGTH - i + 2) then
            Logger.warn("Fuel bajo en rama " .. side .. " en bloque " .. i)
            break
        end
        turtle.digUp()
        if Movement.forward() then
            stepped = stepped + 1
            sessionData.moveCount = (sessionData.moveCount or 0) + 1
        end
    end

    -- Girar 180° para regresar (dos giros en el mismo sentido)
    Movement.turnLeft()
    Movement.turnLeft()

    -- Regresar exactamente los pasos dados
    for i = 1, stepped do
        if turtle.detect() then turtle.dig() end
        Movement.forward()
        sessionData.moveCount = (sessionData.moveCount or 0) + 1
    end

    -- Reorientar hacia el túnel principal:
    --   Si giramos izquierda para entrar → giramos izquierda para salir (estamos mirando opuesto)
    --   Si giramos derecha para entrar   → giramos derecha para salir
    if side == "left" then
        Movement.turnLeft()
    else
        Movement.turnRight()
    end

    Logger.debug("Rama " .. side .. " completa (" .. stepped .. "/" .. Config.BRANCH_LENGTH .. " bloques)")
end

-- ============================================================
-- Función principal
-- ============================================================

-- Ejecuta el patrón completo de branch mining.
-- sessionData: tabla { mainProgress, moveCount } (modificada in-place)
-- Retorna razón de parada: "COMPLETE" | "FUEL" | "INVENTORY"
function BranchMining.run(sessionData)
    local totalBlocks  = Config.TUNNEL_LENGTH
    local spacing      = Config.BRANCH_SPACING
    local branchLen    = Config.BRANCH_LENGTH

    Logger.info(string.format(
        "Branch mining: tunel=%d, espaciado=%d, ramas=%d. Reanudando desde bloque %d.",
        totalBlocks, spacing, branchLen, sessionData.mainProgress or 0
    ))

    local block = sessionData.mainProgress or 0

    while block < totalBlocks do

        -- Verificar fuel antes del segmento: necesitamos avanzar spacing + ambas ramas
        local fuelForSegment = spacing + (branchLen * 2) + spacing  -- +spacing para la vuelta al punto
        if not Fuel.ensureFuel(fuelForSegment) then
            Logger.warn("Fuel insuficiente para continuar. Deteniendo en bloque " .. block)
            sessionData.mainProgress = block
            return "FUEL"
        end

        -- Verificar inventario
        if Inventory.isFull() then
            Logger.warn("Inventario lleno. Deteniendo en bloque " .. block)
            sessionData.mainProgress = block
            return "INVENTORY"
        end

        -- Minar el segmento del túnel principal hasta el siguiente punto de rama
        local segmentTarget = math.min(block + spacing, totalBlocks)
        for i = block + 1, segmentTarget do
            if not digAndStep(sessionData) then
                Logger.warn("No se pudo avanzar en bloque " .. i .. " del tunel principal")
            end
            sessionData.mainProgress = i
        end
        block = segmentTarget

        -- Checkpoint periódico
        if sessionData.moveCount % Config.STATE_SAVE_INTERVAL == 0 then
            -- La señal de guardado la gestiona miner.lua observando moveCount.
            -- BranchMining no importa State directamente (separación de capas).
        end

        Logger.debug("Tunel principal: " .. block .. "/" .. totalBlocks)

        -- Excavar ramas si no terminamos el túnel
        if block < totalBlocks then
            mineBranch("left",  sessionData)
            mineBranch("right", sessionData)
        end
    end

    sessionData.mainProgress = totalBlocks
    Logger.info("Tunel completo! (" .. totalBlocks .. " bloques)")
    return "COMPLETE"
end

return BranchMining
