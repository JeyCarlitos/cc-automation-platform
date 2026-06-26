-- turtles/farmer/farmer.lua
-- Orquestador principal de la Farming Turtle v1.
--
-- COMANDOS (ejecutar desde shell de CC:Tweaked):
--   farmer scan        → Escanea el área buscando farmland y guarda el mapa
--   farmer run         → Ciclo infinito de farmeo controlable por red
--   farmer rescan      → Borra mapa y estado, luego escanea de nuevo
--   farmer clear-map   → Solo borra el mapa guardado
--   farmer status      → Muestra resumen sin mover la turtle
--
-- CONTROL REMOTO (desde pocket computer / commander.lua):
--   STATUS  → Responde con fase, ciclo, plot, fuel y posición
--   FUEL    → Igual que STATUS (commander parsea fuel=N)
--   RETURN  → La turtle termina el plot actual y regresa a HOME
--   REBOOT  → Reinicia la turtle
--   UPDATE  → Regresa a HOME y sale (para actualizar con install/update)
--
-- ALTURAS:
--   HOME (y=0)   → Junto al cofre. inspectDown() ve farmland.
--   FARM (y=+1)  → Un bloque arriba. inspectDown() ve cultivos.
--
-- DIRECCIÓN DEL COFRE:
--   Config.CHEST_DIRECTION ("back" = cofre AL SUR cuando turtle mira north).

-- ============================================================
-- Setup: override de log file ANTES de cargar otros módulos
-- ============================================================
local Config = require("config.config")
Config.LOG_FILE = Config.FARMER_LOG_FILE or "data/logs/farmer.log"

local Logger      = require("core.logger")
local Movement    = require("core.movement")
local Nav         = require("core.nav")
local Fuel        = require("core.fuel")
local Inventory   = require("core.inventory")
local FarmScanner = require("turtles.farmer.farmScanner")
local FarmMap     = require("turtles.farmer.farmMap")
local FarmRoute   = require("turtles.farmer.farmRoute")
local FarmerState = require("turtles.farmer.farmerState")
local Crop        = require("turtles.farmer.crop")

-- ============================================================
-- Modem — auto-detectar igual que commander.lua
-- ============================================================

local MODEM_SIDE = nil
for _, side in ipairs({"back","right","left","top","bottom","front"}) do
    if peripheral.getType(side) == "modem" then
        MODEM_SIDE = side
        break
    end
end

if MODEM_SIDE then
    rednet.open(MODEM_SIDE)
    Logger.info("[Farmer] Modem abierto en " .. MODEM_SIDE)
else
    Logger.info("[Farmer] Sin modem — modo standalone (sin control remoto)")
end

local PROTOCOL = "CCAP"

-- ============================================================
-- Constantes
-- ============================================================

local FARM_HEIGHT = 1  -- y relativo a HOME durante el farmeo

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
    controllerID     = nil,  -- ID del pocket/PC que nos controla
}

-- Flag que el commandListener activa para que farmingMain regrese a HOME
local stopRequested = false

-- ============================================================
-- Helpers de inventario
-- ============================================================

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

local function isItemFuel(slot)
    turtle.select(slot)
    local result = turtle.refuel(0)
    turtle.select(1)
    return result
end

-- Mínimo de cada tipo de semilla que la turtle retiene para replantar.
-- El exceso se deposita. replenishSeeds() recupera más del cofre si bajan de 8.
local MIN_SEED_RESERVE = 16

-- ============================================================
-- Helpers de cofre
-- ============================================================

local function faceChest()
    Movement.faceDir(CHEST_DIR_FACE[Config.CHEST_DIRECTION] or "south")
end

