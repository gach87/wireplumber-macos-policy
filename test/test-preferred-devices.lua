-- Pruebas de la logica del componente, con el doble configurable.
-- Cada prueba construye su propio Fake con los valores que necesita, carga el
-- componente real y valida lo que hizo.

local HERE = arg[0]:match ("(.*)/") or "."
local Fake = dofile (HERE .. "/fake-wireplumber.lua")
local SRC = HERE .. "/../src/preferred-devices.lua"

local SINK, SRCC = "Audio/Sink", "Audio/Source"
local pass, fail = 0, 0

local function check (name, got, want)
  if got == want then
    pass = pass + 1
    print (string.format ("  ok   %s", name))
  else
    fail = fail + 1
    print (string.format ("  FALLO %s\n         esperado: %s\n         obtenido: %s",
                          name, tostring (want), tostring (got)))
  end
end

local function nodes (...)
  local t = {}
  for _, n in ipairs {...} do table.insert (t, { name = n, class = SINK }) end
  return t
end

-- Corre el hook de seleccion una vez y devuelve el evento ya resuelto.
local function select (comp, wp, spec)
  local ev = wp:select_event (spec)
  comp:run ("preferred-devices/select", ev)
  return ev
end

--------------------------------------------------------------------------
print ("llegada de un dispositivo")
do
  local wp = Fake.new { state = { ["sink.0"] = "bocinas" } }
  local c = wp:load (SRC)
  -- primer evento: establece la foto inicial, nada cuenta como llegada
  select (c, wp, { kind = "audio.sink", nodes = nodes ("bocinas") })
  -- segundo: aparece el BT
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("bocinas", "bt") })
  check ("el recien llegado gana", ev:selected (), "bt")
  check ("y queda al frente de la lista", wp:preferred ("sink")[1], "bt")
end

--------------------------------------------------------------------------
print ("eleccion manual estando el BT conectado")
do
  local wp = Fake.new { state = { ["sink.0"] = "bt", ["sink.1"] = "cornetas" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = nodes ("bt", "cornetas") })
  -- el hook nativo ya eligio "cornetas" con el bono de seleccion manual
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("bt", "cornetas"),
                              selected = "cornetas", priority = 30900 })
  check ("la eleccion manual gana al BT", ev:selected (), "cornetas")
  check ("y pasa al frente", wp:preferred ("sink")[1], "cornetas")
end

--------------------------------------------------------------------------
print ("desconexion")
do
  local wp = Fake.new { state = { ["sink.0"] = "bt", ["sink.1"] = "cornetas",
                                  ["sink.2"] = "bocinas" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = nodes ("bt", "cornetas", "bocinas") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("cornetas", "bocinas") })
  check ("cae al siguiente presente, no al de mayor prioridad", ev:selected (), "cornetas")
end

--------------------------------------------------------------------------
print ("reconexion")
do
  local wp = Fake.new { state = { ["sink.0"] = "cornetas", ["sink.1"] = "bt" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = nodes ("cornetas") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("cornetas", "bt") })
  check ("al reconectar vuelve a ganar", ev:selected (), "bt")
end

--------------------------------------------------------------------------
print ("dispositivos que no deben robar el foco (NO_ARRIVAL)")
do
  local wp = Fake.new { state = { ["sink.0"] = "bt" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = nodes ("bt") })
  -- un sink de red reaparece: no es una accion del usuario
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("bt", "to-desktop-speakers") })
  check ("el sink de red no roba el foco", ev:selected (), "bt")
end

--------------------------------------------------------------------------
print ("reinicio del grafo (reaparecen varios a la vez)")
do
  local wp = Fake.new { state = { ["sink.0"] = "bt" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = nodes ("bt") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = nodes ("bt", "hdmi1", "hdmi2") })
  check ("varias llegadas a la vez no reordenan", ev:selected (), "bt")
  check ("y no se cuelan al frente", wp:preferred ("sink")[1], "bt")
end

--------------------------------------------------------------------------
print ("filtrado por direccion")
do
  local wp = Fake.new {}
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.source", nodes = {
    { name = "un-sink", class = SINK },
    { name = "un-mic",  class = SRCC },
  } }
  c:run ("preferred-devices/select", ev)
  check ("un evento de entrada ignora los sinks", ev:selected (), "un-mic")
end

--------------------------------------------------------------------------
print ("perfil preferido")
do
  local wp = Fake.new { profile_rules = { priorities = { "a2dp-sink-sbc_xq", "a2dp-sink" } } }
  local c = wp:load (SRC)
  local ev = wp:profile_event {
    device_props = { ["device.api"] = "bluez5" },
    profiles = { "a2dp-sink", "a2dp-sink-sbc_xq", "headset-head-unit" },
  }
  c:run ("preferred-devices/prefer-profile", ev)
  check ("elige el mejor perfil disponible", ev:selected (), "a2dp-sink-sbc_xq")
end

do
  local wp = Fake.new { profile_rules = { priorities = { "a2dp-sink-sbc_xq" } } }
  local c = wp:load (SRC)
  local ev = wp:profile_event {
    device_props = { ["device.api"] = "bluez5" },
    profiles = { "a2dp-sink-sbc_xq", "headset-head-unit" },
    selected = { name = "headset-head-unit" },   -- llamada en curso
  }
  c:run ("preferred-devices/prefer-profile", ev)
  check ("no pisa una llamada en curso", ev:selected (), "headset-head-unit")
end

--------------------------------------------------------------------------
print ("desmuteo al volver el Bluetooth")
do
  local wp = Fake.new {}
  wp.devices = { wp:device {
    { index = 7, device = 0, direction = "Output", available = "yes" },
    { index = 8, device = 0, direction = "Input",  available = "yes" },
  } }
  local c = wp:load (SRC)
  c:run ("preferred-devices/unmute-on-bt-return", wp:node_added_event ())
  check ("desmutea la ruta de salida", wp.route_mutes[1] and wp.route_mutes[1].index, 7)
  check ("con mute = false", wp.route_mutes[1] and wp.route_mutes[1].mute, false)
  check ("y no toca la de entrada", #wp.route_mutes, 1)
end

--------------------------------------------------------------------------
print ()
print (string.format ("%d pruebas, %d fallos", pass + fail, fail))
os.exit (fail == 0 and 0 or 1)
