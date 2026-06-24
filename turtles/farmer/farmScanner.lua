-- turtles/farmer/farmScanner.lua
-- Descubre automáticamente el área cultivable de la granja.
--
-- *** MODELO DE ALTURAS ***
--
--   y=-1  farmland (tierra arada)
--   y= 0  nivel del cultivo (trigo, zanahoria, etc.)
--   y= 1  altura de navegación del scanner (NUNCA bajamos a y=0 sobre farmland)
--
-- Desde y=1 el scanner usa tres métodos para detectar farmland:
--
--   CASO 1 — Cultivo en y=0
--     inspectDown() ve un cultivo conocido → farmland confirmado debajo.
--     No hacemos nada, respetamos el cultivo.
--
--   CASO 2 — Aire en y=0, farmland intacto
--     inspectDown() ve aire → puede ser farmland vacío (sin cultivo aún).
--     Probamos placeDown() con una semilla.
--     Si planta: farmland confirmado + semilla plantada (doble beneficio).
--     Si no planta: piso incorrecto, ignorar.
--
--   CASO 3 — Aire en y=0, farmland dañado (es dirt ahora)
--     placeDown() falló pero el motivo puede ser que y=-1 es dirt.
--     AQUÍ ES SEGURO BAJAR: y=0 es aire, aterrizamos sobre dirt (no farmland),
--     no hay riesgo de pisar farmland.
--     Bajamos a y=0 → usamos azada sobre y=-1 (dirt → farmland) → subimos →
--     plantamos semilla → marcamos como plot.
--
-- Al terminar regresa a HOME (0,0) a y=0 mirando north.

local Config   = require("config.config")
local Logger   = require("core.logger")
local Nav      = require("core.nav")
local Fuel     = require("core.fuel")
local Movement = require("core.movement")
local Crop     = require("turtles.farmer.crop")

local FarmScanner = {}

-- ============================================================
-- Helpers de inventario
-- ============================================================

-- Retorna el slot de cualquier semilla disponible, o nil.
local function findAnySeed()
    for name, _ in pairs(Crop.allSeeds()) do
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d and d.name == name then return slot end
        end
    end
    return nil
end

-- Retorna el slot de una azada (mejor material primero), o nil.
local HOE_NAMES = {
    "minecraft:netherite_hoe", "minecraft:diamond_hoe",
    "minecraft:iron_hoe",      "minecraft:golden_hoe",
    "minecraft:stone_hoe",     "minecraft:wooden_hoe",
}
local function findHoe()
    for _, hoeName in ipairs(HOE_NAMES) do
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d and d.name == hoeName then return slot end
        end
    end
    return nil
end

-- Intenta plantar una semilla hacia abajo. Retorna true si logró plantar.
local function tryPlantSeed()
    local seedSlot = findAnySeed()
    if not seedSlot then return false end
    turtle.select(seedSlot)
    local ok = turtle.placeDown()
    turtle.select(1)
    return ok
end

-- ============================================================
-- Subir / bajar con reintentos
-- ============================================================

local function goUp()
    for _ = 1, 5 do
        if Movement.up() then return true end
        turtle.digUp(); sleep(0.2)
    end
    return false
end

local function goDown()
    for _ = 1, 5 do
        if Movement.down() then return true end
        turtle.digDown(); sleep(0.2)
    end
    return false
end

-- ============================================================
-- Detección de farmland desde y=1
-- ============================================================

-- Tierra que se puede volver a arar (fue farmland, ahora es dirt/grass).
local TILLABLE = {
    ["minecraft:dirt"]        = true,
    ["minecraft:grass_block"] = true,
    ["minecraft:coarse_dirt"] = true,
    ["minecraft:dirt_path"]   = true,
}

