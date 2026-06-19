-- config/constants.lua
-- Constantes compartidas entre todos los módulos de CCAP.
--
-- Centraliza datos que antes estaban duplicados en quarry.lua y miner.lua.
-- Importar con:  local Constants = require("config.constants")

local Constants = {}

-- ============================================================
-- Bloques irrompibles
-- ============================================================
-- Bloques que ninguna turtle puede destruir.
-- Usados para detectar bedrock, barriers y otros límites de mundo.

Constants.UNBREAKABLE = {
    ["minecraft:bedrock"]                 = true,
    ["minecraft:barrier"]                 = true,
    ["minecraft:command_block"]           = true,
    ["minecraft:chain_command_block"]     = true,
    ["minecraft:repeating_command_block"] = true,
    ["minecraft:end_portal_frame"]        = true,
    ["minecraft:reinforced_deepslate"]    = true,
}

-- ¿Es un bloque irrompible? (bedrock, barrier, etc.)
function Constants.isUnbreakable(name)
    return name ~= nil and Constants.UNBREAKABLE[name] == true
end

-- ¿Es otra turtle? (CC:Tweaked: computercraft:turtle_normal / turtle_advanced)
function Constants.isTurtleBlock(name)
    return name ~= nil and name:find("turtle") ~= nil
end

-- ¿Es lava? (cualquier variante: lava, lava_cauldron, etc.)
function Constants.isLava(name)
    return name ~= nil and (name == "minecraft:lava" or name:find("lava") ~= nil)
end

return Constants