-- Decide si un slot debe depositarse.
-- Reglas:
--   - Fuel               → NO depositar (la turtle lo necesita)
--   - Bone meal          → NO depositar (consumible de farmeo)
--   - Semilla pura       → depositar el EXCESO sobre MIN_SEED_RESERVE
--       (Ej: wheat_seeds: guardar 16, depositar el resto)
--   - Semilla+cosecha    → depositar el EXCESO sobre MIN_SEED_RESERVE
--       (Ej: carrot/potato: guardar 16 para replantar, depositar el resto)
--   - Cosecha normal     → siempre depositar (wheat, beetroot, etc.)
local function shouldDeposit(itemName, slot)
    if isItemFuel(slot) then return false end
    if itemName == "minecraft:bone_meal" then return false end
    local seeds = Crop.allSeeds()
    if seeds[itemName] then
        -- Es semilla (puede ser también cosecha): depositar solo el exceso
        return countItem(itemName) > MIN_SEED_RESERVE
    end
    return true  -- cosecha pura → siempre depositar
end

local function depositCrops()
    faceChest()
    local count = 0
    for slot = 1, 16 do
        local d = turtle.getItemDetail(slot)
        if d and shouldDeposit(d.name, slot) then
            turtle.select(slot)
            if turtle.drop() then count = count + 1
            else Logger.warn("[Farmer] No se pudo depositar slot " .. slot) end
        end
    end
    turtle.select(1)
    Logger.info(string.format("[Farmer] Depositados %d stacks", count))
end

local function replenishBonemeal()
    if not Config.USE_BONEMEAL then return end
    local have = countItem("minecraft:bone_meal")
    local need = Config.BONEMEAL_TARGET_AMOUNT - have
    if need <= 0 then return end
    faceChest()
    for _ = 1, 20 do
        if countItem("minecraft:bone_meal") >= Config.BONEMEAL_TARGET_AMOUNT then break end
        local freeSlot = nil
        for slot = 1, 16 do
            if turtle.getItemCount(slot) == 0 then freeSlot = slot; break end
        end
        if not freeSlot then break end
        turtle.select(freeSlot)
        if not turtle.suck(need) then break end
        local d = turtle.getItemDetail(freeSlot)
        if d and d.name ~= "minecraft:bone_meal" then
            turtle.select(freeSlot); turtle.drop()
        end
        sleep(0.05)
    end
    Logger.info(string.format("[Farmer] Bonemeal: %d", countItem("minecraft:bone_meal")))
end

local function replenishSeeds()
    local minSeedCount = 8
    faceChest()
    for seedName, _ in pairs(Crop.allSeeds()) do
        if countItem(seedName) < minSeedCount and Inventory.freeSlots() > 2 then
            local freeSlot = nil
            for slot = 1, 16 do
                if turtle.getItemCount(slot) == 0 then freeSlot = slot; break end
            end
            if freeSlot then
                turtle.select(freeSlot)
                turtle.suck(minSeedCount - countItem(seedName))
                local d = turtle.getItemDetail(freeSlot)
                if d and d.name ~= seedName then
                    turtle.select(freeSlot); turtle.drop()
                end
            end
        end
    end
    turtle.select(1)
end

-- ============================================================
-- Helpers de farmeo
-- ============================================================

local function plantSeed(cropName)
    local seedName = cropName and Crop.getSeed(cropName) or nil
    if not seedName or countItem(seedName) == 0 then
        for name, _ in pairs(Crop.CROPS) do
            local s = Crop.getSeed(name)
            if s and countItem(s) > 0 then seedName = s; break end
        end
    end
    if not seedName then
        Logger.warn("[Farmer] Sin semillas disponibles")
        return false
    end
    if not selectItem(seedName) then return false end
    local planted = turtle.placeDown()
    turtle.select(1)
    return planted
end

local function applyBonemeal()
    if not selectItem("minecraft:bone_meal") then return false end
    for _ = 1, Config.BONEMEAL_MAX_ATTEMPTS do
        turtle.placeDown()
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

-- Busca una azada en el inventario. Retorna el slot o nil.
-- Preferencia: mejor material primero para no gastar la peor.
local HOE_NAMES = {
    "minecraft:netherite_hoe", "minecraft:diamond_hoe",
    "minecraft:iron_hoe",      "minecraft:golden_hoe",
    "minecraft:stone_hoe",     "minecraft:wooden_hoe",
}
local function findHoe()
    for _, hoeName in ipairs(HOE_NAMES) do
        for slot = 1, 16 do
            local d = turtle.getItemDetail(slot)
            if d and d.name == hoeName then return slot end
        end
    end
    return nil
