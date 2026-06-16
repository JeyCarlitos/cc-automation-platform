-- controller/commander.lua
-- Panel de control multi-turtle para CCAP.
--
-- Cómo instalar en la PC estática:
--   wget https://raw.githubusercontent.com/JeyCarlitos/cc-automation-platform/main/install.lua install
--   install
--   commander
--
-- Comandos:
--   s  [id]  — STATUS: estado de todas o de una turtle específica
--   r  [id]  — RETURN: regresar a base y parar
--   d  [id]  — DEPOSIT: descargar inventario y seguir minando
--   u  [id]  — UPDATE: actualizar código desde GitHub y reiniciar
--   rb [id]  — REBOOT: reiniciar turtle
--   list     — listar turtles conocidas
--   q        — salir
--
--  [id] es el número de ID de la turtle (omítelo para enviar a TODAS).

local MODEM_SIDE = "right"   -- cambia si tu modem está en otro lado
local PROTOCOL   = "ccap"
local TIMEOUT    = 10        -- segundos esperando respuestas

-- ============================================================
-- Inicialización
-- ============================================================

if not peripheral.isPresent(MODEM_SIDE) then
    print("[ERROR] No hay modem en lado '" .. MODEM_SIDE .. "'.")
    print("Cambia MODEM_SIDE al inicio de commander.lua y actualiza.")
    return
end

rednet.open(MODEM_SIDE)

-- ============================================================
-- Registro dinámico de turtles
-- Se puebla automáticamente cuando una turtle responde.
-- registry[id] = { label, lastSeen, lastStatus }
-- ============================================================

local registry = {}

local function registerTurtle(id, label, status)
    if not registry[id] then registry[id] = {} end
    if label then registry[id].label = label end
    registry[id].lastSeen = os.clock()
    if status then registry[id].lastStatus = status end
end

