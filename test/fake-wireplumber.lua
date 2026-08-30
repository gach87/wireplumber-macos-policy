-- Doble configurable de WirePlumber.
--
-- WirePlumber inyecta sus globales (Log, State, Json, SimpleEventHook...) en
-- el sandbox Lua del componente. Este modulo los implementa con valores que
-- CADA PRUEBA configura, para poder ejecutar la logica real del componente sin
-- WirePlumber corriendo y validar exactamente lo que hizo.
--
-- Uso:
--   local wp = Fake.new { state = {...}, profile_rules = {...} }
--   local c  = wp:load ("src/preferred-devices.lua")
--   local ev = wp:select_event { kind = "audio.sink", nodes = {...} }
--   c:run ("preferred-devices/select", ev)
--   assert (ev:selected () == "loquesea")

local Fake = {}
Fake.__index = Fake

--- spec:
---   state          tabla plana inicial de State() (la lista de preferidos)
---   profile_rules  lo que devuelve match_rules_update_properties
---   devices        lista de dobles de dispositivo para el object-manager
---   metadata       valores iniciales de default.configured.*
function Fake.new (spec)
  local self = setmetatable ({}, Fake)
  spec = spec or {}
  self.state = spec.state or {}
  self.profile_rules = spec.profile_rules
  self.devices = spec.devices or {}
  self.metadata = spec.metadata or {}
  self.logs = {}
  self.hooks = {}
  self.route_mutes = {}   -- {device, route, mute} que el componente aplico
  return self
end

function Fake:_install ()
  local self_ = self
  local function sink (_, m) table.insert (self_.logs, tostring (m)) end

  Log = { open_topic = function ()
    return { info = sink, warning = sink, debug = function () end }
  end }

  State = function ()
    return {
      load = function () return self_.state end,
      -- El componente guarda con save_after_timeout; aqui es inmediato para
      -- que la prueba pueda inspeccionar el resultado sin esperas.
      save_after_timeout = function (_, t) self_.state = t end,
    }
  end

  Conf = { get_section_as_json = function (_, default) return default end }

  Json = {
    Array  = function (t) return t or {} end,
    Object = function (t) return { to_string = function () return t end } end,
    Raw    = function (v) return { parse = function () return v end } end,
  }

  -- Devuelve lo que la prueba configuro como reglas de perfil.
  JsonUtils = { match_rules_update_properties = function ()
    return self_.profile_rules or {}
  end }

  Pod = { Object = function (t) return t end }
  package.loaded["common-utils"] = { parseParam = function (p) return p end }

  Constraint = function (t) return t end
  EventInterest = function (t) return t end
  SimpleEventHook = function (def)
    def.register = function (d) self_.hooks[d.name] = d; return d end
    return def
  end
end

--- Carga el componente con los globales ya inyectados.
function Fake:load (path)
  self:_install ()
  dofile (path)
  local hooks = self.hooks
  return {
    run = function (_, name, event)
      local h = hooks[name] or error ("hook no registrado: " .. name)
      return h.execute (event)
    end,
    names = function () local t = {} for k in pairs (hooks) do t[#t+1] = k end return t end,
  }
end

--- Evento de select-default-node.
--- spec: kind, nodes = {{name=, class=}}, selected, priority
function Fake:select_event (spec)
  local self_ = self
  local avail = {}
  for _, n in ipairs (spec.nodes or {}) do
    table.insert (avail, { ["node.name"] = n.name, ["media.class"] = n.class })
  end
  local data = {
    ["available-nodes"] = { parse = function () return avail end },
    ["selected-node"] = spec.selected,
    ["selected-node-priority"] = spec.priority,
  }
  return {
    get_properties = function () return { ["default-node.type"] = spec.kind } end,
    get_data = function (_, k) return data[k] end,
    set_data = function (_, k, v) data[k] = v end,
    get_source = function () return { call = function (_, _, which)
      if which == "metadata" then
        return { lookup = function () return {
          set = function (_, _, key, _, val) self_.metadata[key] = val end,
        } end }
      elseif which == "device" then
        return { iterate = function ()
          local i = 0
          return function () i = i + 1; return self_.devices[i] end
        end }
      end
    end } end,
    selected = function () return data["selected-node"] end,
    priority = function () return data["selected-node-priority"] end,
  }
end

--- Evento de select-profile.
--- spec: device_props, profiles = {nombres}, selected
function Fake:profile_event (spec)
  local data = { ["selected-profile"] = spec.selected }
  local profiles = {}
  for _, name in ipairs (spec.profiles or {}) do
    table.insert (profiles, { name = name, index = #profiles + 1 })
  end
  return {
    get_data = function (_, k) return data[k] end,
    set_data = function (_, k, v) data[k] = v end,
    get_subject = function () return {
      properties = spec.device_props or {},
      iterate_params = function ()
        local i = 0
        return function () i = i + 1; return profiles[i] end
      end,
    } end,
    selected = function ()
      local p = data["selected-profile"]
      return p and p.name or nil
    end,
  }
end

--- Evento de node-added (para el hook de desmuteo).
function Fake:node_added_event ()
  return self:select_event { kind = "audio.sink", nodes = {} }
end

--- Doble de dispositivo con rutas, para validar el desmuteo.
function Fake:device (routes)
  local self_ = self
  local d = { properties = {} }
  d.iterate_params = function ()
    local i = 0
    return function () i = i + 1; return routes[i] end
  end
  d.set_param = function (_, _, param)
    table.insert (self_.route_mutes, { index = param.index, mute = param.props.mute })
  end
  return d
end

--- Lista ordenada de preferidos tal como quedo en el estado.
function Fake:preferred (kind)
  local t, i = {}, 0
  while self.state[kind .. "." .. i] do
    t[#t + 1] = self.state[kind .. "." .. i]
    i = i + 1
  end
  return t
end

return Fake