end

-- Intenta re-arar la celda actual cuando plantSeed() falló.
-- El farmland se dañó y ahora es dirt. Secuencia:
--   1. Bajar a y=0 (encima del dirt — no hay farmland que pisar).
--   2. Usar azada con placeDown() para convertir dirt → farmland.
--   3. Subir a y=1.
--   4. Plantar semilla.
local function reTillAndPlant(px, pz, cropName)
    local hoeSlot = findHoe()
    if not hoeSlot then
        Logger.warn(string.format(
            "[Farmer] Farmland dañado en (%d,%d) — sin azada para reparar", px, pz
        ))
        return
    end

    Logger.info(string.format("[Farmer] Farmland dañado en (%d,%d) — re-arando", px, pz))

    -- Bajar a y=0 (encima del dirt/suelo dañado)
    if not Movement.down() then
        turtle.digDown(); sleep(0.2)
        if not Movement.down() then
            Logger.warn("[Farmer] No se pudo bajar para re-arar")
            return
        end
    end

    -- Usar azada sobre el bloque en y=-1 (dirt)
    turtle.select(hoeSlot)
    local tilled = turtle.placeDown()
    turtle.select(1)

    -- Subir de vuelta a y=1
    if not Movement.up() then
        turtle.digUp(); sleep(0.2)
        Movement.up()
    end

    if tilled then
        Logger.info(string.format("[Farmer] Tierra re-arada en (%d,%d) — plantando", px, pz))
        plantSeed(cropName)
    else
        Logger.warn(string.format("[Farmer] No se pudo arar (%d,%d)", px, pz))
    end
end

local function workPlot(px, pz)
    local hasCrop, data = turtle.inspectDown()

    -- Sin bloque en el nivel del cultivo (y=0) → farmland desnudo o dañado
    if not hasCrop then
        -- Intentar plantar directamente
        if not plantSeed(nil) then
            -- placeDown() falló → farmland posiblemente dañado (es dirt ahora)
            reTillAndPlant(px, pz, nil)
        end
        return
    end

    -- Cultivo conocido → manejar ciclo de crecimiento
    if Crop.isCrop(data.name) then
        if Crop.isMature(data) then
            local cropName = data.name
            turtle.digDown()
            if not plantSeed(cropName) then
                reTillAndPlant(px, pz, cropName)
            end
        elseif Config.USE_BONEMEAL and countItem("minecraft:bone_meal") > 0 then
            local matured = applyBonemeal()
            if matured then
                local _, mData = turtle.inspectDown()
                turtle.digDown()
                local cn = mData and mData.name
                if not plantSeed(cn) then
                    reTillAndPlant(px, pz, cn)
                end
            end
        end
        return
    end

    -- Bloque desconocido en y=0 (piedra, hierba, etc.) — ignorar
    Logger.debug(string.format("[Farmer] Plot (%d,%d): bloque inesperado %s", px, pz, data.name))
end

-- ============================================================
-- Navegación
-- ============================================================

-- Delegar en Nav.navXZ (robusto: reintentos, detección de irrompibles,
-- rodeo perpendicular, tope de intentos antes de descarte).
local function navXZ(targetX, targetZ)
    return Nav.navXZ(targetX, targetZ)
end

local function goToFarmHeight()
    while Movement.getPos().y < FARM_HEIGHT do
        if not Movement.up() then turtle.digUp(); sleep(0.2); Movement.up() end
    end
end

local function goToHomeHeight()
    while Movement.getPos().y > 0 do
        if not Movement.down() then turtle.digDown(); sleep(0.2); Movement.down() end
    end
end

local function returnToHome()
    navXZ(0, 0)
    goToHomeHeight()
    Movement.faceDir("north")
end

-- ============================================================
-- Persistencia
-- ============================================================

local function saveState()
    FarmerState.save(session)
end

-- ============================================================
-- Helpers de red
-- ============================================================

local function label()
    return os.getComputerLabel() or ("ID:" .. os.getComputerID())
end

