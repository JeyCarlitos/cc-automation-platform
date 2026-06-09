-- startup.lua
-- Entry point de CCAP Miner v1.
-- CC:Tweaked ejecuta este archivo automáticamente al encender la turtle.
-- También puede ejecutarse manualmente: startup

-- Verificar que el script corre en una turtle y no en una computadora normal
if not turtle then
    print("[ERROR] Este script debe ejecutarse en una Turtle.")
    print("        Instala el programa en una Mining Turtle.")
    return
end

-- Envolver en pcall para capturar errores no controlados
-- y mostrarlos de forma legible antes de que el programa muera
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
