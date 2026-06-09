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
    "config/config.lua",
    "core/logger.lua",
    "core/movement.lua",
    "core/fuel.lua",
    "core/inventory.lua",
    "turtles/miner/state.lua",
    "turtles/miner/branchMining.lua",
    "turtles/miner/miner.lua",
}

-- Directorios a crear antes de descargar archivos.
local DIRS = {
    "config",
    "core",
    "turtles",
    "turtles/miner",
    "data",
    "data/logs",
    "data/state",
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
        print("     (o config/computercraft.cfg en versiones antiguas)")
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
        fail(path .. "  (sin respuesta HTTP: " .. tostring(err) .. ")")
        fail("  URL intentada: " .. url)
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

    -- Sobrescribir si ya existe
    if fs.exists(path) then
        fs.delete(path)
    end

    local file = fs.open(path, "w")
    if not file then
        fail(path .. "  (no se pudo abrir para escritura)")
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

    -- Verificar HTTP antes de intentar cualquier descarga
    if not checkHTTP() then return end

    -- Crear carpetas
    createDirs()

    -- Descargar todos los archivos
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

    -- Crear alias "update" copiando este instalador
    -- Permite ejecutar `update` en el futuro en lugar de re-descargar install.lua
    local runningAs = shell.getRunningProgram()
    if fs.exists(runningAs) then
        if fs.exists("update") then fs.delete("update") end
        fs.copy(runningAs, "update")
        ok("update  (alias creado)")
    end

    -- Resumen final
    print("")
    print("========================================")

    if failCount == 0 then
        printColored(colors.green, "  Instalacion completa! (" .. successCount .. " archivos)")
        print("")
        print("  Para ejecutar el miner:")
        print("    startup")
        print("")
        print("  Para actualizar desde GitHub:")
        print("    update")
    else
        printColored(colors.orange,
            "  Instalacion parcial: " .. successCount .. " OK, " .. failCount .. " fallidos")
        print("")
        print("  Verifica tu conexion y ejecuta de nuevo:")
        print("    install")
        print("")
        print("  Si el problema persiste, revisa:")
        print("    - HTTP habilitado en CC:Tweaked config")
        print("    - raw.githubusercontent.com en la allowlist")
        print("    - Nombre de usuario/repo correcto en install.lua")
    end

    print("========================================")
end

main()
