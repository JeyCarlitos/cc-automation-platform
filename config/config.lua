-- config/config.lua
-- Configuración central de CCAP Miner v1.

local Config = {}

-- ============================================================
-- COMBUSTIBLE
-- ============================================================
Config.FUEL_MINIMUM       = 100
Config.FUEL_SAFETY_MARGIN = 50

-- ============================================================
-- QUARRY (modo actual de minería)
-- ============================================================

-- Profundidad del pozo vertical antes de empezar a minar capas.
-- 40 bloques es la profundidad típica para comenzar la minería de capas.
Config.SHAFT_DEPTH    = 40

-- Dimensiones del área a minar por capa (16x16 = un chunk completo).
Config.QUARRY_WIDTH   = 16   -- filas (dirección Z)
Config.QUARRY_LENGTH  = 16   -- bloques por fila (dirección X)

-- ============================================================
-- INVENTARIO
-- ============================================================
Config.INVENTORY_RESERVE = 2
Config.CHEST_DIRECTION   = "back"

-- ============================================================
-- PERSISTENCIA
-- ============================================================
Config.STATE_SAVE_INTERVAL = 10
Config.STATE_FILE          = "data/state/miner.json"

-- ============================================================
-- LOGGING
-- ============================================================
Config.LOG_LEVEL = "INFO"
Config.LOG_FILE  = "data/logs/miner.log"

return Config
