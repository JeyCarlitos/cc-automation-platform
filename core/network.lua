-- core/network.lua
-- Capa de abstracción sobre rednet para CCAP.
--
-- Protocolo de mensajes (strings):
--   PC → Turtle : "RETURN"   — terminar, regresar a base y quedarse
--   PC → Turtle : "DEPOSIT"  — ir a descargar y volver al trabajo
--   PC → Turtle : "STATUS"   — responder con estado actual
--   Turtle → PC : "ACK:<cmd>"       — confirmación de recepción
--   Turtle → PC : "STATUS:<datos>"  — respuesta a STATUS

local Config = require("config.config")
local Logger = require("core.logger")

local Network = {}

-- ============================================================
-- Apertura / cierre
-- ============================================================

-- Abre el modem en el lado configurado.
-- Retorna true si tuvo éxito, false si no hay modem.
function Network.open()
    if peripheral.isPresent(Config.MODEM_SIDE) then
        rednet.open(Config.MODEM_SIDE)
        Logger.info("Modem abierto en lado: " .. Config.MODEM_SIDE)
        return true
    end
    Logger.warn("No se encontro modem en lado '" .. Config.MODEM_SIDE ..
                "'. Comandos remotos desactivados.")
    return false
end

function Network.isOpen()
    return rednet.isOpen(Config.MODEM_SIDE)
end

-- ============================================================
-- Envío
-- ============================================================

-- Envía mensaje a una ID específica.
function Network.send(id, msg)
    if rednet.isOpen(Config.MODEM_SIDE) then
        rednet.send(id, tostring(msg), "ccap")
    end
end

-- Difunde mensaje a todos los equipos en rango.
function Network.broadcast(msg)
    if rednet.isOpen(Config.MODEM_SIDE) then
        rednet.broadcast(tostring(msg), "ccap")
    end
end

-- ============================================================
-- Recepción
-- ============================================================

-- Espera un mensaje con timeout opcional.
-- Filtra por protocolo "ccap" y, si Config.CONTROLLER_ID != nil, por ID.
-- Retorna: senderID, message  (o nil, nil si timeout)
function Network.receive(timeout)
    local id, msg = rednet.receive("ccap", timeout)
    if id == nil then return nil, nil end
    -- Filtro por ID controladora (si está configurado)
    if Config.CONTROLLER_ID and id ~= Config.CONTROLLER_ID then
        return nil, nil
    end
    return id, msg
end

return Network
