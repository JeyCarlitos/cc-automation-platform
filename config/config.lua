-- config/config.lua
-- Configuración central de CCAP — Chunk Quarry Vertical.

local Config = {}

-- ============================================================
-- COMBUSTIBLE
-- ============================================================
Config.FUEL_MINIMUM       = 100   -- mínimo para arrancar
Config.FUEL_SAFETY_MARGIN = 50    -- margen extra sobre el costo de retorno

-- ============================================================
-- QUARRY VERTICAL
-- ============================================================

-- Bloques que baja desde la base antes de empezar a minar la primera capa.
-- Con START_OFFSET_DOWN=30 y turtle en Y=60 (superficie), la capa 0 queda en Y=30.
Config.START_OFFSET_DOWN = 30

-- Número máximo de capas a minar (nil = sin límite, para en bedrock).
-- Con START_OFFSET_DOWN=30 y MAX_LAYERS=80, mina de Y=30 hasta Y=-50
-- (si la turtle arranca en Y=60).
Config.MAX_LAYERS = 80

-- Dimensiones del área a minar por capa (16×16 = un chunk completo).
Config.QUARRY_WIDTH  = 16   -- número de filas  (dirección Z)
Config.QUARRY_LENGTH = 16   -- bloques por fila  (dirección X)

-- Altura que baja entre capas (normalmente 1).
Config.LAYER_HEIGHT = 1

-- Si true, regresa al cofre y descarga después de cada capa completa.
-- false = solo regresa al llenarse el inventario o quedarse sin fuel.
Config.RETURN_AFTER_EACH_LAYER = false

-- Si true, termina el quarry al detectar bedrock debajo de la capa actual.
Config.STOP_ON_BEDROCK = true

-- ============================================================
-- INVENTARIO Y FILTRO DE BASURA
-- ============================================================
Config.INVENTORY_RESERVE = 2        -- slots reservados para combustible
Config.CHEST_DIRECTION   = "back"   -- "back" | "left" | "right" | "front"

-- Bloques que se descartan durante la minería (se tiran arriba con dropUp).
-- Los ores (cualquier nombre con "_ore"), ancient_debris y combustibles
-- NUNCA se descartan, independientemente de esta lista.
Config.JUNK_BLOCKS = {
    "minecraft:cobblestone",
    "minecraft:cobbled_deepslate",
    "minecraft:stone",
    "minecraft:deepslate",
    "minecraft:dirt",
    "minecraft:gravel",
    "minecraft:diorite",
    "minecraft:andesite",
    "minecraft:granite",
    "minecraft:tuff",
    "minecraft:calcite",
    "minecraft:basalt",
    "minecraft:blackstone",
    "minecraft:netherrack",
    "minecraft:sand",
    "minecraft:sandstone",
    "minecraft:clay",
}

-- ============================================================
-- RED INALÁMBRICA
-- ============================================================
Config.MODEM_SIDE    = "right"  -- lado donde está el modem (top/bottom/left/right/front/back)
Config.NETWORK_ID    = 100      -- canal/protocolo para identificar este quarry
-- ID de la PC controladora (nil = acepta comandos de cualquier ID)
Config.CONTROLLER_ID = nil

-- ============================================================
-- PERSISTENCIA
-- ============================================================
Config.STATE_SAVE_INTERVAL = 10     -- guardar cada N movimientos
Config.STATE_FILE          = "data/state/miner.json"

-- ============================================================
-- LOGGING
-- ============================================================
Config.LOG_LEVEL = "INFO"
Config.LOG_FILE  = "data/logs/miner.log"

return Config
