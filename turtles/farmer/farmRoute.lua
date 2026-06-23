-- turtles/farmer/farmRoute.lua
-- Ordena los plots de farmland en recorrido serpentín para minimizar distancia.
--
-- Algoritmo:
--   1. Agrupa plots por fila Z (ascendente).
--   2. Dentro de cada fila, ordena X.
--   3. Alterna la dirección de X entre filas (fila 0 → +X, fila 1 → -X, etc.)
--      para evitar tener que volver al inicio de cada fila.
--
-- Uso:
--   local FarmRoute = require("turtles.farmer.farmRoute")
--   local route = FarmRoute.build(plots)
--   -- route = { {x=int, z=int}, ... } en orden de visita

local FarmRoute = {}

-- Construye y retorna el array de plots en orden serpentín.
-- plots: { {x=int, z=int}, ... }  (puede estar en cualquier orden)
function FarmRoute.build(plots)
    if not plots or #plots == 0 then return {} end

    -- Paso 1: agrupar por Z
    local byZ  = {}
    local zSet = {}
    for _, p in ipairs(plots) do
        local z = p.z
        if not byZ[z] then
            byZ[z]        = {}
            zSet[#zSet+1] = z
        end
        byZ[z][#byZ[z]+1] = { x = p.x, z = p.z }
    end

    -- Paso 2: ordenar filas Z ascendente
    table.sort(zSet)

    -- Paso 3: construir recorrido con serpentín en X
    local route  = {}
    local rowIdx = 0  -- 0-based para calcular paridad

    for _, z in ipairs(zSet) do
        local row = byZ[z]

        -- Ordenar X ascendente
        table.sort(row, function(a, b) return a.x < b.x end)

        -- Filas impares: invertir para ir en dirección -X
        if rowIdx % 2 == 1 then
            local rev = {}
            for i = #row, 1, -1 do rev[#rev+1] = row[i] end
            row = rev
        end

        for _, p in ipairs(row) do
            route[#route+1] = { x = p.x, z = p.z }
        end

        rowIdx = rowIdx + 1
    end

    return route
end

return FarmRoute
