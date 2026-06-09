-- core/fuel.lua
-- Gestión de combustible de la turtle.
--
-- Regla principal: antes de cualquier bloque de movimientos,
-- llamar Fuel.ensureFuel(extraBlocksNeeded).
-- Si retorna false, la turtle debe regresar a base.
--
-- Uso:
--   local Fuel = require("core.fuel")
--   if not Fuel.ensureFuel(20) then
--       -- iniciar retorno
--   end

local Config   = require("config.config")
local Logger   = require("core.logger")
local Movement = require("core.movement")

local Fuel = {}

-- ============================================================
-- Consultas básicas
-- ============================================================

-- Nivel de combustible actual.
function Fuel.getLevel()
    return turtle.getFuelLevel()
end

-- Costo estimado de retorno al origen basado en posición actual.
-- Usa distancia Manhattan: |x| + |y| + |z|.
-- Es una cota inferior; el camino real puede ser levemente mayor.
function Fuel.estimateReturnCost()
    local p = Movement.getPos()
    return math.abs(p.x) + math.abs(p.y) + math.abs(p.z)
end

-- ¿Hay suficiente combustible para moverse 'extra' bloques y regresar?
-- Incluye el margen de seguridad configurado.
function Fuel.hasSufficient(extra)
    extra = extra or 0
    local needed = Fuel.estimateReturnCost() + extra + Config.FUEL_SAFETY_MARGIN
    return Fuel.getLevel() >= needed
end

-- ============================================================
-- Refuel
-- ============================================================

-- Intenta refueler consumiendo ítems combustibles del inventario.
-- Retorna true si se ganó algo de fuel.
function Fuel.refuelFromInventory()
    local before = Fuel.getLevel()

    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            turtle.select(slot)
            -- refuel(0) no consume nada pero verifica si el ítem es combustible
            if turtle.refuel(0) then
                turtle.refuel()
                Logger.debug("Refueled from slot " .. slot)
            end
        end
    end
    turtle.select(1)

    local gained = Fuel.getLevel() - before
    if gained > 0 then
        Logger.info(string.format("Refueled +%d fuel (total: %d)", gained, Fuel.getLevel()))
    end
    return gained > 0
end

-- ============================================================
-- Garantía de fuel
-- ============================================================

-- Asegura que hay fuel suficiente para 'extra' bloques adicionales y el retorno.
-- Intenta refuel automático si es necesario.
-- Retorna:
--   true  → fuel OK, se puede continuar
--   false → fuel insuficiente incluso después de refuel (debe regresar)
function Fuel.ensureFuel(extra)
    extra = extra or 0

    if Fuel.hasSufficient(extra) then return true end

    Logger.info(string.format(
        "Fuel bajo (%d). Intentando refuel... (necesario: %d+%d+%d)",
        Fuel.getLevel(),
        Fuel.estimateReturnCost(),
        extra,
        Config.FUEL_SAFETY_MARGIN
    ))

    Fuel.refuelFromInventory()

    if Fuel.hasSufficient(extra) then return true end

    Logger.warn(string.format(
        "Fuel insuficiente para continuar. Nivel: %d | Estimado para retorno: %d",
        Fuel.getLevel(),
        Fuel.estimateReturnCost()
    ))
    return false
end

return Fuel
