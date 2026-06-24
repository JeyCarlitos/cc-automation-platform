-- core/nav.lua
-- Navegación inteligente 2D en superficie (plano XZ).
--
-- PROBLEMA que resuelve:
--   El navXZ reactivo (dig+retry) se queda pegado en esquinas y paredes
--   porque no tiene ningún modelo del entorno — solo reacciona al choque.
--
-- SOLUCIÓN — BFS con memoria de obstáculos:
--   1. Antes de moverse, calcular la ruta óptima con BFS (búsqueda en anchura).
--      BFS garantiza la ruta más corta y nunca entra en bucle.
--   2. Seguir la ruta paso a paso. Si un paso falla (obstáculo nuevo),
--      añadir ese bloque al mapa y REPLANIFICAR inmediatamente.
--   3. Distinción entre obstáculos PERMANENTES (paredes, bedrock — se
--      memorizan toda la sesión) y TEMPORALES (mobs, otras turtles —
--      se olvidan al terminar la llamada navXZ para no bloquear rutas futuras).
--   4. Si tras MAX_REPLANS el objetivo sigue sin alcanzarse, retornar false
--      en lugar de bucle infinito. El llamador decide qué hacer.
--
-- Uso:
--   local Nav = require("core.nav")
--   Nav.navXZ(10, 5)        -- true si llegó, false si no pudo
--   Nav.goHome()            -- navega a (0,0)
--   Nav.clearObstacles()    -- resetea la memoria de obstáculos permanentes

local Logger   = require("core.logger")
local Movement = require("core.movement")

local Nav = {}

-- ============================================================
-- Constantes y tablas de dirección
-- ============================================================

-- Máximo de ciclos dig+forward por intento de paso
local MAX_DIG_TRIES = 3

-- Máximo de replanificaciones por llamada a navXZ
local MAX_REPLANS = 20

-- Límite de nodos explorados en BFS (seguridad ante grids enormes)
local BFS_NODE_LIMIT = 4000

-- Bloques irrompibles: nunca intentar cavar
local UNBREAKABLE = {
    ["minecraft:bedrock"]                 = true,
    ["minecraft:barrier"]                 = true,
    ["minecraft:command_block"]           = true,
    ["minecraft:chain_command_block"]     = true,
    ["minecraft:repeating_command_block"] = true,
    ["minecraft:end_portal_frame"]        = true,
    ["minecraft:reinforced_deepslate"]    = true,
}

-- Orden de exploración de BFS: prioriza cardinalidad para paths naturales
local EXPLORE = {
    { dx =  0, dz = -1, dir = "north" },
    { dx =  1, dz =  0, dir = "east"  },
    { dx =  0, dz =  1, dir = "south" },
    { dx = -1, dz =  0, dir = "west"  },
}

-- Deltas de dirección (para calcular coordenada del bloque frontal)
local DIR_DELTA = {
    north = { dx =  0, dz = -1 },
    south = { dx =  0, dz =  1 },
    east  = { dx =  1, dz =  0 },
    west  = { dx = -1, dz =  0 },
}

-- ============================================================
-- Memoria de obstáculos
-- ============================================================

-- Obstáculos permanentes: paredes, bedrock, bloques que no ceden.
-- Persisten durante toda la sesión de farming.
local permObstacles = {}

-- Clave de posición (string para usarla como índice de tabla hash)
local function pk(x, z)  return x .. "," .. z  end

-- ============================================================
-- BFS
-- ============================================================

