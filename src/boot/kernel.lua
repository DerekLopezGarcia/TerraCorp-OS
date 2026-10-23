-- TerraCorp OS - kernel.
--
-- Responsabilidades: montar el volumen como sistema de ficheros, cargar los
-- módulos propios (sin `require` de OpenOS), arrancar servicios y correr el
-- bucle de señales que alimenta al escritorio.

local kernel = {}

local MODULE_ROOTS = {
  tc = "/lib/tc/",
  apps = "/apps/",
}

local APP_IDS = { "dashboard", "files", "console", "settings", "about" }

local function packCall(fn, ...)
  local result = table.pack(pcall(fn, ...))
  if not result[1] then
    return nil, tostring(result[2])
  end
  return table.unpack(result, 2, result.n)
end

local function splitPath(path)
  local parts = {}
  for part in tostring(path):gmatch("[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

-- Sistema de ficheros mínimo sobre el componente de disco de arranque.
local function makeVfs(volume)
  local vfs = {}

  function vfs.read(path)
    local handle, reason = packCall(volume.open, path, "r")
    if not handle then
      return nil, reason
    end

    local chunks = {}
    while true do
      local data, why = packCall(volume.read, handle, 4096)
      -- Un driver que devuelva "" en vez de nil al llegar al final colgaría
      -- el bucle: se corta también con cadena vacía.
      if type(data) ~= "string" or data == "" then
        packCall(volume.close, handle)
        if why then
          return nil, why
        end
        break
      end
      chunks[#chunks + 1] = data
    end

    packCall(volume.close, handle)
    return table.concat(chunks)
  end

  local function writeMode(path, data, mode)
    local handle, reason = packCall(volume.open, path, mode)
    if not handle then
      return nil, reason
    end
    local ok, why = packCall(volume.write, handle, data)
    packCall(volume.close, handle)
    if not ok then
      return nil, why
    end
    return true
  end

  function vfs.write(path, data)
    return writeMode(path, data, "w")
  end

  function vfs.append(path, data)
    return writeMode(path, data, "a")
  end

  function vfs.exists(path)
    local ok, value = pcall(volume.exists, path)
    return ok and value == true
  end

  function vfs.isDirectory(path)
    local ok, value = pcall(volume.isDirectory, path)
    return ok and value == true
  end

  function vfs.size(path)
    local value = packCall(volume.size, path)
    return tonumber(value)
  end

  -- El componente devuelve una tabla 1..n con los nombres (ver
  -- docs/opencomputers.md). Algunos drivers antiguos devuelven un iterador:
  -- se aceptan las dos formas.
  function vfs.list(path)
    local result, reason = packCall(volume.list, path)

    if type(result) == "function" then
      local names = {}
      local ok = pcall(function()
        for name in result do
          names[#names + 1] = tostring(name)
        end
      end)
      if not ok then
        return nil, "no se pudo listar " .. tostring(path)
      end
      table.sort(names)
      return names
    end

    if type(result) ~= "table" then
      return nil, reason or ("no se pudo listar " .. tostring(path))
    end

    local names = {}
    for _, name in ipairs(result) do
      names[#names + 1] = tostring(name)
    end

    -- Tabla con claves no secuenciales: recorrerla como conjunto.
    if #names == 0 and next(result) ~= nil then
      for _, name in pairs(result) do
        names[#names + 1] = tostring(name)
      end
    end

    table.sort(names)
    return names
  end

  function vfs.ensureDir(path)
    local current = ""
    for _, part in ipairs(splitPath(path)) do
      current = current .. "/" .. part
      if not vfs.exists(current) then
        local ok, reason = packCall(volume.makeDirectory, current)
        if not ok and not vfs.exists(current) then
          return nil, reason
        end
      end
    end
    return true
  end

  function vfs.remove(path)
    return packCall(volume.remove, path)
  end

  function vfs.rename(from, to)
    return packCall(volume.rename, from, to)
  end

  -- OpenComputers expone spaceUsed/spaceTotal en bytes; el resto del OS
  -- trabaja en kilobytes (ver docs/arquitectura.md).
  function vfs.space()
    local used = packCall(volume.spaceUsed)
    local total = packCall(volume.spaceTotal)
    if type(used) ~= "number" or type(total) ~= "number" then
      return nil
    end
    return used / 1024, total / 1024
  end

  return vfs
end

--------------------------------------------------------------------------------
-- Servicios del kernel
--------------------------------------------------------------------------------

function kernel:uptime()
  return computer.uptime()
end

function kernel:energy()
  local ok, stored, maximum = pcall(computer.energy)
  if not ok or type(stored) ~= "number" then
    return nil
  end
  -- Algunos nodos reportan solo `stored` o un `maximum` inválido. Se trata
  -- como "sin lectura de energía" en vez de reventar al dividir por nil.
  if type(maximum) ~= "number" or maximum <= 0 then
    return nil
  end
  return stored, maximum
end

function kernel:energyPercent()
  local stored, maximum = self:energy()
  if not stored or not maximum or maximum <= 0 then
    return 100
  end
  return (stored / maximum) * 100
end

function kernel:memory()
  local total = computer.totalMemory()
  local free = computer.freeMemory()
  return total - free, total
end

function kernel:components()
  local now = computer.uptime()
  local cached = self._components
  if cached and now - cached.at < 3 then
    return cached
  end

  local counts, total = {}, 0
  for _, kind in component.list() do
    counts[kind] = (counts[kind] or 0) + 1
    total = total + 1
  end

  -- La tarjeta "Enlaces" muestra periféricos, no la electrónica interna.
  local internal = {
    computer = true,
    eeprom = true,
    filesystem = true,
    gpu = true,
    keyboard = true,
    screen = true,
  }

  local entries = {}
  for kind, count in pairs(counts) do
    if not internal[kind] then
      entries[#entries + 1] = { kind = kind, count = count }
    end
  end
  table.sort(entries, function(a, b)
    if a.count == b.count then
      return a.kind < b.kind
    end
    return a.count > b.count
  end)

  self._components = { at = now, total = total, entries = entries }
  return self._components
end

function kernel:storage()
  return self.vfs.space()
end

function kernel:applyTheme()
  self.theme = self.themeModule.build(self.config)
  self.ui.theme = self.theme
  self.ui.colors = self.theme.colors
  self.ui.glyphs = self.theme.glyphs
  self.log.setLevel(self.config.get("logLevel"))
  self.ui:markDirty()
end

function kernel:saveConfig()
  local ok, reason = self.config.save(self.vfs)
  if not ok then
    self.log.warn("no se pudo guardar la configuración: " .. tostring(reason))
  end
  return ok
end

function kernel:rebindScreen()
  local gpuAddress = component.list("gpu")()
  local screenAddress = component.list("screen")()

  if gpuAddress and screenAddress then
    pcall(component.invoke, gpuAddress, "bind", screenAddress)
  end

  if gpuAddress and gpuAddress ~= self.gfx.address then
    local ok, replacement = pcall(self.gfxModule.new, gpuAddress)
    if ok then
      self.gfx = replacement
      self.ui.gfx = replacement
    end
  end

  if self.gfx:resize() then
    self.ui:resize()
  end
  self.ui:markDirty()
end

function kernel:poweroff(reboot)
  local colors = self.theme.colors
  self.gfx:clear(colors.bg)
  self.gfx:put(2, 1, reboot and "Reiniciando TerraCorp OS..." or "Apagando TerraCorp OS...", colors.dim, colors.bg)
  self.gfx:flush()
  pcall(os.sleep, 0.3)
  computer.shutdown(reboot == true)
end

-- Último recurso: si el escritorio no se puede pintar, se avisa con la GPU en
-- crudo. Sin esto, un fallo de render deja una pantalla negra sin explicación.
function kernel:emergency(reason)
  local gpu = self.gfx and self.gfx.gpu
  if not gpu then
    return
  end

  local ok, width, height = pcall(gpu.getResolution)
  if not ok or not width or not height then
    width, height = 80, 25
  end

  local message = tostring(reason or "sin detalle")
  pcall(gpu.setBackground, 15)
  pcall(gpu.setForeground, 14)
  pcall(gpu.fill, 1, 1, width, math.min(7, height), " ")
  pcall(gpu.set, 2, 2, "TerraCorp OS: no se pudo pintar el escritorio")
  pcall(gpu.set, 2, 4, string.sub(message, 1, math.max(1, width - 4)))
  pcall(gpu.set, 2, 5, "Detalle completo en /var/log/tc.log")
end

function kernel:loop()
  local lastTick = computer.uptime()
  local renderErrors = 0
  local gpuFailures = 0

  while true do
    local pack = table.pack(pcall(computer.pullSignal, 0.2))

    if not pack[1] then
      self.log.error("pullSignal: " .. tostring(pack[2]))
      pcall(os.sleep, 0.25)
    elseif pack[2] then
      local name = pack[2]
      if name == "shutdown" or name == "reboot" then
        return
      end
      if name ~= "interrupted" then
        local ok, reason = pcall(self.ui.dispatch, self.ui, table.unpack(pack, 2, pack.n))
        if not ok then
          self.log.error("evento " .. tostring(name) .. ": " .. tostring(reason))
        end
      end
    end

    local now = computer.uptime()
    if now - lastTick >= 1 then
      lastTick = now
      pcall(self.ui.tick, self.ui)
    end

    local okRender, reason, failed = pcall(self.ui.render, self.ui, false)

    -- La GPU rechaza tramos si no tiene energía suficiente. No es un error de
    -- Lua: las celdas quedan pendientes y se reintentan en el frame siguiente.
    if okRender and type(failed) == "number" and failed > 0 then
      gpuFailures = gpuFailures + 1
      if gpuFailures == 1 or gpuFailures % 20 == 0 then
        self.log.warn("gpu: " .. failed .. " tramos sin escribir (¿energía?) en " .. gpuFailures .. " frames")
      end
    elseif okRender and gpuFailures > 0 then
      self.log.info("gpu recuperada tras " .. gpuFailures .. " frames")
      gpuFailures = 0
    end

    if not okRender then
      renderErrors = renderErrors + 1
      -- El render marca `dirty = false` antes de pintar: si falla a medias hay
      -- que volver a pedirlo o la pantalla se queda congelada.
      self.ui:markDirty()
      if renderErrors == 1 then
        -- Se avisa por pantalla: una negra sin texto no dice nada.
        self:emergency(reason)
      end
      -- Sin límite esto escribe en disco por frame si se retira la pantalla;
      -- se registra el primero y luego uno cada 30 intentos.
      if renderErrors == 1 or renderErrors % 30 == 0 then
        self.log.error("render (" .. renderErrors .. " fallos): " .. tostring(reason))
      end
      pcall(os.sleep, math.min(1, 0.05 * renderErrors))
    elseif renderErrors > 0 then
      self.log.info("render recuperado tras " .. renderErrors .. " fallos")
      renderErrors = 0
    end
  end
end

--------------------------------------------------------------------------------
-- Arranque
--------------------------------------------------------------------------------

function kernel.start(boot)
  local volume = component.proxy(boot.address)
  if not volume then
    error("TerraCorp OS: el volumen " .. tostring(boot.address) .. " no responde", 0)
  end

  local vfs = makeVfs(volume)
  local cache = {}

  local BASE = {
    assert = assert,
    error = error,
    ipairs = ipairs,
    pairs = pairs,
    next = next,
    pcall = pcall,
    xpcall = xpcall,
    select = select,
    print = print,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    setmetatable = setmetatable,
    getmetatable = getmetatable,
    rawget = rawget,
    rawset = rawset,
    rawequal = rawequal,
    unpack = table.unpack,
    load = load,
    math = math,
    string = string,
    table = table,
    os = os,
    io = io,
    coroutine = coroutine,
    utf8 = utf8,
  }

  local requireModule

  local function resolve(id)
    local root, name = id:match("^(%a[%w_]*)%.([%w_]+)$")
    local base = root and MODULE_ROOTS[root]
    if not base then
      return nil
    end
    return base .. name .. ".lua"
  end

  local function newEnv()
    local env = {}
    for key, value in pairs(BASE) do
      env[key] = value
    end
    env.require = requireModule
    env.component = component
    env.computer = computer
    env._G = env
    return env
  end

  requireModule = function(id)
    local cached = cache[id]
    if cached ~= nil then
      return cached
    end

    local path = resolve(id)
    if not path then
      error("módulo desconocido: " .. tostring(id), 0)
    end

    local source, reason = vfs.read(path)
    if not source then
      error("no se pudo leer " .. path .. ": " .. tostring(reason), 0)
    end

    local chunk, compileError = load(source, "=" .. path, "t", newEnv())
    if not chunk then
      error("error de sintaxis en " .. path .. ": " .. tostring(compileError), 0)
    end

    local result = chunk(id)
    cache[id] = result
    return result
  end

  local version = requireModule("tc.version")
  local util = requireModule("tc.util")
  local text = requireModule("tc.text")
  local log = requireModule("tc.log")
  local config = requireModule("tc.config")
  local themeModule = requireModule("tc.theme")
  local gfxModule = requireModule("tc.gfx")
  local uiModule = requireModule("tc.ui")

  -- /etc y /var/log deben existir antes de leer preferencias y abrir el
  -- registro: una instalación manual (copiar src/*) no los crea.
  vfs.ensureDir("/etc")
  vfs.ensureDir("/var/log")

  config.load(vfs)
  log.setLevel(config.get("logLevel"))

  -- El registro se abre antes de tocar la GPU: si el arranque se cuelga al
  -- inicializar vídeo o el splash, la primera línea ya está escrita y se sabe
  -- que el fallo no es del volumen.
  log.setSink(function(line)
    local size = vfs.size("/var/log/tc.log") or 0
    if size > 131072 then
      vfs.write("/var/log/tc.log", "")
    end
    vfs.append("/var/log/tc.log", line .. "\n")
  end)

  local address = computer.address()
  local configured = config.get("hostname")
  local hostname = configured
  if hostname == "" then
    hostname = "TC-" .. tostring(address):sub(1, 4):upper()
  end

  log.info("arranque " .. version.product .. " " .. version.version .. " en " .. hostname)

  local gpuAddress = component.list("gpu")()
  if not gpuAddress then
    error("TerraCorp OS: se necesita una GPU para arrancar", 0)
  end

  local screenAddress = component.list("screen")()
  if screenAddress then
    pcall(component.invoke, gpuAddress, "bind", screenAddress)
  end

  local theme = themeModule.build(config)
  local gfx = gfxModule.new(gpuAddress)

  local okLimits, maxWidth, maxHeight = pcall(gfx.gpu.maxResolution)
  if okLimits and maxWidth and maxHeight then
    local targetWidth = math.min(maxWidth, 118)
    local targetHeight = math.min(maxHeight, 44)
    if targetWidth ~= gfx.w or targetHeight ~= gfx.h then
      if pcall(gfx.gpu.setResolution, targetWidth, targetHeight) then
        gfx:resize()
      end
    end
  end

  local function drawSplash(ratio, message)
    local colors = theme.colors
    gfx:clear(colors.bg)

    local function center(textValue, row, fg)
      local column = math.max(1, math.floor((gfx.w - text.width(textValue)) / 2) + 1)
      gfx:put(column, row, textValue, fg, colors.bg)
    end

    local middle = math.floor(gfx.h / 2)
    center("TERRACORP", middle - 4, colors.accent)
    center("O S", middle - 3, colors.accent)
    center(version.tagline:upper(), middle - 1, colors.dim)
    center("v" .. version.version .. "  " .. version.codename, middle, colors.dim)

    local width = math.min(40, gfx.w - 8)
    local column = math.floor((gfx.w - width) / 2) + 1
    gfx:bar(column, middle + 2, width, ratio, colors.accent, colors.bg, theme.glyphs.block)
    center(message, middle + 4, colors.dim)
    gfx:flush()
  end

  local splash = config.get("splash") == true
  if splash then
    log.info("splash")
    drawSplash(0.25, "Montando servicios base")
  end

  local instance = setmetatable({
    version = version,
    util = util,
    text = text,
    log = log,
    config = config,
    theme = theme,
    themeModule = themeModule,
    gfxModule = gfxModule,
    gfx = gfx,
    vfs = vfs,
    volume = volume,
    address = address,
    hostname = hostname,
  }, { __index = kernel })

  -- Diagnóstico de arranque: si la pantalla acaba negra, el registro dice con
  -- qué GPU, qué pantalla y qué resolución se estaba trabajando.
  log.info(string.format(
    "gpu %s · pantalla %s · %dx%d · %d KB libres",
    tostring(gpuAddress):sub(1, 4),
    tostring(screenAddress or "-"):sub(1, 4),
    gfx.w,
    gfx.h,
    math.floor(computer.freeMemory() / 1024)
  ))

  local apps = {}
  for _, id in ipairs(APP_IDS) do
    local ok, module = pcall(requireModule, "apps." .. id)
    if ok and type(module) == "table" then
      apps[#apps + 1] = module
    else
      log.error("app no disponible: " .. id .. " (" .. tostring(module) .. ")")
    end
  end

  instance.ui = uiModule.new({
    kernel = instance,
    gfx = gfx,
    theme = theme,
    log = log,
    config = config,
    version = version,
    apps = apps,
    util = util,
  })

  if splash then
    drawSplash(0.75, "Iniciando escritorio")
    pcall(os.sleep, 0.4)
    drawSplash(1, "Sesión lista")
    pcall(os.sleep, 0.35)
  end

  -- Primera composición controlada: si el escritorio no se puede pintar, se
  -- dice en pantalla en vez de arrancar con el framebuffer en negro.
  log.info("primer render")
  local okPaint, paintReason = pcall(instance.ui.render, instance.ui, true)
  if not okPaint then
    instance:emergency(paintReason)
    log.error("primer render: " .. tostring(paintReason))
  elseif instance.ui.failures then
    log.error("primer render con avisos: " .. table.concat(instance.ui.failures, " | "))
  else
    log.info("primer render ok")
  end

  instance:loop()
end

return kernel