-- Evalúa si la celda actual (x,z) tiene farmland y si es posible repararla.
-- La turtle DEBE estar a y=1 al llamar esta función.
-- Puede modifica el estado: puede plantar semillas, re-arar, subir/bajar.
-- Al retornar la turtle siempre queda a y=1 en la misma posición (x,z).
-- Retorna true si la celda es (o fue) farmland y está lista para cultivar.
local function detectAndRepair(hoeSlot)
    local px, pz = Movement.getPos().x, Movement.getPos().z

    -- ── CASO 1: cultivo en y=0 ────────────────────────────────
    local hasBlock, data = turtle.inspectDown()
    if hasBlock and Crop.isCrop(data.name) then
        return true  -- farmland confirmado, cultivo sano
    end

    -- bloque no-cultivo sólido en y=0 → no es área de cultivo
    if hasBlock then
        return false
    end

    -- ── CASO 2: aire en y=0, intentar plantar ─────────────────
    if tryPlantSeed() then
        Logger.debug(string.format("[Scanner] Farmland vacío confirmado (%d,%d)", px, pz))
        return true
    end

    -- ── CASO 3: planta falló → posible farmland dañado ────────
    -- Bajar a y=0 es seguro: y=0 es aire (acabamos de confirmarlo),
    -- así que aterrizamos sobre lo que sea en y=-1.
    -- Si es dirt → arar → plantar → OK.
    -- Si es otra cosa (piedra, bedrock…) → subir y descartar.
    if not hoeSlot then
        Logger.debug(string.format(
            "[Scanner] (%d,%d) sin cultivo/semilla y sin azada — ignorando", px, pz
        ))
        return false
    end

    if not goDown() then
        Logger.warn(string.format("[Scanner] No pude bajar en (%d,%d)", px, pz))
        return false
    end

    -- Ahora en y=0. Ver qué hay en y=-1.
    local hasDirt, dirtData = turtle.inspectDown()
    local canTill = hasDirt and TILLABLE[dirtData.name]

    if canTill then
        turtle.select(hoeSlot)
        local tilled = turtle.placeDown()
        turtle.select(1)

        goUp()  -- volver a y=1

        if tilled then
            Logger.info(string.format("[Scanner] Tierra re-arada en (%d,%d)", px, pz))
            tryPlantSeed()  -- plantar encima del nuevo farmland
            return true
        end
    else
        goUp()
        Logger.debug(string.format(
            "[Scanner] (%d,%d): %s — no es farmland",
            px, pz, hasDirt and dirtData.name or "vacío"
        ))
    end

    return false
end

-- ============================================================
-- Escaneo principal
-- ============================================================

-- Recorre una cuadrícula (2*radius+1)² centrada en HOME buscando farmland.
-- Navega a y=1 para no pisar el farmland.
-- Si hay azada en inventario, repara farmland dañado automáticamente.
-- Retorna array de { x=int, z=int }.
function FarmScanner.scan(radius)
    radius = radius or Config.FARM_SCAN_RADIUS or 16

    -- Localizar azada UNA VEZ al inicio (no buscar en cada celda)
    local hoeSlot = findHoe()
    if hoeSlot then
        Logger.info("[Scanner] Azada encontrada — se reparará farmland dañado")
    else
        Logger.info("[Scanner] Sin azada — solo se detectará farmland intacto")
    end

    -- Subir a y=1 ANTES de navegar sobre el área de cultivo
    if Movement.getPos().y < 1 then
        Logger.info("[Scanner] Subiendo a y=1...")
        if not goUp() then
            Logger.error("[Scanner] No se pudo subir — abortando")
            return {}
        end
    end

    local plots   = {}
    local skipped = 0
    local rowIdx  = 0

    Logger.info(string.format(
        "[Scanner] Inicio. Radio: %d (%d celdas)",
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
            -- Fuel check
            local p = Movement.getPos()
            local returnDist = math.abs(p.x) + math.abs(p.z) + 4
            if not Fuel.hasSufficient(returnDist) then
                Logger.warn("[Scanner] Fuel bajo — abortando")
                Nav.navXZ(0, 0); goDown()
                Movement.faceDir("north")
                return plots
            end

            -- Navegar a la celda (la turtle permanece en y=1)
            local reached = Nav.navXZ(x, z)
            if not reached then
                skipped = skipped + 1
                Logger.warn(string.format("[Scanner] (%d,%d) inaccesible", x, z))
            else
                sleep(0)
                -- Re-buscar azada periódicamente (puede haber sido consumida/dañada)
                if not hoeSlot then hoeSlot = findHoe() end

                if detectAndRepair(hoeSlot) then
                    plots[#plots+1] = { x = x, z = z }
                end
            end
        end
    end

    Logger.info(string.format(
        "[Scanner] Terminado. %d plots, %d inaccesibles.",
        #plots, skipped
    ))

    -- Regresar a HOME a y=1, luego bajar a y=0
    Nav.navXZ(0, 0)
    goDown()
    Movement.faceDir("north")

    return plots
end

return FarmScanner
