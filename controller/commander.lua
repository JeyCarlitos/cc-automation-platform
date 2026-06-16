-- controller/commander.lua
-- Interfaz de comandos inalámbricos para la PC controladora.
--
-- Ejecutar en la PC: commander
--
-- Comandos disponibles:
--   return  / r  — turtle regresa a base y se detiene
--   deposit / d  — turtle va a descargar y vuelve al trabajo
--   status  / s  — turtle responde con su estado actual
--   quit    / q  — salir del commander
--
-- Requiere: modem inalámbrico conectado a la PC en el lado configurado.

local MODEM_SIDE = "right"   -- cambia si tu modem está en otro lado
local PROTOCOL   = "ccap"
local TIMEOUT    = 8         -- segundos esperando respuesta de la turtle

-- ============================================================
-- Inicialización
-- ============================================================

if not peripheral.isPresent(MODEM_SIDE) then
    print("[ERROR] No hay modem en lado '" .. MODEM_SIDE .. "'.")
    print("Cambia MODEM_SIDE en commander.lua.")
    return
end

rednet.open(MODEM_SIDE)

-- ============================================================
-- Helpers
-- ============================================================

local function waitForReply()
    local t = os.startTimer(TIMEOUT)
    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "rednet_message" then
            local senderID, msg, proto = p1, p2, p3
            if proto == PROTOCOL then
                return senderID, msg
            end
        elseif event == "timer" and p1 == t then
            return nil, nil
        end
    end
end

local function sendCmd(cmd)
    rednet.broadcast(cmd, PROTOCOL)
    term.setTextColor(colors.yellow)
    print("Enviando: " .. cmd .. "  (esperando respuesta...)")
    term.setTextColor(colors.white)

    local id, msg = waitForReply()
    if msg then
        term.setTextColor(colors.lime)
        print("Turtle [" .. tostring(id) .. "]: " .. tostring(msg))
        term.setTextColor(colors.white)
    else
        term.setTextColor(colors.red)
        print("Sin respuesta (timeout " .. TIMEOUT .. "s).")
        term.setTextColor(colors.white)
    end
end

-- ============================================================
-- Menú principal
-- ============================================================

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.cyan)
print("=========================================")
print("  CCAP Commander — Control Inalambrico")
print("=========================================")
term.setTextColor(colors.white)
print("")
print("Comandos:")
term.setTextColor(colors.yellow)
print("  r / return   — Regresar a base y parar")
print("  d / deposit  — Descargar y volver al trabajo")
print("  s / status   — Pedir estado de la turtle")
print("  q / quit     — Salir")
term.setTextColor(colors.white)
print("")
print("La turtle debe estar en rango del modem.")
print("")

while true do
    term.setTextColor(colors.white)
    write("> ")
    local input = read()
    if not input then break end
    input = input:lower():match("^%s*(.-)%s*$")  -- trim

    if input == "r" or input == "return" then
        sendCmd("RETURN")

    elseif input == "d" or input == "deposit" then
        sendCmd("DEPOSIT")

    elseif input == "s" or input == "status" then
        sendCmd("STATUS")

    elseif input == "q" or input == "quit" then
        break

    elseif input == "" then
        -- ignorar línea vacía

    else
        term.setTextColor(colors.red)
        print("Comando no reconocido: '" .. input .. "'")
        print("Usa: r, d, s, q")
        term.setTextColor(colors.white)
    end
end

rednet.close(MODEM_SIDE)
print("Commander cerrado.")
