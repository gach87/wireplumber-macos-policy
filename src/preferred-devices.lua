-- Seleccion de salida/entrada por defecto al estilo macOS.
--
-- Modelo copiado de macOS, leido de /Library/Preferences/Audio/
-- com.apple.audio.SystemSettings.plist: macOS guarda una lista ORDENADA de
-- "preferred devices" por direccion y un "global.arrival" por dispositivo.
-- La regla que reproduce su comportamiento es:
--
--     al LLEGAR un dispositivo pasa al FRENTE de la lista,
--     y gana siempre el primero de la lista que este PRESENTE.
--
-- Eso da a la vez tres cosas que las prioridades de WirePlumber no pueden
-- expresar juntas: que el BT gane al conectarse, que una eleccion manual se
-- respete estando el BT conectado, y que al desconectar caiga a algo
-- predecible en vez de a lo que dicte el puntaje del historial.

log = Log.open_topic ("s-preferred-devices")
cutils = require ("common-utils")

-- Mismas reglas declarativas que lee device/find-preferred-profile, para que
-- el usuario configure esto de forma nativa en vez de tocar el script.
profile_rules = Conf.get_section_as_json ("device.profile.priority.rules", Json.Array {})

state = State ("audio-preferred-devices")
st = state:load ()

-- Dispositivos cuya LLEGADA no debe robar el foco: los sinks RTP de red
-- aparecen y desaparecen solos segun si el desktop responde, y eso no es una
-- accion del usuario. Siguen en la lista (elegibles a mano y como respaldo).
NO_ARRIVAL = { "to%-desktop%-" }

-- Gana a los tres hooks de WirePlumber: el mayor de ellos es el de seleccion
-- manual, con 30000 + prioridad del nodo.
WIN_PRIO = 50000

seen = {}
-- Ultima eleccion manual observada por direccion. Sin esto, el hook nativo
-- find-selected-default-node vuelve a proponerla con 30000 en CADA evento y la
-- re-promoveriamos al frente una y otra vez, pisando la llegada de un
-- dispositivo nuevo. Solo cuenta como eleccion manual cuando CAMBIA.
last_conf = {}

local function is_no_arrival (name)
  for _, pat in ipairs (NO_ARRIVAL) do
    if name:find (pat) then return true end
  end
  return false
end

local function load_list (kind)
  local t, i = {}, 0
  while st[kind .. "." .. i] do
    t[#t + 1] = st[kind .. "." .. i]
    i = i + 1
  end
  return t
end

local function save_list (kind, list)
  local i = 0
  while st[kind .. "." .. i] do st[kind .. "." .. i] = nil; i = i + 1 end
  for j, v in ipairs (list) do st[kind .. "." .. (j - 1)] = v end
  state:save_after_timeout (st)
end

local function to_front (list, name)
  for i, v in ipairs (list) do
    if v == name then table.remove (list, i) break end
  end
  table.insert (list, 1, name)
end

local function contains (list, name)
  for _, v in ipairs (list) do if v == name then return true end end
  return false
end

-- Deshace el mute protector cuando VUELVE el Bluetooth.
--
-- El ajuste device.routes.mute-on-bluetooth-playback-removed mutea todas las
-- salidas al desaparecer el BT y NO desmutea nunca. Su proposito es "te
-- alejaste del equipo y no quiero que suene por las cornetas". Si el BT esta
-- de vuelta, esa condicion ya termino. Si el BT NO vuelve, el mute se queda y
-- la proteccion sigue intacta.
local function set_route_mute (device, route, mute)
  device:set_param ("Route", Pod.Object {
    "Spa:Pod:Object:Param:Route", "Route",
    index = route.index,
    device = route.device,
    props = Pod.Object { "Spa:Pod:Object:Param:Props", "Route", mute = mute },
    save = false,
  })
end

SimpleEventHook {
  name = "preferred-devices/unmute-on-bt-return",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "=", "Audio/Sink" },
      Constraint { "device.api", "=", "bluez5" },
    },
  },
  execute = function (event)
    local om = event:get_source ():call ("get-object-manager", "device")
    if not om then return end
    local n = 0
    for device in om:iterate () do
      for p in device:iterate_params ("Route") do
        local route = cutils.parseParam (p, "Route")
        if route and route.direction == "Output" and route.available ~= "no" then
          set_route_mute (device, route, false)
          n = n + 1
        end
      end
    end
    if n > 0 then
      log:info ("BT de vuelta: deshecho el mute protector en " .. n .. " rutas")
    end
  end
}:register ()

