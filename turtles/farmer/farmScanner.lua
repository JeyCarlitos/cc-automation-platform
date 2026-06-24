-- turtles/farmer/farmScanner.lua
-- Descubre automáticamente el área cultivable de la granja.
--
-- *** ALTURA DE NAVEGACIÓN ***
-- El scanner navega a y=1 (NUNCA a y=0) para no pisar el farmland.
--
--   y=-1 (rel) → farmland (bloque de tierra arada)
--   y= 0 (rel) → nivel del cultivo (aquí crece el trigo/zanahoria/etc.)
--   y= 1 (rel) → altura de navegación segura (turtle está ENCIMA del cultivo)
--
-- Desde y=1, inspectDown() ve el bloque en y=0:
--   - Cultivo conocido  → farmland confirmado debajo (y=-1) → marcar como plot
--   - Aire              → farmland vacío posible → intentar plantar semilla
--                         Si placeDown() funciona → farmland confirmado + semilla plantada
--                         Si falla               → no es farmland, ignorar
--   - Otro bloque       → no es área de cultivo, ignorar
--
-- PRERREQUISITO: la turtle debe estar en HOME (0,0) al llamar scan().
-- Al terminar regresa a HOME a y=0 y queda mirando north.

local Config    = require("config.config")
local Logger    = require("core.logger")
local Nav       = require("core.nav")
local Fuel      = require("core.fuel")
local Movement  = require("core.movement")
local Crop      = require("turtles.farmer.crop")

local FarmScanner = {}

-- ============================================================
-- Detección de farmland desde y=1
-- ============================================================

-- Busca cualquier semilla en el inventario.
-- Retorna (slot, nombre) o (nil, nil) si no hay ninguna.
local function findAnySeed()
    for name, _ in pairs(Crop.allSeeds()) do
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d and d.name == name then
                return slot, name
            end
        end
    end
    return nil, nil
end

-- Detecta si la celda actual contiene farmland. Se llama desde y=1.
-- inspectDown() ve y=0 (nivel del cultivo).
--
-- Lógica:
--   1. Hay cultivo conocido abajo → farmland confirmado (respeta el cultivo)
--   2. Hay aire abajo             → probar placeDown() con semilla
--      Si planta OK → farmland confirmado; semilla queda plantada (¡útil!)
--      Si falla     → no hay farmland en y=-1
--   3. Otro bloque                → no es área de cultivo
local function detectFarmlandFromAbove()
    local hasBlock, data = turtle.inspectDown()

    -- Caso 1: cultivo conocido → farmland confirmado
    if hasBlock and Crop.isCrop(data.name) then
        return true
    end

    -- Caso 3: bloque no-cultivo → no es farmland
    if hasBlock then
        return false
    end

    -- Caso 2: aire → verificar con semilla
    local seedSlot = findAnySeed()
    if not seedSlot then
        Logger.debug("[Scanner] Sin semillas para verificar celda vacía")
        return false
    end

    turtle.select(seedSlot)
    local planted = turtle.placeDown()
    turtle.select(1)

    if planted then
        Logger.debug(string.format(
            "[Scanner] Farmland vacío confirmado en (%d,%d) — semilla plantada",
            Movement.getPos().x, Movement.getPos().z
        ))
        return true
    end

    return false
end

-- ============================================================
-- Subir / bajar (con reintentos y dig)
-- ============================================================

local function goUp()
    for _ = 1, 5 do
        if Movement.up() then return true end
        turtle.digUp()
        sleep(0.2)
    end
    Logger.error("[Scanner] No se pudo subir a y=1")
    return false
end

local function goDown()
    for _ = 1, 5 do
        if Movement.down() then return true end
        turtle.digDown()
        sleep(0.2)
    end
    Logger.error("[Scanner] No se pudo bajar a y=0")
    return false
end

-- ============================================================
-- Escaneo principal
-- ============================================================

-- Recorre una cuadrícula (2*radius+1)² centrada en HOME buscando farmland.
-- Navega a y=1 para nunca pisar el farmland.
-- Retorna array de { x=int, z=int }.
function FarmScanner.scan(radius)
    radius = radius or Config.FARM_SCAN_RADIUS or 16

    -- Subir a y=1 ANTES de moverse sobre el farmland
    if Movement.getPos().y < 1 then
        Logger.info("[Scanner] Subiendo a y=1 para no pisar el farmland...")
        if not goUp() then
            Logger.error("[Scanner] No se pudo subir — abortando")
            return {}
        end
    end

    local plots   = {}
    local skipped = 0
    local rowIdx  = 0

    Logger.info(string.format(
        "[Scanner] Inicio a y=1. Radio: %d (~%d celdas)",
        radius, (2*radius+1)^2
    ))

    for z = -radius, radius do
        -- Lista de X con patrón serpentín
        local xList = {}
        for x = -radius, radius do xList[#xList+1] = x end
        if rowIdx % 2 == 1 then
            local rev = {}
            for i = #xList, 1, -1 do rev[#rev+1] = xList[i] end
            xList = rev
        end
        rowIdx = rowIdx + 1

        for _, x in ipairs(xList) do
            -- Fuel check: reserva para volver a HOME
            local p = Movement.getPos()
            local returnDist = math.abs(p.x) + math.abs(p.z) + 4
            if not Fuel.hasSufficient(returnDist) then
                Logger.warn("[Scanner] Fuel bajo — abortando")
                Nav.navXZ(0, 0)
                goDown()
                Movement.faceDir("north")
                Logger.info(string.format(
                    "[Scanner] Abortado por fuel. %d plots, %d saltadas.",
                    #plots, skipped
                ))
                return plots
            end

            -- Navegar a la celda sin pisar farmland (permanecemos en y=1)
            local reached = Nav.navXZ(x, z)
            if not reached then
                skipped = skipped + 1
                Logger.warn(string.format("[Scanner] Celda (%d,%d) inaccesible, saltando", x, z))
            else
                sleep(0)
                if detectFarmlandFromAbove() then
                    plots[#plots+1] = { x = x, z = z }
                    Logger.debug(string.format("[Scanner] Plot en x=%d z=%d", x, z))
                end
            end
        end
    end

    Logger.info(string.format(
        "[Scanner] Terminado. %d plots, %d saltadas.",
        #plots, skipped
    ))

    -- Regresar a HOME a y=1, luego bajar a y=0
    Nav.navXZ(0, 0)
    goDown()
    Movement.faceDir("north")

    return plots
end

return FarmScanner
