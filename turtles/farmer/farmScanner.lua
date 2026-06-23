-- turtles/farmer/farmScanner.lua
-- Descubre automáticamente el área cultivable de la granja.
--
-- PRERREQUISITO: la turtle debe estar en HOME (y=0) al llamar scan().
-- El HOME queda exactamente un bloque POR ENCIMA del nivel del farmland.
-- Desde ahí, turtle.inspectDown() retorna el bloque de farmland.
--
-- ALGORITMO:
--   Cuadrícula serpentín de (-radius,-radius) a (+radius,+radius).
--   En cada celda se llama Nav.navXZ() y luego inspectDown().
--   Si la celda no es alcanzable (pared, obstáculo), se descarta y
--   el scanner continúa con la siguiente — nunca se queda atascado.
--
-- Al terminar regresa a HOME y queda mirando north.
--
-- Uso:
--   local FarmScanner = require("turtles.farmer.farmScanner")
--   local plots = FarmScanner.scan(16)  -- radio en bloques

local Config = require("config.config")
local Logger = require("core.logger")
local Nav    = require("core.nav")
local Fuel   = require("core.fuel")
local Movement = require("core.movement")

local FarmScanner = {}

-- ¿El bloque directamente debajo es farmland?
local function isFarmlandBelow()
    local hasBlock, data = turtle.inspectDown()
    return hasBlock and data.name == "minecraft:farmland"
end

-- ============================================================
-- Escaneo principal
-- ============================================================

-- Recorre una cuadrícula (2*radius+1)² centrada en HOME buscando farmland.
-- Las celdas inaccesibles se saltan automáticamente.
-- Retorna array de { x=int, z=int }.
-- La turtle debe estar en HOME (y=0) y regresará a HOME al terminar.
function FarmScanner.scan(radius)
    radius = radius or Config.FARM_SCAN_RADIUS or 16

    local plots   = {}
    local skipped = 0
    local rowIdx  = 0  -- para paridad del serpentín

    Logger.info(string.format(
        "[Scanner] Inicio. Radio: %d (~%d celdas)",
        radius, (2*radius+1)^2
    ))

    for z = -radius, radius do
        -- Construir lista de X para esta fila (serpentín)
        local xList = {}
        for x = -radius, radius do xList[#xList+1] = x end
        if rowIdx % 2 == 1 then
            local rev = {}
            for i = #xList, 1, -1 do rev[#rev+1] = xList[i] end
            xList = rev
        end
        rowIdx = rowIdx + 1

        for _, x in ipairs(xList) do
            -- Fuel check: asegurar que puede volver a HOME
            local returnDist = math.abs(Movement.getPos().x)
                             + math.abs(Movement.getPos().z) + 4
            if not Fuel.hasSufficient(returnDist) then
                Logger.warn("[Scanner] Fuel bajo — abortando y regresando a HOME")
                Nav.navXZ(0, 0)
                Movement.faceDir("north")
                Logger.info(string.format(
                    "[Scanner] Abortado por fuel. %d plots, %d celdas saltadas.",
                    #plots, skipped
                ))
                return plots
            end

            -- Navegar a la celda; si no se puede alcanzar, saltar
            local reached = Nav.navXZ(x, z)
            if not reached then
                skipped = skipped + 1
                Logger.warn(string.format("[Scanner] Celda (%d,%d) inaccesible, saltando", x, z))
            else
                sleep(0)  -- yield
                if isFarmlandBelow() then
                    plots[#plots+1] = { x = x, z = z }
                    Logger.debug(string.format("[Scanner] Farmland en x=%d z=%d", x, z))
                end
            end
        end
    end

    Logger.info(string.format(
        "[Scanner] Terminado. %d plots encontrados, %d celdas saltadas.",
        #plots, skipped
    ))

    -- Regresar a HOME
    Nav.navXZ(0, 0)
    Movement.faceDir("north")

    return plots
end

return FarmScanner