-- Impone el perfil preferido de un dispositivo ANTES de que se restaure el
-- guardado. Hace falta porque WirePlumber sobrescribe el perfil guardado con
-- el que acabe eligiendo (degradando p.ej. de 'a2dp-sink-sbc_xq' a
-- 'a2dp-sink', o sea de SBC-XQ a SBC pelado) y, una vez hay perfil elegido,
-- find-preferred-profile se salta. Corre DESPUES de find-calling-profile y
-- respeta un perfil ya elegido, para no cortar una llamada en curso.
SimpleEventHook {
  name = "preferred-devices/prefer-profile",
  after = { "device/find-calling-profile" },
  before = { "device/find-stored-profile" },
  interests = {
    EventInterest { Constraint { "event.type", "=", "select-profile" } },
  },
  execute = function (event)
    if event:get_data ("selected-profile") then return end  -- llamada en curso

    local device = event:get_subject ()
    local props = JsonUtils.match_rules_update_properties (profile_rules,
                                                           device.properties)
    local p_array = props["priorities"]
    if not p_array then return end

    for _, want in ipairs (Json.Raw (p_array):parse ()) do
      for p in device:iterate_params ("EnumProfile") do
        local dp = cutils.parseParam (p, "EnumProfile")
        if dp and dp.name == want then
          event:set_data ("selected-profile", dp)
          log:info ("perfil preferido impuesto: " .. want)
          return
        end
      end
    end
  end
}:register ()

SimpleEventHook {
  name = "preferred-devices/select",
  -- Despues de los tres hooks nativos, para ver que eligieron y poder
  -- detectar la seleccion manual antes de imponer la nuestra.
  after = { "default-nodes/find-best-default-node",
            "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node" },
  -- IMPRESCINDIBLE: apply-default-node declara el MISMO 'after' que nosotros,
  -- asi que sin esto el orden entre ambos queda indefinido y nuestra decision
  -- puede llegar despues de que ya se aplico la suya.
  before = { "default-nodes/apply-default-node" },
  interests = {
    EventInterest { Constraint { "event.type", "=", "select-default-node" } },
  },
  execute = function (event)
    local props = event:get_properties ()
    local dtype = props["default-node.type"]
    local kind, want_class
    if dtype == "audio.sink" then kind, want_class = "sink", "Audio/Sink"
    elseif dtype == "audio.source" then kind, want_class = "source", "Audio/Source"
    else return end

    local avail = event:get_data ("available-nodes")
    avail = avail and avail:parse ()
    if not avail then return end

    local present, order = {}, {}
    -- OJO: 'available-nodes' trae TODOS los nodos, no solo los de esta
    -- direccion. Los propios scripts de WirePlumber filtran por media.class a
    -- mano; sin esto, la lista de entradas se llena de sinks.
    for _, np in ipairs (avail) do
      local n = np["node.name"]
      if n and np["media.class"] == want_class then
        present[n] = true
        order[#order + 1] = n
      end
    end

    local list = load_list (kind)

    -- Auto-siembra: todo nodo presente que no este en la lista entra al final.
    -- Sin esto la lista arranca vacia y el componente no elige nunca nada.
    -- El orden inicial lo pone la seleccion vigente, mas abajo.
    for _, n in ipairs (order) do
      if not contains (list, n) then list[#list + 1] = n end
    end

    -- 1. Llegadas -> al frente. En el primer evento no se considera llegada
    --    nada (no hay con que comparar). Si aparece MAS DE UNO a la vez es un
    --    evento del grafo (un reinicio hace reaparecer todo), no una accion
    --    del usuario: entran a la lista pero al final, sin promover.
    local prev = seen[kind]
    if prev then
      local arrivals = {}
      for _, n in ipairs (order) do
        if not prev[n] then arrivals[#arrivals + 1] = n end
      end
      if #arrivals > 1 then
        for _, n in ipairs (arrivals) do
          if not contains (list, n) then list[#list + 1] = n end
        end
      else
        for _, n in ipairs (arrivals) do
          if is_no_arrival (n) then
            if not contains (list, n) then list[#list + 1] = n end
          else
            to_front (list, n)
            log:info ("llego " .. n .. " -> al frente")
          end
        end
      end
    end
    seen[kind] = present

    -- 2. Eleccion manual -> al frente. El hook nativo find-selected-default-node
    --    ya la habra puesto con prioridad >= 30000; eso es la señal.
    local sel = event:get_data ("selected-node")
    local sel_prio = event:get_data ("selected-node-priority") or 0
    if sel and sel_prio >= 30000 and present[sel] then
      if last_conf[kind] ~= sel then
        to_front (list, sel)
        last_conf[kind] = sel
        log:info ("elegido a mano " .. sel .. " -> al frente")
      end
    end

    -- 3. Gana el primero de la lista que este presente.
    local win
    for _, n in ipairs (list) do
      if present[n] then win = n break end
    end
    if win then
      event:set_data ("selected-node-priority", WIN_PRIO)
      event:set_data ("selected-node", win)

      -- Mantener 'default.configured' en sincronia con el ganador. Sin esto,
      -- si eliges a mano el mismo dispositivo que ya figuraba configurado, el
      -- metadata no cambia, no se emite evento, y tu clic no hace nada.
      -- Escribiendolo, cualquier eleccion tuya produce un cambio real que si
      -- podemos detectar. No hay bucle: al reentrar, last_conf ya coincide.
      if sel ~= win then
        local mom = event:get_source ():call ("get-object-manager", "metadata")
        local md = mom and mom:lookup { Constraint { "metadata.name", "=", "default" } }
        if md then
          md:set (0, "default.configured." .. dtype, "Spa:String:JSON",
                  Json.Object { name = win }:to_string ())
          last_conf[kind] = win
        end
      end
    end
    log:info ("" .. kind .. " -> " .. tostring (win))

    save_list (kind, list)
  end
}:register ()

log:info ("componente preferred-devices cargado")
