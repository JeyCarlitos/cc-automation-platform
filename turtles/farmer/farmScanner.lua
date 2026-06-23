-- turtles/farmer/farmScanner.lua
-- Descubre automáticamente el área cultivable de la granja.
--
-- PRERREQUISITO: la turtle debe estar en HOME (y=0) al llamar scan().
-- El HOME es la posición inicial de la turtle (junto al cofre), que queda
-- exactamente un bloque POR ENCIMA del nivel del farmland.  Desde ahí,
-- turtle.inspectDown() retorna el bloque de farmland al nivel del suelo.
--
-- ALGORITMO:
--   Cuadrícula serpentín de (-radius, -radius) a (+radius, +radius).
--   En cada celda se llama inspectDown().  Si es "minecraft:farmland"
--   se registra la posición (x, z) relativa a HOME.
--
-- Al terminar regresa a HOME y queda mirando north.
--
-- Uso:
--   local FarmScanner = require("turtles.farmer.farmScanner")
--   local plots = FarmScanner.scan(16)  -- radio en bloques

local Config   = require("config.config")
local Logger   = require("core.logger")
local Movement = require("core.movement")
local Fuel     = require("core.fuel")

local FarmScanner = {}

-- ============================================================
-- Navegación XZ interna (permanece en Y actual)
-- ============================================================

-- Mueve la turtle de su posición actual a (targetX, targetZ) sin cambiar Y.
-- Si un bloque obstaculiza el camino lo excava (plantas, etc.).
local function navXZ(targetX, targetZ)
    -- Eje X
    while Movement.getPos().x ~= targetX do
        local d = Movement.getPos().x < targetX and "east" or "west"
        Movement.faceDir(d)
        if not Movement.forward() then
            turtle.dig()
            sleep(0.2)
            Movement.forward()
        end
        sleep(0)
    end
    -- Eje Z
    while Movement.getPos().z ~= targetZ do
        local d = Movement.getPos().z < targetZ and "south" or "north"
        Movement.faceDir(d)
        if not Movement.forward() then
            turtle.dig()
            sleep(0.2)
            Movement.forward()
        end
        sleep(0)
    end
end

-- ============================================================
-- Detección de farmland
-- ============================================================

local function isFarmlandBelow()
    local hasBlock, data = turtle.inspectDown()
    return hasBlock and data.name == "minecraft:farmland"
end

-- ============================================================
-- Escaneo principal
-- ============================================================

-- Recorre una cuadrícula (2*radius+1)² centrada en HOME buscando farmland.
-- Retorna array de { x=int, z=int }.
-- La turtle debe estar en HOME (y=0) y regresará a HOME al terminar.
function FarmScanner.scan(radius)
    radius = radius or Config.FARM_SCAN_RADIUS or 16

    local plots   = {}
    local visited = {}

    local function key(x, z) return x .. "," .. z end

    Logger.info(string.format(
        "[Scanner] Inicio. Radio: %d (~%d celdas)",
        radius, (2*radius+1)^2
    ))

    local rowIdx = 0  -- para calcular paridad del serpentín

    for z = -radius, radius do
        -- Construir lista de X para esta fila
        local xList = {}
        for x = -radius, radius do
            xList[#xList+1] = x
        end
        -- Filas impares: recorrer en dirección decreciente
        if rowIdx % 2 == 1 then
            local rev = {}
            for i = #xList, 1, -1 do rev[#rev+1] = xList[i] end
            xList = rev
        end
        rowIdx = rowIdx + 1

        for _, x in ipairs(xList) do
            -- Verificar fuel: debe alcanzar para volver a HOME más un margen
            local returnDist = math.abs(Movement.getPos().x)
                             + math.abs(Movement.getPos().z) + 4
            if not Fuel.hasSufficient(returnDist) then
                Logger.warn("[Scanner] Fuel bajo — abortando y regresando a HOME")
                navXZ(0, 0)
                Movement.faceDir("north")
                return plots
            end

            navXZ(x, z)
            sleep(0)  -- yield para no bloquear el scheduler de CC

            local k = key(x, z)
            if not visited[k] then
                visited[k] = true
                if isFarmlandBelow() then
                    plots[#plots+1] = { x = x, z = z }
                    Logger.debug(string.format(
                        "[Scanner] Farmland en x=%d z=%d", x, z
                    ))
                end
            end
        end
    end

    Logger.info(string.format(
        "[Scanner] Terminado. %d plots de farmland encontrados.", #plots
    ))

    -- Regresar a HOME
    navXZ(0, 0)
    Movement.faceDir("north")

    return plots
end

return FarmScanner