local function statusMsg()
    local p = Movement.getPos()
    return string.format(
        "[%s] STATUS phase=%s cycle=%d plot=%d fuel=%d x=%d y=%d z=%d",
        label(), session.phase, session.cycle,
        session.currentPlotIndex, Fuel.getLevel(),
        p.x, p.y, p.z
    )
end

-- ============================================================
-- Corrutina: commandListener
-- ============================================================
-- Escucha comandos del pocket computer / controller.
-- Si no hay modem, bloquea dormida (para que parallel.waitForAny
-- no la descarte antes de que farmingMain termine).

local function commandListener()
    if not MODEM_SIDE then
        while true do sleep(9999) end
        return
    end

    -- Anunciarse al controlador
    rednet.broadcast(string.format(
        "[%s] HELLO type=farmer fuel=%d",
        label(), Fuel.getLevel()
    ), PROTOCOL)

    while true do
        local senderId, msg = rednet.receive(PROTOCOL, 1)
        if senderId and msg then
            session.controllerID = senderId  -- guardar quién nos habla

            if msg == "STATUS" or msg == "FUEL" then
                rednet.send(senderId, statusMsg(), PROTOCOL)

            elseif msg == "RETURN" then
                Logger.info("[Farmer] Comando RETURN del controlador " .. senderId)
                stopRequested = true
                rednet.send(senderId, string.format("[%s] ACK RETURN", label()), PROTOCOL)

            elseif msg == "UPDATE" then
                Logger.info("[Farmer] Comando UPDATE — regresando a HOME")
                stopRequested = true
                rednet.send(senderId, string.format("[%s] ACK UPDATE", label()), PROTOCOL)

            elseif msg == "REBOOT" then
                Logger.info("[Farmer] Comando REBOOT del controlador " .. senderId)
                rednet.send(senderId, string.format("[%s] ACK REBOOT", label()), PROTOCOL)
                sleep(0.5)
                os.reboot()

            elseif msg == "DEPOSIT" then
                -- Solicitud de descarga inmediata: marcamos para volver
                stopRequested = true
                rednet.send(senderId, string.format("[%s] ACK DEPOSIT", label()), PROTOCOL)
            end
        end
        sleep(0)
    end
end

-- ============================================================
-- Corrutina: heartbeatLoop
-- ============================================================

local function heartbeatLoop()
    if not MODEM_SIDE then
        while true do sleep(9999) end
        return
    end
    while true do
        sleep(60)
        if session.controllerID then
            rednet.send(session.controllerID, statusMsg(), PROTOCOL)
            Logger.debug("[Farmer] Heartbeat enviado")
        end
    end
end

-- ============================================================
-- Corrutina: farmingMain
-- ============================================================
-- Máquina de estados del ciclo de farmeo.
-- Retorna cuando stopRequested == true (tras volver a HOME).

