-- turtles/farmer/farmer.lua
-- Orquestador principal de la Farming Turtle v1.
--
-- COMANDOS (ejecutar desde shell de CC:Tweaked):
--   farmer scan        → Escanea el área buscando farmland y guarda el mapa
--   farmer run         → Ciclo infinito de farmeo (carga mapa, pregunta R/N si hay estado)
--   farmer rescan      → Borra mapa y estado, luego escanea de nuevo
--   farmer clear-map   → Solo borra el mapa guardado
--   farmer status      → Muestra resumen sin mover la turtle
--
-- ALTURAS:
--   HOME (y=0)    → Posición de inicio junto al cofre.
--                   inspectDown() ve el farmland al nivel del suelo.
--   FARM  (y=+1) → Un bloque arriba de HOME.
--                   inspectDown() ve los cultivos encima del farmland.
--   El scanner trabaja en y=0; el ciclo de farmeo trabaja en y=+1.
--
-- DIRECCIÓN DEL COFRE:
--   Configurada en Config.CHEST_DIRECTION ("back" | "front" | "left" | "right").
--   "back" significa que el cofre está AL SUR del HOME (turtle arranca mirando north).

-- ============================================================
-- Setup inicial: override de log file ANTES de cargar otros módulos
-- ============================================================
local Config = require("config.config")
Config.LOG_FILE = Config.FARMER_LOG_FILE or "data/logs/farmer.log"

local Logger      = require("core.logger")
local Movement    = require("core.movement")
local Fuel        = require("core.fuel")
local Inventory   = require("core.inventory")
local FarmScanner = require("turtles.farmer.farmScanner")
local FarmMap     = require("turtles.farmer.farmMap")
local FarmRoute   = require("turtles.farmer.farmRoute")
local FarmerState = require("turtles.farmer.farmerState")
local Crop        = require("turtles.farmer.crop")

-- ============================================================
-- Constantes
-- ============================================================

local FARM_HEIGHT = 1  -- y relativo a HOME para el ciclo de farmeo

-- Mapeo de Config.CHEST_DIRECTION a dirección de movimiento
local CHEST_DIR_FACE = {
    back  = "south",
    front = "north",
    left  = "west",
    right = "east",
}

-- ============================================================
-- Estado de sesión
-- ============================================================

local session = {
    phase            = "IDLE",
    currentPlotIndex = 1,
    cycle            = 0,
    returningReason  = nil,
}

-- ============================================================
-- Helpers de inventario
-- ============================================================

-- Selecciona el primer slot que contenga el ítem indicado.
-- Retorna el slot o nil si no está.
local function selectItem(name)
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and d.name == name then
            turtle.select(slot)
            return slot
        end
    end
    return nil
end

-- Cuenta cuántos items de este nombre hay en total en el inventario.
local function countItem(name)
    local total = 0
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and d.name == name then
            total = total + turtle.getItemCount(slot)
        end
    end
    return total
end

-- ¿El ítem en este slot es combustible?
local function isItemFuel(slot)
    turtle.select(slot)
    local result = turtle.refuel(0)
    turtle.select(1)
    return result
end

-- Set de ítems que la turtle NUNCA deposita (semillas + bonemeal).
-- Se construye una vez de forma lazy.
local _protected = nil
local function buildProtected()
    if _protected then return end
    _protected = { ["minecraft:bone_meal"] = true }
    local seeds = Crop.allSeeds()
    for name, _ in pairs(seeds) do
        _protected[name] = true
    end
end

local function isProtected(name)
    buildProtected()
    return _protected[name] == true
end

-- ============================================================
-- Helpers de cofre
-- ============================================================

-- Orienta la turtle hacia el cofre.
local function faceChest()
    local face = CHEST_DIR_FACE[Config.CHEST_DIRECTION] or "south"
    Movement.faceDir(face)
end

-- Deposita todos los ítems que no sean semillas, bonemeal ni combustible.
local function depositCrops()
    faceChest()
    local count = 0
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and not isProtected(d.name) and not isItemFuel(slot) then
            turtle.select(slot)
            if turtle.drop() then
                count = count + 1
            else
                Logger.warn("[Farmer] No se pudo depositar slot " .. slot .. " (cofre lleno?)")
            end
        end
    end
    turtle.select(1)
    Logger.info(string.format("[Farmer] Depositados %d stacks al cofre", count))
end

