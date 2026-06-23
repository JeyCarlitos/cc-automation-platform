-- turtles/farmer/crop.lua
-- Definición de cultivos soportados y helpers de madurez/semilla.
--
-- Cada entrada tiene:
--   maxAge  → valor de state.age en el que el cultivo está listo para cosechar
--   seed    → nombre del ítem necesario para replantar
--
-- Uso:
--   local Crop = require("turtles.farmer.crop")
--   local ok, data = turtle.inspectDown()
--   if Crop.isMature(data) then
--       turtle.digDown()
--       Crop.getSeed(data.name)  -- semilla a replantar
--   end

local Crop = {}

-- ============================================================
-- Tabla de cultivos
-- ============================================================
-- Ampliar aquí para añadir soporte a cultivos de mods.

Crop.CROPS = {
    ["minecraft:wheat"]     = { maxAge = 7, seed = "minecraft:wheat_seeds"    },
    ["minecraft:carrots"]   = { maxAge = 7, seed = "minecraft:carrot"         },
    ["minecraft:potatoes"]  = { maxAge = 7, seed = "minecraft:potato"         },
    ["minecraft:beetroots"] = { maxAge = 3, seed = "minecraft:beetroot_seeds" },
}

-- ============================================================
-- Consultas
-- ============================================================

-- ¿Es un cultivo soportado?
function Crop.isCrop(name)
    return Crop.CROPS[name] ~= nil
end

-- ¿El bloque inspeccionado está maduro para cosechar?
-- data: tabla devuelta por turtle.inspectDown() (incluye .name y .state)
function Crop.isMature(data)
    if not data or not data.name then return false end
    local info = Crop.CROPS[data.name]
    if not info then return false end
    local age = (data.state and data.state.age) or 0
    return age >= info.maxAge
end

-- Devuelve la semilla necesaria para replantar este tipo de cultivo.
-- Retorna nil si el cultivo no está en la tabla.
function Crop.getSeed(cropName)
    local info = Crop.CROPS[cropName]
    return info and info.seed or nil
end

-- Devuelve la edad máxima de este cultivo.
function Crop.getMaxAge(cropName)
    local info = Crop.CROPS[cropName]
    return info and info.maxAge or nil
end

-- Devuelve un set { [seedName] = true } con todas las semillas de cultivos soportados.
-- Útil para construir la lista de ítems protegidos.
function Crop.allSeeds()
    local seeds = {}
    for _, info in pairs(Crop.CROPS) do
        seeds[info.seed] = true
    end
    return seeds
end

return Crop
