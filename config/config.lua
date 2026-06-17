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

-- ── POZO COMPARTIDO ─────────────────────────────────────────────────────────
-- Coordenada del único pozo de descenso compartido entre todas las turtles.
-- Offset relativo a HOME (cofre). Todas las turtles bajan por este mismo
-- pozo y luego caminan horizontalmente a su zona de minería en profundidad.
--
--   SHAFT=(0,0): el pozo está justo en HOME → sin desplazamiento extra.
--   SHAFT=(8,0): el pozo está 8 bloques al este del cofre.
--
-- NOTA: solo una turtle puede usar el pozo a la vez. Escalonar los arranques.
Config.SHAFT_X = 0
Config.SHAFT_Z = 0

-- ── ZONAS POR TURTLE ────────────────────────────────────────────────────────
-- Desplazamiento horizontal desde HOME hasta el origen de la zona de minería
-- de ESTA turtle. Cada turtle tiene valores distintos para no solaparse.
-- La turtle baja por el POZO COMPARTIDO y luego camina a su zona en profundidad.
--
--   Turtle 1 → QUARRY_OFFSET_X = 0,  QUARRY_OFFSET_Z = 0   (mina en X 0..15)
--   Turtle 2 → QUARRY_OFFSET_X = 16, QUARRY_OFFSET_Z = 0   (mina en X 16..31)
--   Turtle 3 → QUARRY_OFFSET_X = 32, QUARRY_OFFSET_Z = 0   (mina en X 32..47)
Config.QUARRY_OFFSET_X = 0
Config.QUARRY_OFFSET_Z = 0

-- Dimensiones del área a minar por capa (16×16 = un chunk completo).
Config.QUARRY_WIDTH  = 16   -- número de filas  (dirección Z)
Config.QUARRY_LENGTH = 16   -- bloques por fila  (dirección X)

-- Altura que baja entre capas.
-- Con 3: cada pasada excava 3 bloques de alto (techo, nivel, suelo) con
-- cobertura completa y 3× menos viajes de descenso. Recomendado con safeDigFloor.
Config.LAYER_HEIGHT = 3

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
