-- Configurable WirePlumber test double.
--
-- WirePlumber injects its globals (Log, State, Json, SimpleEventHook, ...)
-- into the component's Lua sandbox. This module implements them with values
-- EACH TEST configures, so the component's real logic can run without
-- WirePlumber and we can assert on exactly what it did.
--
--   local wp = Fake.new { state = {...}, no_arrival = {...} }
--   local c  = wp:load ("src/preferred-devices.lua")
--   local ev = wp:select_event { kind = "audio.sink", nodes = {...} }
--   c:run ("preferred-devices/select", ev)
--   assert (ev:selected () == "headset")

local Fake = {}
Fake.__index = Fake

--- spec:
---   state          initial flat table behind State() (the preferred list)
---   profile_rules  what match_rules_update_properties returns
---   no_arrival     patterns for the preferred-devices.no-arrival section
---   smart_filters  { [link_group] = true } for is_filter_smart
---   devices        device doubles for the "device" object manager
---   metadata       initial default.configured.* values
function Fake.new (spec)
  local self = setmetatable ({}, Fake)
  spec = spec or {}
  self.state = spec.state or {}
  self.profile_rules = spec.profile_rules
  self.no_arrival = spec.no_arrival or {}
  self.smart_filters = spec.smart_filters or {}
  self.devices = spec.devices or {}
  self.metadata = spec.metadata or {}
  self.logs = {}
  self.hooks = {}
  self.route_mutes = {}   -- what the component applied, for assertions
  return self
end

local function parseable (v)
  return { parse = function () return v end }
end

function Fake:_install ()
  local this = self
  local function sink (_, m) table.insert (this.logs, tostring (m)) end

  Log = { open_topic = function ()
    return { info = sink, warning = sink, debug = function () end }
  end }

  State = function ()
    return {
      load = function () return this.state end,
      -- The component saves with save_after_timeout; immediate here so a test
      -- can inspect the result without waiting.
      save_after_timeout = function (_, t) this.state = t end,
    }
  end

  Conf = { get_section_as_json = function (name, default)
    if name == "preferred-devices.no-arrival" then
      return parseable (this.no_arrival)
    end
    return default
  end }

  Json = {
    Array  = function (t) return parseable (t or {}) end,
    Object = function (t) return { to_string = function () return t end } end,
    Raw    = parseable,
  }

  JsonUtils = { match_rules_update_properties = function ()
    return this.profile_rules or {}
  end }

  Pod = { Object = function (t) return t end }
  package.loaded["common-utils"] = { parseParam = function (p) return p end }
  package.loaded["filter-utils"] = { is_filter_smart = function (_, link_group)
    return this.smart_filters[link_group] == true
  end }

  Constraint = function (t) return t end
  EventInterest = function (t) return t end
  SimpleEventHook = function (def)
    def.register = function (d) this.hooks[d.name] = d; return d end
    return def
  end
end

--- Loads the component with the globals already injected.
function Fake:load (path)
  self:_install ()
  dofile (path)
  local hooks = self.hooks
  return {
    run = function (_, name, event)
      local h = hooks[name] or error ("hook not registered: " .. name)
      return h.execute (event)
    end,
    names = function ()
      local t = {}
      for k in pairs (hooks) do t[#t + 1] = k end
      table.sort (t)
      return t
    end,
  }
end

--- A select-default-node event.
--- spec: kind, nodes = {{name=, class=}}, selected, priority
function Fake:select_event (spec)
  local this = self
  local avail = {}
  for _, n in ipairs (spec.nodes or {}) do
    table.insert (avail, { ["node.name"] = n.name, ["media.class"] = n.class,
                           ["node.link-group"] = n.link_group })
  end
  local data = {
    ["available-nodes"] = parseable (avail),
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
          set = function (_, _, key, _, val) this.metadata[key] = val end,
        } end }
      elseif which == "device" then
        return { iterate = function ()
          local i = 0
          return function () i = i + 1; return this.devices[i] end
        end }
      end
    end } end,
    selected  = function () return data["selected-node"] end,
    priority  = function () return data["selected-node-priority"] end,
  }
end

--- A select-profile event.
--- spec: device_props, profiles = {names}, selected, unavailable = {[name]=true}
function Fake:profile_event (spec)
  local data = { ["selected-profile"] = spec.selected }
  local profiles = {}
  local unavailable = spec.unavailable or {}
  for _, name in ipairs (spec.profiles or {}) do
    table.insert (profiles, { name = name, index = #profiles + 1,
                              available = unavailable[name] and "no" or "yes" })
  end
  -- Profiles the device knows about but reports as unavailable still show up
  -- in EnumProfile; that is exactly the case worth testing.
  for name in pairs (unavailable) do
    table.insert (profiles, { name = name, index = #profiles + 1, available = "no" })
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

--- A node-added event, for the unmute hook.
function Fake:node_added_event ()
  return self:select_event { kind = "audio.sink", nodes = {} }
end

--- A device double with routes, to assert on unmuting.
function Fake:device (routes)
  local this = self
  return {
    properties = {},
    iterate_params = function ()
      local i = 0
      return function () i = i + 1; return routes[i] end
    end,
    set_param = function (_, _, param)
      table.insert (this.route_mutes, { index = param.index, mute = param.props.mute })
    end,
  }
end

--- The ordered preferred list as it ended up in the state.
function Fake:preferred (kind)
  local t, i = {}, 0
  while self.state[kind .. "." .. i] do
    t[#t + 1] = self.state[kind .. "." .. i]
    i = i + 1
  end
  return t
end

return Fake
