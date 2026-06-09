-- config/config.lua
-- Configuración central de CCAP Miner v1.
-- Todos los parámetros ajustables están aquí.
-- Ningún módulo debe contener números mágicos.

local Config = {}

-- ============================================================
-- COMBUSTIBLE
-- ============================================================

-- Nivel mínimo de fuel para iniciar una operación de minería.
-- Si la turtle tiene menos, intentará refuel primero.
Config.FUEL_MINIMUM = 100

-- Bloques de margen de seguridad sobre el costo estimado de retorno.
-- Ejemplo: si estimamos 60 bloques de retorno, necesitamos 60 + 50 = 110 de fuel libre.
Config.FUEL_SAFETY_MARGIN = 50

-- ============================================================
-- MINERÍA
-- ============================================================

-- Largo del túnel principal en bloques.
Config.TUNNEL_LENGTH = 50

-- Largo de cada rama lateral en bloques (a cada lado del túnel).
Config.BRANCH_LENGTH = 10

-- Cada cuántos bloques del túnel principal se abre una rama.
-- Con 3: rama en bloque 3, 6, 9, 12...
Config.BRANCH_SPACING = 3

-- ============================================================
-- INVENTARIO
-- ============================================================

-- Slots reservados para combustible. El miner no tirará ítems de estos slots.
-- Valor recomendado: 1-2.
Config.INVENTORY_RESERVE = 2

-- Dirección del cofre relativa al origen de la turtle (posición de inicio).
-- Opciones: "back" | "forward" | "left" | "right"
-- Setup recomendado: turtle en frente del cofre mirando hacia el túnel → "back"
Config.CHEST_DIRECTION = "back"

-- ============================================================
-- PERSISTENCIA
-- ============================================================

-- Guardar estado cada N movimientos.
-- Valor más bajo = más seguridad ante crashes, pero más escrituras a disco.
Config.STATE_SAVE_INTERVAL = 10

-- Ruta del archivo de estado persistente.
Config.STATE_FILE = "data/state/miner.json"

-- ============================================================
-- LOGGING
-- ============================================================

-- Nivel mínimo de log a registrar.
-- Opciones: "DEBUG" | "INFO" | "WARN" | "ERROR"
-- En producción usar "INFO". Para depuración usar "DEBUG".
Config.LOG_LEVEL = "INFO"

-- Ruta del archivo de log.
Config.LOG_FILE = "data/logs/miner.log"

return Config