local function farmingMain(route)
    local phase = session.phase == "IDLE" and "FARMING" or session.phase

    while true do

        if phase == "FARMING" then
            goToFarmHeight()
            session.phase = "FARMING"

            while session.currentPlotIndex <= #route do
                -- Parada solicitada por red
                if stopRequested then
                    session.returningReason = "COMMANDED"
                    saveState()
                    phase = "RETURNING"
                    break
                end

                local idx  = session.currentPlotIndex
                local plot = route[idx]

                -- Fuel check
                local dist = math.abs(plot.x - Movement.getPos().x)
                           + math.abs(plot.z - Movement.getPos().z)
                if not Fuel.ensureFuel(dist + 10) then
                    Logger.warn("[Farmer] Fuel bajo — regresando a HOME")
                    session.returningReason = "FUEL"
                    saveState()
                    phase = "RETURNING"
                    break
                end

                navXZ(plot.x, plot.z)
                workPlot(plot.x, plot.z)

                if Inventory.isFull() then
                    Logger.info("[Farmer] Inventario lleno — regresando a HOME")
                    session.currentPlotIndex = idx + 1
                    session.returningReason  = "INVENTORY"
                    saveState()
                    phase = "RETURNING"
                    break
                end

                session.currentPlotIndex = idx + 1
                if idx % Config.FARMER_STATE_SAVE_INTERVAL == 0 then
                    saveState()
                end
                sleep(0)
            end

            -- Ciclo completo sin interrupción
            if phase == "FARMING" then
                session.cycle            = session.cycle + 1
                session.currentPlotIndex = 1
                session.returningReason  = "CYCLE_COMPLETE"
                Logger.info(string.format("[Farmer] Ciclo %d completo.", session.cycle))
                phase = "RETURNING"
            end

        elseif phase == "RETURNING" then
            session.phase = "RETURNING"
            saveState()
            returnToHome()
            -- Si fue un RETURN/UPDATE comandado, salir limpiamente
            if stopRequested and session.returningReason == "COMMANDED" then
                depositCrops()
                Logger.info("[Farmer] Detenido por comando. Escribe 'farmer run' para reanudar.")
                return
            end
            phase = "UNLOADING"

        elseif phase == "UNLOADING" then
            session.phase = "UNLOADING"
            depositCrops()
            replenishBonemeal()
            replenishSeeds()
            Fuel.refuelFromInventory()

            Logger.info(string.format(
                "[Farmer] HOME — fuel=%d bonemeal=%d",
                Fuel.getLevel(), countItem("minecraft:bone_meal")
            ))

            if session.returningReason == "CYCLE_COMPLETE" then
                phase = "WAITING"
            else
                session.returningReason = nil
                stopRequested = false
                saveState()
                phase = "FARMING"
            end

        elseif phase == "WAITING" then
            session.phase = "WAITING"
            saveState()
            print(string.format(
                "[Farmer] Ciclo %d listo. Esperando %ds...",
                session.cycle, Config.FARM_LOOP_DELAY
            ))
            Logger.info(string.format("[Farmer] Esperando %ds", Config.FARM_LOOP_DELAY))

            local waited = 0
            while waited < Config.FARM_LOOP_DELAY do
                if stopRequested then break end
                sleep(5)
                waited = waited + 5
            end

            if stopRequested then
                session.returningReason = "COMMANDED"
                FarmerState.clear()
                Logger.info("[Farmer] Detenido durante espera.")
                return
            end

            session.returningReason = nil
            phase = "FARMING"
        end
    end
end

-- ============================================================
-- Comando: SCAN
-- ============================================================

