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
Config.START_OFFSET_DOWN = 5

-- Dimensiones del área a minar por capa (16×16 = un chunk completo).
Config.QUARRY_WIDTH  = 16   -- número de filas  (dirección Z)
Config.QUARRY_LENGTH = 16   -- bloques por fila  (dirección X)

-- Altura que baja entre capas (normalmente 1).
Config.LAYER_HEIGHT = 1

-- Si true, regresa al cofre y descarga después de cada capa completa.
Config.RETURN_AFTER_EACH_LAYER = true

-- Si true, termina el quarry al detectar bedrock debajo de la capa actual.
Config.STOP_ON_BEDROCK = true

-- ============================================================
-- INVENTARIO
-- ============================================================
Config.INVENTORY_RESERVE = 2        -- slots reservados para combustible
Config.CHEST_DIRECTION   = "back"   -- "back" | "left" | "right" | "front"

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
