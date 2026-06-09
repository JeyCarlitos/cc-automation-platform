-- startup.lua
-- Entry point de CCAP Miner.
-- CC:Tweaked lo ejecuta automáticamente al encender la turtle.

if not turtle then
    print("[ERROR] Este script debe ejecutarse en una Turtle.")
    return
end

-- ============================================================
-- Preguntar si reanudar sesión guardada o empezar de cero
-- ============================================================

local STATE_FILE = "data/state/miner.json"

if fs.exists(STATE_FILE) then
    -- Leer la fase guardada para mostrarla
    local phase, layer = "?", 0
    local f = fs.open(STATE_FILE, "r")
    if f then
        local data = textutils.unserialise(f.readAll())
        f.close()
        if data then
            phase = data.phase or "?"
            layer = data.currentLayer or 0
        end
    end

    term.clear()
    term.setCursorPos(1, 1)
    if term.setTextColor then term.setTextColor(colors.yellow) end
    print("=== CCAP Miner ===")
    print("")
    if term.setTextColor then term.setTextColor(colors.white) end
    print("Sesion guardada encontrada:")
    print("  Fase:  " .. tostring(phase))
    print("  Capa:  " .. tostring(layer))
    print("")
    print("Si recolocaste la turtle en el")
    print("punto inicial, elige N (nueva).")
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
        fs.delete(STATE_FILE)
        print("Estado borrado. Iniciando sesion nueva.")
        sleep(0.8)
    else
        print("Reanudando sesion guardada...")
        sleep(0.5)
    end
end

-- ============================================================
-- Ejecutar el miner
-- ============================================================

local ok, err = pcall(function()
    local Miner = require("turtles.miner.miner")
    Miner.run()
end)

if not ok then
    if term.setTextColor then term.setTextColor(colors.red) end
    print("")
    print("ERROR FATAL:")
    print(tostring(err))
    if term.setTextColor then term.setTextColor(colors.white) end
    print("")
    print("Revisa data/logs/miner.log para mas detalles.")
    print("Corrige el error y ejecuta: startup")
end