-- Intenta tomar bonemeal del cofre hasta llegar a BONEMEAL_TARGET_AMOUNT.
-- Estrategia: suck + verificar qué se tomó + devolver lo que no sirve.
local function replenishBonemeal()
    if not Config.USE_BONEMEAL then return end

    local have = countItem("minecraft:bone_meal")
    local need = Config.BONEMEAL_TARGET_AMOUNT - have
    if need <= 0 then return end

    faceChest()
    Logger.info(string.format(
        "[Farmer] Replenishing bonemeal: tengo %d, objetivo %d",
        have, Config.BONEMEAL_TARGET_AMOUNT
    ))

    for _ = 1, 20 do
        if countItem("minecraft:bone_meal") >= Config.BONEMEAL_TARGET_AMOUNT then break end

        -- Buscar un slot libre
        local freeSlot = nil
        for slot = 1, 16 do
            if turtle.getItemCount(slot) == 0 then
                freeSlot = slot
                break
            end
        end
        if not freeSlot then break end

        turtle.select(freeSlot)
        if not turtle.suck(need) then break end  -- cofre vacío o bloqueado

        -- Verificar lo recibido; devolver lo que no sea bonemeal
        local d = turtle.getItemDetail(freeSlot)
        if d and d.name ~= "minecraft:bone_meal" then
            turtle.select(freeSlot)
            turtle.drop()
        end

        sleep(0.05)
    end

    Logger.info(string.format(
        "[Farmer] Bonemeal en inventario: %d", countItem("minecraft:bone_meal")
    ))
end

-- Intenta tomar semillas del cofre para las semillas que están por debajo del mínimo.
-- Solo toma si el inventario tiene espacio libre.
local function replenishSeeds()
    local minSeedCount = 8  -- umbral mínimo por tipo de semilla
    faceChest()
    local seeds = Crop.allSeeds()
    for seedName, _ in pairs(seeds) do
        local have = countItem(seedName)
        if have < minSeedCount and Inventory.freeSlots() > 2 then
            local freeSlot = nil
            for slot = 1, 16 do
                if turtle.getItemCount(slot) == 0 then
                    freeSlot = slot
                    break
                end
            end
            if freeSlot then
                turtle.select(freeSlot)
                turtle.suck(minSeedCount - have)
                -- Si lo que se tomó no es la semilla esperada, devolver
                local d = turtle.getItemDetail(freeSlot)
                if d and d.name ~= seedName then
                    turtle.select(freeSlot)
                    turtle.drop()
                end
            end
        end
    end
    turtle.select(1)
end

-- ============================================================
-- Helpers de farmeo
-- ============================================================

-- Planta una semilla en la celda actual (turtle a FARM_HEIGHT, farmland abajo).
-- cropName: nombre del cultivo cosechado (para replantar el mismo tipo).
--           Si es nil, intenta cualquier semilla disponible.
-- Retorna true si se plantó con éxito.
local function plantSeed(cropName)
    local seedName = cropName and Crop.getSeed(cropName) or nil

    -- Si no tenemos la semilla específica, buscar cualquier otra
    if not seedName or countItem(seedName) == 0 then
        for name, _ in pairs(Crop.CROPS) do
            local s = Crop.getSeed(name)
            if s and countItem(s) > 0 then
                seedName = s
                break
            end
        end
    end

    if not seedName then
        Logger.warn("[Farmer] Sin semillas disponibles para plantar")
        return false
    end

    if not selectItem(seedName) then
        return false
    end

    local ok = turtle.placeDown()
    turtle.select(1)
    return ok
end

-- Aplica bonemeal al cultivo inmaduro debajo de la turtle.
-- Retorna true si el cultivo maduró tras los intentos.
local function applyBonemeal()
    if not selectItem("minecraft:bone_meal") then return false end

    for _ = 1, Config.BONEMEAL_MAX_ATTEMPTS do
        turtle.placeDown()  -- aplica bonemeal al cultivo en y-1
        sleep(0.1)
        local hasCrop, data = turtle.inspectDown()
        if hasCrop and Crop.isMature(data) then
            turtle.select(1)
            return true
        end
    end

    turtle.select(1)
    return false
end