local function knownIds()
    local ids = {}
    for id in pairs(registry) do ids[#ids+1] = id end
    table.sort(ids)
    return ids
end

local function displayName(id)
    local t = registry[id]
    if t and t.label then return t.label end
    return "ID:" .. tostring(id)
end

-- ============================================================
-- Helpers de color
-- ============================================================

local function clr(color, text)
    if term.isColor and term.isColor() then term.setTextColor(color) end
    write(text)
    if term.isColor and term.isColor() then term.setTextColor(colors.white) end
end

local function clrln(color, text) clr(color, text) print("") end

-- ============================================================
-- Envío
-- ============================================================

local function send(targetId, cmd)
    if targetId then
        rednet.send(targetId, cmd, PROTOCOL)
    else
        rednet.broadcast(cmd, PROTOCOL)
    end
end

-- ============================================================
-- Recepción (recoge TODAS las respuestas hasta timeout)
-- ============================================================

local function collectReplies(timeout, expectedIds)
    local replies = {}
    local pending = {}
    if expectedIds then
        for _, id in ipairs(expectedIds) do pending[id] = true end
    end

    local deadline = os.clock() + timeout

    while os.clock() < deadline do
        local remaining = math.max(0.05, deadline - os.clock())
        local t = os.startTimer(remaining)

        local event, p1, p2, p3 = os.pullEvent()

        if event == "rednet_message" then
            local senderID, msg, proto = p1, p2, p3
            os.cancelTimer(t)
            if proto == PROTOCOL then
                replies[#replies+1] = { id = senderID, msg = tostring(msg) }
                pending[senderID] = nil

                -- Salir antes si ya tenemos respuesta de todos los esperados
                if expectedIds then
                    local allDone = true
                    for _ in pairs(pending) do allDone = false; break end
                    if allDone then break end
                end
            end
        elseif event == "timer" and p1 == t then
            break
        else
            os.cancelTimer(t)
        end
    end

    return replies
end

-- ============================================================
-- Ejecutar un comando y mostrar respuestas
-- ============================================================

local function runCmd(cmd, targetId)
    local dest = targetId and ("turtle " .. displayName(targetId)) or "TODAS las turtles"
    clr(colors.yellow, "→ " .. cmd)
    clrln(colors.lightGray, "  →  " .. dest)

    send(targetId, cmd)

    -- Esperar respuestas de las turtles conocidas (o de la target específica)
    local expectedIds = targetId and {targetId} or knownIds()
    local replies = collectReplies(TIMEOUT, #expectedIds > 0 and expectedIds or nil)

    if #replies == 0 then
        clrln(colors.red, "  Sin respuesta (timeout " .. TIMEOUT .. "s).")
        clrln(colors.lightGray, "  Asegúrate de que la turtle esté encendida y en rango.")
    else
        for _, r in ipairs(replies) do
            -- Extraer label si viene en el mensaje: "[LABEL] resto..."
            local lbl = r.msg:match("^%[(.-)%]")
            registerTurtle(r.id, lbl, r.msg)

            clr(colors.lime, "  [" .. displayName(r.id) .. "] ")
            print(r.msg)
        end
    end
    print("")
end

-- ============================================================
-- Comando LIST
-- ============================================================

local function listTurtles()
    local ids = knownIds()
    if #ids == 0 then
        clrln(colors.orange, "  Sin turtles registradas todavía.")
        clrln(colors.lightGray, "  Usa 's' para descubrirlas (broadcast de STATUS).")
        print("")
        return
    end
    clrln(colors.yellow, "  Turtles conocidas:")
    for _, id in ipairs(ids) do
        local t   = registry[id]
        local age = t.lastSeen and math.floor(os.clock() - t.lastSeen) or "?"
        clr(colors.lime,      string.format("  [ID:%-4d]  ", id))
        clr(colors.white,     string.format("%-24s", t.label or "(sin label)"))
        clrln(colors.lightGray, " hace " .. age .. "s")
    end
    print("")
end

-- ============================================================
-- Header
-- ============================================================

local function printHeader()
    term.clear()
    term.setCursorPos(1, 1)
    clrln(colors.cyan, "==========================================")
    clrln(colors.cyan, "  CCAP Commander  —  Control Multi-Turtle")
    clrln(colors.cyan, "==========================================")
    print("")
    clrln(colors.yellow, "  Comandos  (agrega [id] para una turtle):")
    print("   s  [id]  — estado actual")
    print("   r  [id]  — regresar a base y parar")
    print("   d  [id]  — descargar y seguir minando")
    print("   u  [id]  — actualizar código (GitHub) y reiniciar")
    print("   rb [id]  — reiniciar turtle")
    print("   list     — turtles conocidas")
    print("   q        — salir")
    print("")
    clrln(colors.lightGray, "  Omite [id] para enviar a TODAS.")
    print("")
end

-- ============================================================
-- Parser de entrada
-- ============================================================

local CMD_MAP = {
    s       = "STATUS",
    status  = "STATUS",
    r       = "RETURN",
    ["return"] = "RETURN",
    d       = "DEPOSIT",
    deposit = "DEPOSIT",
    u       = "UPDATE",
    update  = "UPDATE",
    rb      = "REBOOT",
    reboot  = "REBOOT",
}

local function parseInput(raw)
    local input = raw:lower():match("^%s*(.-)%s*$")

    -- Comandos especiales sin ID
    if input == "list"              then return "LIST", nil end
    if input == "q" or input == "quit" then return "QUIT", nil end
    if input == ""                  then return "EMPTY", nil end

    -- "cmd" o "cmd id"
    local word, rest = input:match("^(%S+)%s*(.*)$")
    if not word then return nil, nil end

    local cmd = CMD_MAP[word]
    if not cmd then return nil, nil end

    local targetId = nil
    if rest and rest ~= "" then
        targetId = tonumber(rest)
        if not targetId then
            clrln(colors.red, "  ID inválido: '" .. rest .. "'. Usa el número de computadora.")
            return "INVALID", nil
        end
    end

    return cmd, targetId
end

-- ============================================================
-- Bucle principal
-- ============================================================

printHeader()

while true do
    clr(colors.white, "> ")
    local raw = read()
    if not raw then break end

    local cmd, targetId = parseInput(raw)

    if     cmd == "QUIT"    then break
    elseif cmd == "LIST"    then listTurtles()
    elseif cmd == "EMPTY"   then -- ignorar
    elseif cmd == "INVALID" then -- ya mostró error
    elseif cmd ~= nil       then runCmd(cmd, targetId)
    else
        clrln(colors.red, "  Comando no reconocido.")
        print("  Usa: s, r, d, u, rb, list, q")
        print("")
    end
end

rednet.close(MODEM_SIDE)
clrln(colors.lightGray, "Commander cerrado.")
