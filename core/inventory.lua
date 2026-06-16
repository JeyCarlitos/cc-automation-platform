-- core/inventory.lua
-- Gestión del inventario de la turtle.
--
-- Responsabilidad: detectar cuándo el inventario está lleno y vaciar
-- los ítems no combustibles en la dirección indicada.
--
-- Uso:
--   local Inventory = require("core.inventory")
--   if Inventory.isFull() then
--       -- regresar a base y llamar Inventory.dropAll("forward")
--   end

local Config = require("config.config")
local Logger = require("core.logger")

local Inventory = {}

-- ============================================================
-- Consultas de slots
-- ============================================================

-- Cantidad de slots con al menos un ítem.
function Inventory.usedSlots()
    local count = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            count = count + 1
        end
    end
    return count
end

-- Slots disponibles.
function Inventory.freeSlots()
    return 16 - Inventory.usedSlots()
end

-- El inventario se considera "lleno" cuando los slots libres llegan
-- al mínimo reservado para combustible.
function Inventory.isFull()
    return Inventory.freeSlots() <= Config.INVENTORY_RESERVE
end

-- ============================================================
-- Clasificación de ítems
-- ============================================================

-- Verifica si el ítem en 'slot' es combustible sin consumirlo.
-- turtle.refuel(0) retorna true si el ítem en el slot seleccionado es combustible.
local function isFuel(slot)
    turtle.select(slot)
    local result = turtle.refuel(0)
    turtle.select(1)
    return result
end

-- ============================================================
-- Descarga de ítems
-- ============================================================

-- Tira todos los ítems no combustibles hacia 'direction'.
-- direction: "forward" | "up" | "down"
-- Respeta los slots que contienen combustible (no los descarta).
-- Retorna el número de stacks tirados.
function Inventory.dropAll(direction)
    local dropFn
    if direction == "up" then
        dropFn = turtle.dropUp
    elseif direction == "down" then
        dropFn = turtle.dropDown
    else
        dropFn = turtle.drop  -- default: forward
    end

    local dropped = 0

    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 and not isFuel(slot) then
            turtle.select(slot)
            if dropFn() then
                dropped = dropped + 1
            else
                Logger.warn("No se pudo tirar ítem del slot " .. slot .. " (cofre lleno?)")
            end
        end
    end

    turtle.select(1)
    Logger.info(string.format("Descargados %d stacks. Slots libres: %d/16", dropped, Inventory.freeSlots()))
    return dropped
end

-- ============================================================
-- Filtro de basura
-- ============================================================

-- Tabla para búsqueda O(1) de bloques basura.
local junkSet = nil
local function buildJunkSet()
    if junkSet then return end
    junkSet = {}
    for _, name in ipairs(Config.JUNK_BLOCKS or {}) do
        junkSet[name] = true
    end
end

-- Devuelve true si el ítem es un mineral (nunca se descarta).
local function isOre(name)
    return name ~= nil and (
        name:find("_ore")          ~= nil or
        name:find("ancient_debris") ~= nil or
        name:find("raw_")          ~= nil
    )
end

-- Devuelve true si el nombre de ítem es basura configurable.
local function isJunk(name)
    if name == nil then return false end
    buildJunkSet()
    return junkSet[name] == true
end

-- Descarta los ítems basura tirándolos hacia arriba (el techo ya fue excavado).
-- Nunca descarta: ores, ancient_debris, combustibles.
-- Retorna el número de slots descartados.
function Inventory.dropJunk()
    local dropped = 0
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local d = turtle.getItemDetail(slot)
            if d and isJunk(d.name) and not isOre(d.name) and not isFuel(slot) then
                turtle.select(slot)
                -- Intentar tirar arriba (techo excavado = aire).
                -- Si falla, intentar adelante o abajo como respaldo.
                if not turtle.dropUp() then
                    if not turtle.drop() then
                        turtle.dropDown()
                    end
                end
                dropped = dropped + 1
            end
        end
    end
    turtle.select(1)
    if dropped > 0 then
        Logger.debug(string.format("Basura descartada: %d slots liberados", dropped))
    end
    return dropped
end

-- ============================================================
-- Utilidades
-- ============================================================

-- Retorna el índice del primer slot con combustible, o nil si no hay.
function Inventory.findFuelSlot()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 and isFuel(slot) then
            turtle.select(1)
            return slot
        end
    end
    turtle.select(1)
    return nil
end

return Inventory