-- Trabaja el plot actual: la turtle está en (x, FARM_HEIGHT, z).
-- inspectDown() devuelve el cultivo (o aire) al nivel y=0.
local function workPlot(px, pz)
    local hasCrop, data = turtle.inspectDown()

    if not hasCrop then
        -- Farmland vacío: plantar
        plantSeed(nil)
        return
    end

    if not Crop.isCrop(data.name) then
        -- Bloque desconocido encima del farmland (bloque decorativo, etc.)
        Logger.debug(string.format(
            "[Farmer] Plot (%d,%d): bloque no cultivo: %s", px, pz, data.name
        ))
        return
    end

    if Crop.isMature(data) then
        -- Cosechar y replantar
        local cropName = data.name
        turtle.digDown()    -- cosecha; drops se recogen automáticamente
        plantSeed(cropName)
        return
    end

    -- Inmaduro: intentar bonemeal si está habilitado
    if Config.USE_BONEMEAL and countItem("minecraft:bone_meal") > 0 then
        local matured = applyBonemeal()
        if matured then
            local _, mData = turtle.inspectDown()
            local cropName = mData and mData.name
            turtle.digDown()
            plantSeed(cropName)
        end
        -- Si no maduró: dejar y pasar al siguiente plot
    end
    -- Sin bonemeal o no habilitado: skip
end

-- ============================================================
-- Navegación
-- ============================================================

-- Navega en el plano XZ al objetivo, excavando obstáculos si es necesario.
-- No cambia Y.
local function navXZ(targetX, targetZ)
    while Movement.getPos().x ~= targetX do
        local d = Movement.getPos().x < targetX and "east" or "west"
        Movement.faceDir(d)
        if not Movement.forward() then
            turtle.dig()
            sleep(0.2)
            Movement.forward()
        end
        sleep(0)
    end
    while Movement.getPos().z ~= targetZ do
        local d = Movement.getPos().z < targetZ and "south" or "north"
        Movement.faceDir(d)
        if not Movement.forward() then
            turtle.dig()
            sleep(0.2)
            Movement.forward()
        end
        sleep(0)
    end
end

-- Sube de y=0 a y=FARM_HEIGHT (excava si hay bloque encima).
local function goToFarmHeight()
    while Movement.getPos().y < FARM_HEIGHT do
        if not Movement.up() then
            turtle.digUp()
            sleep(0.2)
            Movement.up()
        end
    end
end

-- Baja de y=FARM_HEIGHT a y=0 (excava si hay bloque debajo).
-- Nota: al bajar encima de cultivos se excavan con digDown; eso es intencional
-- ya que la turtle solo baja de vuelta a HOME (0,0) donde no hay cultivos.
local function goToHomeHeight()
    while Movement.getPos().y > 0 do
        if not Movement.down() then
            turtle.digDown()
            sleep(0.2)
            Movement.down()
        end
    end
end

-- Regresa a HOME (0,0) navegando XZ primero y luego bajando a y=0.
local function returnToHome()
    navXZ(0, 0)
    goToHomeHeight()
    Movement.faceDir("north")
end

-- ============================================================
-- Persistencia de sesión
-- ============================================================

local function saveState()
    session.phase = session.phase or "FARMING"
    FarmerState.save(session)
end

-- ============================================================
-- Comando: SCAN
-- ============================================================

