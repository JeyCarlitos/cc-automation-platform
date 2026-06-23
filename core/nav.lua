-- core/nav.lua
-- Navegación 2D en superficie (plano XZ) con evasión de obstáculos.
--
-- PROBLEMA que resuelve:
--   El navXZ simple (dig + forward) entra en bucle infinito al toparse
--   con una pared irrompible o un bloque que no cede tras varios intentos.
--
-- ESTRATEGIA:
--   1. Intentar moverse en la dirección principal (hasta MAX_DIG_ATTEMPTS
--      veces, excavando entre intentos).
--   2. Si falla, intentar un rodeo perpendicular (moverse en Z o X según
--      cuál esté bloqueado) y reintentar la dirección principal.
--   3. Si después del rodeo sigue bloqueado, incrementar stuckCount.
--   4. Al llegar a MAX_STUCK sin avance real, loguear error y retornar false.
--      El llamador decide qué hacer (saltar la celda, abortar, etc.).
--
-- Uso:
--   local Nav = require("core.nav")
--   Nav.navXZ(10, 5)          -- retorna true si llegó, false si no pudo
--   Nav.goHome()              -- navega a (0,0) en el plano XZ

local Logger   = require("core.logger")
local Movement = require("core.movement")

local Nav = {}

-- Número máximo de ciclos dig+forward antes de declarar esa dirección bloqueada.
local MAX_DIG_ATTEMPTS = 4

-- Número máximo de iteraciones del bucle principal sin avance antes de rendirse.
local MAX_STUCK = 20

-- Bloques que nunca se intentan cavar (evita desperdiciar tiempo en paredes admin).
local UNBREAKABLE = {
    ["minecraft:bedrock"]                 = true,
    ["minecraft:barrier"]                 = true,
    ["minecraft:command_block"]           = true,
    ["minecraft:chain_command_block"]     = true,
    ["minecraft:repeating_command_block"] = true,
    ["minecraft:end_portal_frame"]        = true,
    ["minecraft:reinforced_deepslate"]    = true,
}

-- ============================================================
-- Helpers internos
-- ============================================================

-- Intenta moverse hacia 'dir' excavando si es necesario.
-- Retorna true si la turtle avanzó un bloque.
local function moveDir(dir)
    Movement.faceDir(dir)
    for _ = 1, MAX_DIG_ATTEMPTS do
        if Movement.forward() then return true end

        local hasBlock, data = turtle.inspect()
        if hasBlock then
            if UNBREAKABLE[data.name] then
                return false  -- irrompible → no tiene sentido seguir
            end
            turtle.dig()
            sleep(0.25)
        else
            -- Posible entidad bloqueando (mob, otra turtle, etc.)
            sleep(0.4)
        end
    end
    return false
end

-- ============================================================
-- API pública
-- ============================================================

-- Navega de la posición actual a (targetX, targetZ) en el plano XZ.
-- No modifica Y.
--
-- Estrategia de movimiento:
--   - Prioriza el eje con mayor delta (reduce distancia total).
--   - Si el eje preferido está bloqueado, intenta el otro eje como rodeo.
--   - Si ambos están bloqueados, incrementa stuckCount.
--   - Tras MAX_STUCK iteraciones sin avance, retorna false (no rompe el programa).
--
-- Retorna true si llegó al destino, false si no pudo alcanzarlo.
function Nav.navXZ(targetX, targetZ)
    local stuckCount = 0

    while true do
        local p = Movement.getPos()
        if p.x == targetX and p.z == targetZ then return true end

        local dx = targetX - p.x
        local dz = targetZ - p.z
        local moved = false

        -- Elegir eje primario (mayor delta absoluto)
        if math.abs(dx) >= math.abs(dz) then
            -- Eje X primero
            if dx ~= 0 then
                local dir = dx > 0 and "east" or "west"
                if moveDir(dir) then
                    moved = true
                elseif dz ~= 0 then
                    -- X bloqueado → rodeo por Z
                    moved = moveDir(dz > 0 and "south" or "north")
                end
            elseif dz ~= 0 then
                moved = moveDir(dz > 0 and "south" or "north")
            end
        else
            -- Eje Z primero
            if dz ~= 0 then
                local dir = dz > 0 and "south" or "north"
                if moveDir(dir) then
                    moved = true
                elseif dx ~= 0 then
                    -- Z bloqueado → rodeo por X
                    moved = moveDir(dx > 0 and "east" or "west")
                end
            elseif dx ~= 0 then
                moved = moveDir(dx > 0 and "east" or "west")
            end
        end

        if moved then
            stuckCount = 0
        else
            stuckCount = stuckCount + 1

            if stuckCount >= MAX_STUCK then
                local cur = Movement.getPos()
                Logger.error(string.format(
                    "[Nav] Atascado en (%d,%d) — objetivo (%d,%d). Celda descartada.",
                    cur.x, cur.z, targetX, targetZ
                ))
                return false
            end

            -- Último recurso: moverse en cualquier dirección libre para
            -- salir del rincón antes del próximo intento.
            local escaped = false
            for _, d in ipairs({"north","east","south","west"}) do
                if moveDir(d) then
                    escaped = true
                    break
                end
            end
            if not escaped then
                sleep(0.5)  -- nada funciona, esperar un tick (mob u otro obstáculo temporal)
            end
        end

        sleep(0)  -- yield al scheduler de CC
    end
end

-- Navega a HOME (0,0) en el plano XZ sin cambiar Y.
-- Equivalente a Nav.navXZ(0, 0).
function Nav.goHome()
    return Nav.navXZ(0, 0)
end

return Nav
