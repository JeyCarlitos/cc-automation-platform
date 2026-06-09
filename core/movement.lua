-- core/movement.lua
-- Wrapper de movimiento de la turtle con tracking de posición relativa.
--
-- REGLA: ningún otro módulo llama a turtle.forward/back/up/down/turn* directamente.
--        Todo movimiento pasa por aquí para mantener pos y dir consistentes.
--
-- Sistema de coordenadas:
--   Origen:  posición de inicio de la turtle → {x=0, y=0, z=0}
--   Norte:   dirección inicial de la turtle  → z aumenta al avanzar
--   Y:       sube al ir hacia arriba
--
-- Uso:
--   local Movement = require("core.movement")
--   Movement.digForward()
--   local p = Movement.getPos()  -- { x, y, z }
--   local d = Movement.getDir()  -- "north" | "south" | "east" | "west"

local Logger = require("core.logger")

local Movement = {}

-- ============================================================
-- Estado interno
-- ============================================================

local pos = { x = 0, y = 0, z = 0 }
local dir = "north"

-- Vectores de desplazamiento por dirección
local DIR_DELTA = {
    north = { x =  0, z = -1 },
    south = { x =  0, z =  1 },
    east  = { x =  1, z =  0 },
    west  = { x = -1, z =  0 },
}

-- Rotaciones
local TURN_LEFT  = { north = "west",  west = "south", south = "east", east = "north" }
local TURN_RIGHT = { north = "east",  east = "south", south = "west", west = "north" }

-- ============================================================
-- Helper: reintentar acción para tolerar bloques cayendo / mobs
-- ============================================================

local function retry(fn, maxAttempts)
    maxAttempts = maxAttempts or 3
    for i = 1, maxAttempts do
        if fn() then return true end
        if i < maxAttempts then sleep(0.4) end
    end
    return false
end

-- ============================================================
-- Movimientos básicos
-- ============================================================

function Movement.forward()
    if not retry(turtle.forward) then
        Logger.warn("Movement.forward: bloqueado")
        return false
    end
    local d = DIR_DELTA[dir]
    pos.x = pos.x + d.x
    pos.z = pos.z + d.z
    return true
end

function Movement.back()
    if not retry(turtle.back) then
        Logger.warn("Movement.back: bloqueado")
        return false
    end
    local d = DIR_DELTA[dir]
    pos.x = pos.x - d.x
    pos.z = pos.z - d.z
    return true
end

function Movement.up()
    if not retry(turtle.up) then
        Logger.warn("Movement.up: bloqueado")
        return false
    end
    pos.y = pos.y + 1
    return true
end

function Movement.down()
    if not retry(turtle.down) then
        Logger.warn("Movement.down: bloqueado")
        return false
    end
    pos.y = pos.y - 1
    return true
end

function Movement.turnLeft()
    turtle.turnLeft()
    dir = TURN_LEFT[dir]
    return true
end

function Movement.turnRight()
    turtle.turnRight()
    dir = TURN_RIGHT[dir]
    return true
end

-- ============================================================
-- Movimientos con excavación (dig + move)
-- ============================================================

-- Excava el bloque frontal y avanza. Reintenta si hay bloque cayendo.
function Movement.digForward()
    retry(turtle.dig)
    return Movement.forward()
end

-- Excava el bloque superior y sube.
function Movement.digUp()
    retry(turtle.digUp)
    return Movement.up()
end

-- Excava el bloque inferior y baja.
function Movement.digDown()
    retry(turtle.digDown)
    return Movement.down()
end

-- ============================================================
-- Navegación de orientación
-- ============================================================

-- Gira hasta quedar mirando targetDir. Máximo 4 giros.
function Movement.faceDir(targetDir)
    if not DIR_DELTA[targetDir] then
        Logger.error("faceDir: dirección inválida: " .. tostring(targetDir))
        return
    end
    local attempts = 0
    while dir ~= targetDir and attempts < 4 do
        Movement.turnRight()
        attempts = attempts + 1
    end
end

-- ============================================================
-- Accesores y setters de estado
-- ============================================================

-- Devuelve copia de la posición actual.
function Movement.getPos()
    return { x = pos.x, y = pos.y, z = pos.z }
end

-- Devuelve la dirección actual.
function Movement.getDir()
    return dir
end

-- Restaura posición y dirección (usado al recuperar sesión guardada).
function Movement.setState(savedPos, savedDir)
    pos.x = savedPos.x
    pos.y = savedPos.y
    pos.z = savedPos.z
    dir   = savedDir
    Logger.debug(string.format("Movement state restored: x=%d y=%d z=%d dir=%s",
        pos.x, pos.y, pos.z, dir))
end

-- Resetea al origen. Úsalo solo al iniciar una sesión nueva.
function Movement.resetState()
    pos = { x = 0, y = 0, z = 0 }
    dir = "north"
end

return Movement