local function cmdScan()
    Logger.info("[Farmer] Iniciando escaneo de farmland...")
    print("[Farmer] Escaneando area (radio " .. Config.FARM_SCAN_RADIUS .. ")...")

    -- Asegurar fuel suficiente para el scan completo
    local scanCost = (2 * Config.FARM_SCAN_RADIUS + 1)^2 + Config.FARM_SCAN_RADIUS * 4
    if not Fuel.ensureFuel(scanCost) then
        print("[Farmer] ERROR: Fuel insuficiente para el escaneo.")
        return
    end

    local plots = FarmScanner.scan(Config.FARM_SCAN_RADIUS)

    if #plots == 0 then
        print("[Farmer] No se encontro farmland en el radio " .. Config.FARM_SCAN_RADIUS .. ".")
        print("  Asegurate de que la turtle esta junto al farm y que el farmland")
        print("  esta al nivel del suelo (directamente debajo del HOME).")
        return
    end

    FarmMap.save(plots)

    print(string.format("[Farmer] Scan completo. %d plots de farmland guardados.", #plots))
    Logger.info(string.format("[Farmer] Scan completo: %d plots", #plots))
end

-- ============================================================
-- Comando: RUN (ciclo de farmeo)
-- ============================================================

local function cmdRun()
    -- ── Cargar o verificar mapa ──────────────────────────────────────────
    local mapData = FarmMap.load()

    if not mapData or #mapData.plots == 0 then
        if Config.AUTO_SCAN_IF_NO_MAP then
            print("[Farmer] No hay mapa. Ejecutando scan automatico...")
            Logger.info("[Farmer] Sin mapa — ejecutando scan automático")
            cmdScan()
            mapData = FarmMap.load()
            if not mapData or #mapData.plots == 0 then
                print("[Farmer] El scan no encontro farmland. Abortando.")
                return
            end
        else
            print("[Farmer] ERROR: No hay mapa. Ejecuta primero: farmer scan")
            return
        end
    end

    local route = FarmRoute.build(mapData.plots)
    Logger.info(string.format("[Farmer] Ruta construida: %d plots", #route))

    -- ── Gestión de estado guardado ───────────────────────────────────────
    local saved = FarmerState.load()
    if saved then
        term.clear()
        term.setCursorPos(1, 1)
        if term.setTextColor then term.setTextColor(colors.yellow) end
        print("=== Farmer Turtle ===")
        print("")
        if term.setTextColor then term.setTextColor(colors.white) end
        print("Estado guardado encontrado:")
        print("  Fase:  " .. tostring(saved.phase))
        print("  Ciclo: " .. tostring(saved.cycle))
        print("  Plot:  " .. tostring(saved.currentPlotIndex) .. "/" .. #route)
        print("  Pos:   x=" .. saved.x .. " y=" .. saved.y .. " z=" .. saved.z)
        print("")
        print("Coloca la turtle en esa posicion antes de reanudar.")
        print("")
        if term.setTextColor then term.setTextColor(colors.green) end
        print("R = Reanudar sesion guardada")
        if term.setTextColor then term.setTextColor(colors.red) end
        print("N = Nueva sesion (borra estado)")
        if term.setTextColor then term.setTextColor(colors.white) end
        print("")
        write("Elige [R/N]: ")

        local choice = read()
        if choice and choice:lower() == "n" then
            FarmerState.clear()
            saved = nil
            print("Estado borrado. Iniciando sesion nueva.")
            sleep(0.8)
        else
            -- Restaurar posición en el tracker de movimiento
            Movement.setState(
                { x = saved.x, y = saved.y, z = saved.z },
                saved.dir
            )
            session.phase            = saved.phase
            session.currentPlotIndex = saved.currentPlotIndex
            session.cycle            = saved.cycle
            session.returningReason  = saved.returningReason
            Logger.info(string.format(
                "[Farmer] Reanudando: fase=%s ciclo=%d plot=%d",
                session.phase, session.cycle, session.currentPlotIndex
            ))
        end
    end

    if not saved then
        -- Sesión nueva
        Movement.resetState()
        session.phase            = "FARMING"
        session.currentPlotIndex = 1
        session.cycle            = 0
        session.returningReason  = nil
    end

    -- ── Bucle principal ──────────────────────────────────────────────────
    print(string.format("[Farmer] Iniciando farmeo: %d plots, ciclo %d",
        #route, session.cycle))
    Logger.info(string.format("[Farmer] Run iniciado. Plots: %d", #route))

    local phase = session.phase  -- variable local para la máquina de estados

    while true do

        -- ── FARMING ─────────────────────────────────────────────────────
        if phase == "FARMING" then
            goToFarmHeight()
            session.phase = "FARMING"

            while session.currentPlotIndex <= #route do
                local idx  = session.currentPlotIndex
                local plot = route[idx]

                -- Verificar fuel para llegar al plot + regresar a HOME
                local distToPlot = math.abs(plot.x - Movement.getPos().x)
                                 + math.abs(plot.z - Movement.getPos().z)
                if not Fuel.ensureFuel(distToPlot + 10) then
                    Logger.warn("[Farmer] Fuel bajo — regresando a HOME")
                    session.returningReason = "FUEL"
                    saveState()
                    phase = "RETURNING"
                    break
                end

                -- Navegar al plot
                navXZ(plot.x, plot.z)

                -- Trabajar el plot
                workPlot(plot.x, plot.z)

                -- Verificar inventario
                if Inventory.isFull() then
                    Logger.info("[Farmer] Inventario lleno — regresando a HOME")
                    session.currentPlotIndex = idx + 1
                    session.returningReason  = "INVENTORY"
                    saveState()
                    phase = "RETURNING"
                    break
                end

                -- Avanzar índice y guardar estado periódicamente
                session.currentPlotIndex = idx + 1
                if idx % Config.FARMER_STATE_SAVE_INTERVAL == 0 then
                    saveState()
                end

                sleep(0)  -- yield
            end

            -- Si terminamos todos los plots sin interrupción
            if phase == "FARMING" then
                session.cycle            = session.cycle + 1
                session.currentPlotIndex = 1
                session.returningReason  = "CYCLE_COMPLETE"
                Logger.info(string.format(
                    "[Farmer] Ciclo %d completo.", session.cycle
                ))
                phase = "RETURNING"
            end

        -- ── RETURNING ───────────────────────────────────────────────────
        elseif phase == "RETURNING" then
            session.phase = "RETURNING"
            returnToHome()
            phase = "UNLOADING"

        -- ── UNLOADING ───────────────────────────────────────────────────
        elseif phase == "UNLOADING" then
            session.phase = "UNLOADING"

            depositCrops()
            replenishBonemeal()
            replenishSeeds()
            Fuel.refuelFromInventory()

            Logger.info(string.format(
                "[Farmer] HOME: fuel=%d bonemeal=%d",
                Fuel.getLevel(), countItem("minecraft:bone_meal")
            ))

            if session.returningReason == "CYCLE_COMPLETE" then
                phase = "WAITING"
            else
                -- Interrupción por fuel o inventario: reanudar farmeo
                session.returningReason = nil
                saveState()
                phase = "FARMING"
            end

        -- ── WAITING ─────────────────────────────────────────────────────
        elseif phase == "WAITING" then
            session.phase = "WAITING"
            saveState()

            print(string.format(
                "[Farmer] Ciclo %d listo. Esperando %ds...",
                session.cycle, Config.FARM_LOOP_DELAY
            ))
            Logger.info(string.format(
                "[Farmer] Esperando %ds entre ciclos", Config.FARM_LOOP_DELAY
            ))

            -- Esperar en bloques de 5s para no bloquear el scheduler
            local waited = 0
            while waited < Config.FARM_LOOP_DELAY do
                sleep(5)
                waited = waited + 5
            end

            session.returningReason = nil
            phase = "FARMING"
        end

    end  -- while true
end

-- ============================================================
-- Comando: STATUS
-- ============================================================

local function cmdStatus()
    print("=== Farmer Turtle - Status ===")
    print("")

    -- Mapa
    local mapData = FarmMap.load()
    if mapData then
        print(string.format("Mapa:   %d plots (escaneado dia %d)",
            #mapData.plots, mapData.scannedAt or 0))
    else
        print("Mapa:   No disponible (ejecuta: farmer scan)")
    end

    -- Estado de sesion
    local saved = FarmerState.load()
    if saved then
        local total = mapData and #mapData.plots or "?"
        print(string.format("Fase:   %s", tostring(saved.phase)))
        print(string.format("Ciclo:  %d", saved.cycle))
        print(string.format("Plot:   %d/%s", saved.currentPlotIndex, tostring(total)))
        print(string.format("Pos:    x=%d y=%d z=%d dir=%s",
            saved.x, saved.y, saved.z, saved.dir))
        if saved.returningReason then
            print(string.format("Motivo retorno: %s", saved.returningReason))
        end
    else
        print("Sesion: Sin estado guardado")
    end

    -- Inventario actual
    print("")
    print(string.format("Fuel:   %d", turtle.getFuelLevel()))
    print(string.format("Slots:  %d/16 usados", Inventory.usedSlots()))
    local seeds = Crop.allSeeds()
    for seedName, _ in pairs(seeds) do
        local count = countItem(seedName)
        if count > 0 then
            print(string.format("  %s: %d", seedName:gsub("minecraft:", ""), count))
        end
    end
    local bm = countItem("minecraft:bone_meal")
    if bm > 0 then
        print(string.format("  bone_meal: %d", bm))
    end
end

-- ============================================================
-- Punto de entrada — dispatch por argumento
-- ============================================================

local args = {...}
local cmd  = args[1] or "status"

if cmd == "scan" then
    cmdScan()

elseif cmd == "run" then
    local ok, err = pcall(cmdRun)
    if not ok then
        if term.setTextColor then term.setTextColor(colors.red) end
        print("[Farmer] ERROR FATAL:")
        print(tostring(err))
        if term.setTextColor then term.setTextColor(colors.white) end
        Logger.error("[Farmer] ERROR FATAL: " .. tostring(err))
        print("Revisa " .. (Config.FARMER_LOG_FILE or "data/logs/farmer.log"))
    end

elseif cmd == "rescan" then
    print("[Farmer] Borrando mapa y estado anterior...")
    FarmMap.clear()
    FarmerState.clear()
    cmdScan()

elseif cmd == "clear-map" then
    FarmMap.clear()
    FarmerState.clear()
    print("[Farmer] Mapa y estado borrados.")

elseif cmd == "status" then
    cmdStatus()

else
    print("Uso: farmer <comando>")
    print("  scan       Escanea el area buscando farmland")
    print("  run        Inicia el ciclo de farmeo")
    print("  rescan     Borra mapa y vuelve a escanear")
    print("  clear-map  Borra el mapa guardado")
    print("  status     Muestra resumen sin moverse")
end