local function cmdScan()
    Logger.info("[Farmer] Iniciando escaneo...")
    print("[Farmer] Escaneando (radio " .. Config.FARM_SCAN_RADIUS .. ")...")

    local scanCost = (2 * Config.FARM_SCAN_RADIUS + 1)^2 + Config.FARM_SCAN_RADIUS * 4
    if not Fuel.ensureFuel(scanCost) then
        print("[Farmer] ERROR: Fuel insuficiente para el escaneo.")
        return
    end

    local plots = FarmScanner.scan(Config.FARM_SCAN_RADIUS)
    if #plots == 0 then
        print("[Farmer] No se encontro farmland. Revisa que el farmland este")
        print("  directamente debajo del HOME de la turtle.")
        return
    end

    FarmMap.save(plots)
    print(string.format("[Farmer] Listo. %d plots guardados.", #plots))
end

-- ============================================================
-- Comando: RUN
-- ============================================================

local function cmdRun()
    -- Cargar mapa
    local mapData = FarmMap.load()
    if not mapData or #mapData.plots == 0 then
        if Config.AUTO_SCAN_IF_NO_MAP then
            print("[Farmer] Sin mapa — escaneando automaticamente...")
            cmdScan()
            mapData = FarmMap.load()
            if not mapData or #mapData.plots == 0 then
                print("[Farmer] Sin farmland encontrado. Abortando.")
                return
            end
        else
            print("[Farmer] ERROR: Ejecuta primero: farmer scan")
            return
        end
    end

    local route = FarmRoute.build(mapData.plots)
    Logger.info(string.format("[Farmer] Ruta: %d plots", #route))

    -- Gestión de estado guardado
    local saved = FarmerState.load()
    if saved then
        term.clear(); term.setCursorPos(1,1)
        if term.setTextColor then term.setTextColor(colors.yellow) end
        print("=== Farmer Turtle ==="); print("")
        if term.setTextColor then term.setTextColor(colors.white) end
        print("Estado guardado:")
        print("  Fase:  " .. tostring(saved.phase))
        print("  Ciclo: " .. tostring(saved.cycle))
        print("  Plot:  " .. tostring(saved.currentPlotIndex) .. "/" .. #route)
        print("  Pos:   x="..saved.x.." y="..saved.y.." z="..saved.z)
        print("")
        if term.setTextColor then term.setTextColor(colors.green) end
        print("R = Reanudar")
        if term.setTextColor then term.setTextColor(colors.red) end
        print("N = Nueva sesion")
        if term.setTextColor then term.setTextColor(colors.white) end
        print(""); write("Elige [R/N]: ")

        local choice = read()
        if choice and choice:lower() == "n" then
            FarmerState.clear()
            saved = nil
            Movement.resetState()
            session.phase = "FARMING"; session.currentPlotIndex = 1
            session.cycle = 0; session.returningReason = nil
            sleep(0.5)
        else
            Movement.setState({x=saved.x, y=saved.y, z=saved.z}, saved.dir)
            session.phase            = saved.phase
            session.currentPlotIndex = saved.currentPlotIndex
            session.cycle            = saved.cycle
            session.returningReason  = saved.returningReason
        end
    else
        Movement.resetState()
        session.phase = "FARMING"; session.currentPlotIndex = 1
        session.cycle = 0; session.returningReason = nil
    end

    print(string.format("[Farmer] Iniciando: %d plots, ciclo %d", #route, session.cycle))
    if MODEM_SIDE then
        print("[Farmer] Modem activo — controlable desde pocket computer")
    end

    -- Ejecutar en paralelo: farmeo + comandos de red + heartbeat
    parallel.waitForAny(
        commandListener,
        function() farmingMain(route) end,
        heartbeatLoop
    )
end

-- ============================================================
-- Comando: STATUS
-- ============================================================

local function cmdStatus()
    print("=== Farmer Turtle - Status ==="); print("")
    local mapData = FarmMap.load()
    if mapData then
        print(string.format("Mapa:   %d plots", #mapData.plots))
    else
        print("Mapa:   No disponible (farmer scan)")
    end
    local saved = FarmerState.load()
    if saved then
        local total = mapData and #mapData.plots or "?"
        print(string.format("Fase:   %s",    tostring(saved.phase)))
        print(string.format("Ciclo:  %d",    saved.cycle))
        print(string.format("Plot:   %d/%s", saved.currentPlotIndex, tostring(total)))
        print(string.format("Pos:    x=%d y=%d z=%d dir=%s",
            saved.x, saved.y, saved.z, saved.dir))
    else
        print("Sesion: Sin estado guardado")
    end
    print("")
    print(string.format("Fuel:   %d", turtle.getFuelLevel()))
    print(string.format("Slots:  %d/16 usados", Inventory.usedSlots()))
    for seedName, _ in pairs(Crop.allSeeds()) do
        local c = countItem(seedName)
        if c > 0 then print(string.format("  %s: %d", seedName:gsub("minecraft:",""), c)) end
    end
    local bm = countItem("minecraft:bone_meal")
    if bm > 0 then print(string.format("  bone_meal: %d", bm)) end
end

-- ============================================================
-- Punto de entrada
-- ============================================================

local args = {...}
local cmd  = args[1] or "status"

if cmd == "scan" then
    cmdScan()
elseif cmd == "run" then
    local ok, err = pcall(cmdRun)
    if not ok then
        if term.setTextColor then term.setTextColor(colors.red) end
        print("[Farmer] ERROR FATAL:"); print(tostring(err))
        if term.setTextColor then term.setTextColor(colors.white) end
        Logger.error("[Farmer] ERROR FATAL: " .. tostring(err))
        print("Revisa " .. (Config.FARMER_LOG_FILE or "data/logs/farmer.log"))
    end
elseif cmd == "rescan" then
    FarmMap.clear(); FarmerState.clear()
    cmdScan()
elseif cmd == "clear-map" then
    FarmMap.clear(); FarmerState.clear()
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
