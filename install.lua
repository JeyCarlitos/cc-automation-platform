-- install.lua
-- Instalador y actualizador de CCAP desde GitHub.
-- Primera instalación:
--   wget https://raw.githubusercontent.com/JeyCarlitos/cc-automation-platform/main/install.lua install
--   install
-- Actualizaciones futuras:
--   update

local REPO_USER   = "JeyCarlitos"
local REPO_NAME   = "cc-automation-platform"
local REPO_BRANCH = "main"
local BASE_URL    = "https://raw.githubusercontent.com/"
                  .. REPO_USER .. "/" .. REPO_NAME .. "/" .. REPO_BRANCH .. "/"

-- Lista completa de archivos del proyecto.
-- Agregar aquí cada nuevo archivo que se añada al repo.
local FILES = {
    "startup.lua",
    "install.lua",       -- se auto-actualiza desde GitHub
    "config/config.lua",
    "config/constants.lua",
    "core/logger.lua",
    "core/movement.lua",
    "core/fuel.lua",
    "core/inventory.lua",
    "core/network.lua",
    "turtles/miner/state.lua",
    "turtles/miner/quarry.lua",
    "turtles/miner/miner.lua",
    "turtles/farmer/crop.lua",
    "turtles/farmer/farmMap.lua",
    "turtles/farmer/farmRoute.lua",
    "turtles/farmer/farmScanner.lua",
    "turtles/farmer/farmerState.lua",
    "turtles/farmer/farmer.lua",
    "controller/commander.lua",
}

local DIRS = {
    "config",
    "core",
    "controller",
    "turtles",
    "turtles/miner",
    "turtles/farmer",
    "data",
    "data/logs",
    "data/state",
    "data/jobs",
    "data/metrics",
}

-- ============================================================
-- Utilidades de presentación
-- ============================================================

local function printColored(color, msg)
    if term.isColor and term.isColor() then
        term.setTextColor(color)
    end
    print(msg)
    if term.isColor and term.isColor() then
        term.setTextColor(colors.white)
    end
end

local function ok(msg)   printColored(colors.green,  "  [OK]   " .. msg) end
local function fail(msg) printColored(colors.red,    "  [FAIL] " .. msg) end
local function info(msg) printColored(colors.yellow, "  [ .. ] " .. msg) end

-- ============================================================
-- Verificación de HTTP
-- ============================================================

local function checkHTTP()
    if not http then
        fail("HTTP API no disponible.")
        print("")
        print("Para habilitar HTTP en CC:Tweaked:")
        print("  1. Abre serverconfig/computercraft-server.toml")
        print("  2. Establece: http_enable = true")
        print("  3. Agrega a la allowlist: raw.githubusercontent.com")
        print("  4. Reinicia el servidor / juego")
        return false
    end
    return true
end

-- ============================================================
-- Creación de directorios
-- ============================================================

local function createDirs()
    print("\nCreando estructura de directorios...")
    for _, dir in ipairs(DIRS) do
        if not fs.exists(dir) then
            fs.makeDir(dir)
            print("  mkdir " .. dir)
        end
    end
end

-- ============================================================
-- Descarga de un archivo individual
-- ============================================================

local function downloadFile(path)
    local url = BASE_URL .. path
    info("Descargando " .. path)

    local response, err = http.get(url)

    if not response then
        fail(path .. "  (" .. tostring(err) .. ")")
        return false
    end

    if response.getResponseCode and response.getResponseCode() ~= 200 then
        local code = response.getResponseCode()
        response.close()
        fail(path .. "  (HTTP " .. code .. ")")
        return false
    end

    local content = response.readAll()
    response.close()

    if not content or #content == 0 then
        fail(path .. "  (respuesta vacía)")
        return false
    end

    if fs.exists(path) then fs.delete(path) end

    local file = fs.open(path, "w")
    if not file then
        fail(path .. "  (no se pudo escribir)")
        return false
    end
    file.write(content)
    file.close()

    ok(path)
    return true
end

-- ============================================================
-- Programa principal
-- ============================================================

local function main()
    term.clear()
    term.setCursorPos(1, 1)

    print("========================================")
    print("  CCAP Installer")
    print("  " .. REPO_USER .. "/" .. REPO_NAME .. " @ " .. REPO_BRANCH)
    print("========================================")

    if not checkHTTP() then return end

    createDirs()

    print("\nDescargando archivos del proyecto...")
    local successCount = 0
    local failCount    = 0

    for _, path in ipairs(FILES) do
        if downloadFile(path) then
            successCount = successCount + 1
        else
            failCount = failCount + 1
        end
    end

    -- Actualizar el comando "update" con la versión recién descargada de install.lua.
    -- Así "update" siempre tiene el código más reciente del repo.
    if fs.exists("install.lua") then
        if fs.exists("update") then fs.delete("update") end
        fs.copy("install.lua", "update")
        ok("update  (actualizado desde install.lua)")
    elseif fs.exists(shell.getRunningProgram()) then
        if fs.exists("update") then fs.delete("update") end
        fs.copy(shell.getRunningProgram(), "update")
        ok("update  (alias de " .. shell.getRunningProgram() .. ")")
    end

    -- Crear/actualizar el shortcut "commander" en la raíz.
    -- Permite ejecutar 'commander' directamente desde cualquier máquina.
    if fs.exists("controller/commander.lua") then
        if fs.exists("commander") then fs.delete("commander") end
        fs.copy("controller/commander.lua", "commander")
        ok("commander  (shortcut actualizado)")
    end

    -- Crear/actualizar el shortcut "farmer" en la raíz.
    -- Permite ejecutar 'farmer scan', 'farmer run', etc. directamente.
    if fs.exists("turtles/farmer/farmer.lua") then
        if fs.exists("farmer") then fs.delete("farmer") end
        fs.copy("turtles/farmer/farmer.lua", "farmer")
        ok("farmer  (shortcut actualizado)")
    end

    print("")
    print("========================================")

    if failCount == 0 then
        if term.setTextColor then term.setTextColor(colors.green) end
        print("  Instalacion completa! (" .. successCount .. " archivos)")
        if term.setTextColor then term.setTextColor(colors.white) end
        print("")
        print("  Para ejecutar el miner:")
        print("    startup")
        print("")
        print("  Para actualizar desde GitHub:")
        print("    update")
    else
        if term.setTextColor then term.setTextColor(colors.orange) end
        print("  Instalacion parcial: " .. successCount .. " OK, " .. failCount .. " fallidos")
        if term.setTextColor then term.setTextColor(colors.white) end
        print("")
        print("  Ejecuta de nuevo: install")
    end

    print("========================================")
end

main()