-- Busca el camino más corto de (sx,sz) a (tx,tz) evitando obstáculos.
-- isBlocked(key) → bool: función que decide si una celda está bloqueada.
-- Retorna:
--   array de { x, z, dir }  → pasos para llegar al objetivo
--   {}                       → ya estamos en el objetivo
--   nil                      → sin ruta posible
local function bfs(sx, sz, tx, tz, isBlocked)
    if sx == tx and sz == tz then return {} end

    -- Cola manual (head pointer para evitar table.remove O(n))
    local queue = { { x = sx, z = sz } }
    local head  = 1

    -- parent[key] = { px, pz, dir } — cómo llegamos a esta celda
    local parent = {}
    local visited = { [pk(sx, sz)] = true }

    while head <= #queue do
        if head > BFS_NODE_LIMIT then
            Logger.warn("[Nav] BFS: límite de nodos alcanzado")
            break
        end

        local cur = queue[head]
        head = head + 1

        -- Comprobar si llegamos
        if cur.x == tx and cur.z == tz then
            -- Reconstruir ruta
            local path = {}
            local c = cur
            while c.x ~= sx or c.z ~= sz do
                local k = pk(c.x, c.z)
                local p = parent[k]
                table.insert(path, 1, { x = c.x, z = c.z, dir = p.dir })
                c = { x = p.px, z = p.pz }
            end
            return path
        end

        -- Expandir vecinos
        for _, d in ipairs(EXPLORE) do
            local nx = cur.x + d.dx
            local nz = cur.z + d.dz
            local nk = pk(nx, nz)
            if not visited[nk] and not isBlocked(nk) then
                visited[nk] = true
                parent[nk]  = { px = cur.x, pz = cur.z, dir = d.dir }
                queue[#queue + 1] = { x = nx, z = nz }
            end
        end
    end

    return nil  -- sin ruta
end

-- ============================================================
-- Intento de movimiento individual
-- ============================================================

-- Retorna:
--   "moved"          → la turtle avanzó un bloque
--   "obstacle_perm"  → bloque irrompible o que no cedió (pared real)
--   "obstacle_temp"  → entidad, mob u obstáculo transitorio
local function tryStep(dir)
    Movement.faceDir(dir)

    for attempt = 1, MAX_DIG_TRIES do
        if Movement.forward() then return "moved" end

        local hasBlock, data = turtle.inspect()
        if hasBlock then
            if UNBREAKABLE[data.name] then
                return "obstacle_perm"
            end
            -- Intentar excavar (puede ser tierra, hojas, cultivo, etc.)
            turtle.dig()
            sleep(0.25)
        else
            -- Sin bloque visible → entidad bloqueando (mob, otra turtle)
            sleep(0.4)
            -- En el último intento sin bloque = obstáculo temporal
            if attempt == MAX_DIG_TRIES then
                return "obstacle_temp"
            end
        end
    end

    -- Agotamos intentos con bloque → pared que no cedió
    return "obstacle_perm"
end

-- ============================================================
-- API pública
-- ============================================================

-- Limpia la memoria de obstáculos permanentes.
-- Llamar al inicio de cada sesión de farming para no cargar rutas
-- de sesiones anteriores donde el mundo era diferente.
function Nav.clearObstacles()
    permObstacles = {}
    Logger.debug("[Nav] Mapa de obstáculos reseteado")
end

-- Navega de la posición actual a (targetX, targetZ) en el plano XZ.
-- No modifica Y. Siempre planifica la ruta completa antes de moverse.
--
-- Garantías:
--   - Nunca entra en bucle infinito.
--   - Si hay una ruta libre, la encuentra y la sigue.
--   - Si la ruta está bloqueada, replanefica automáticamente.
--   - Los obstáculos permanentes se recuerdan para futuras llamadas.
--   - Los obstáculos temporales (mobs) se olvidan al terminar.
--
-- Retorna true si llegó al destino, false si no pudo alcanzarlo.
function Nav.navXZ(targetX, targetZ)
    -- Obstáculos temporales: solo para esta llamada
    local tempObstacles = {}

    local function isBlocked(key)
        return permObstacles[key] or tempObstacles[key]
    end

    local replans = 0

    while true do
        local p = Movement.getPos()
        if p.x == targetX and p.z == targetZ then return true end

        -- Planificar ruta
        local path = bfs(p.x, p.z, targetX, targetZ, isBlocked)

        if path == nil then
            -- Sin ruta posible con los obstáculos conocidos
            Logger.warn(string.format(
                "[Nav] Sin ruta a (%d,%d) — destino bloqueado o inaccesible",
                targetX, targetZ
            ))
            return false
        end

        -- Seguir la ruta paso a paso
        local needReplan = false

        for _, step in ipairs(path) do
            local cur = Movement.getPos()
            if cur.x == targetX and cur.z == targetZ then
                needReplan = false
                break
            end

            local result = tryStep(step.dir)

            if result ~= "moved" then
                -- Calcular coordenada del bloque que bloqueó el paso
                local delta = DIR_DELTA[step.dir]
                local bx    = cur.x + delta.dx
                local bz    = cur.z + delta.dz
                local bk    = pk(bx, bz)

                if result == "obstacle_perm" then
                    permObstacles[bk] = true
                    Logger.debug(string.format(
                        "[Nav] Pared en (%d,%d) — añadida al mapa permanente", bx, bz
                    ))
                else
                    tempObstacles[bk] = true
                    Logger.debug(string.format(
                        "[Nav] Obstáculo temporal en (%d,%d) (mob?)", bx, bz
                    ))
                end

                replans = replans + 1
                if replans >= MAX_REPLANS then
                    Logger.error(string.format(
                        "[Nav] %d replanificaciones — abandono (%d,%d)",
                        replans, targetX, targetZ
                    ))
                    return false
                end

                needReplan = true
                break  -- volver a planificar con el nuevo obstáculo en el mapa
            end

            sleep(0)  -- yield al scheduler de CC:Tweaked
        end

        -- Si terminamos de seguir la ruta sin interrupción, verificar llegada
        if not needReplan then
            local p2 = Movement.getPos()
            if p2.x == targetX and p2.z == targetZ then
                return true
            end
            -- La ruta se siguió completa pero no llegamos (raro; forzar replán)
            replans = replans + 1
            if replans >= MAX_REPLANS then return false end
        end
    end
end

-- Navega a HOME (0,0) en XZ.
function Nav.goHome()
    return Nav.navXZ(0, 0)
end

return Nav
