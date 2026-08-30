-- macOS-style default audio device selection for WirePlumber.
--
-- The model is taken from macOS itself, read out of
-- /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist: macOS keeps
-- an ORDERED "preferred devices" list per direction, plus a "global.arrival"
-- {seed,time} per device and a global arrival counter. The rule that
-- reproduces its behaviour is:
--
--     an ARRIVING device moves to the FRONT of the list,
--     and the first device in the list that is PRESENT wins.
--
-- That expresses three things at once which WirePlumber's priorities cannot:
-- headphones win when you plug them in, a manual choice is respected while
-- they stay connected, and unplugging falls back to something predictable
-- instead of whatever the stored-history score happens to pick.

log = Log.open_topic ("s-preferred-devices")
cutils = require ("common-utils")
futils = require ("filter-utils")

state = State ("audio-preferred-devices")
st = state:load ()

-- Same declarative rules that device/find-preferred-profile reads, so profile
-- preferences are configured natively instead of by editing this script.
profile_rules = Conf.get_section_as_json ("device.profile.priority.rules", Json.Array {})

-- Lua patterns matched against node.name. A device whose arrival matches is
-- NOT moved to the front: it still takes part in the list (selectable by hand,
-- usable as a fallback), it just does not steal focus when it shows up.
--
-- This is for nodes that come and go on their own rather than because someone
-- did something: network sinks that track a remote host's reachability,
-- virtual monitors, loopbacks. Empty by default.
no_arrival = Conf.get_section_as_json ("preferred-devices.no-arrival", Json.Array {}):parse ()

-- Beats WirePlumber's three native hooks; the highest of those is the manual
-- selection one, at 30000 + the node's own priority.
WIN_PRIO = 50000

-- Media classes that count for each direction. These mirror what
-- default-nodes/rescan actually collects: 'available-nodes' carries every node
-- for BOTH directions, so each hook filters for itself. Matching only
-- "Audio/Sink"/"Audio/Source" would silently make duplex devices and virtual
-- sources unselectable. Audio/Sink is deliberately absent from the source set:
-- upstream skips it there too.
SINK_CLASSES   = { ["Audio/Sink"] = true, ["Audio/Duplex"] = true }
SOURCE_CLASSES = { ["Audio/Source"] = true, ["Audio/Source/Virtual"] = true,
                   ["Audio/Duplex"] = true }

-- How many devices are remembered per direction.
MAX_REMEMBERED = 32

-- Node names present at the previous event, per direction. Used to tell an
-- arrival from a device that was already there.
seen = {}

-- Last manual selection observed, per direction. Without this, the native
-- find-selected-default-node hook re-proposes it at 30000 on EVERY event and
-- we would keep promoting it to the front, overriding a device that just
-- arrived. It only counts as a manual choice when it CHANGES.
last_conf = {}

-- Last value written to default.configured per direction. Without this, a
-- write that never takes effect would be retried on every event, and every
-- retry would emit another event: an infinite loop.
wrote = {}

local function is_no_arrival (name)
  for _, pat in ipairs (no_arrival) do
    if name:find (pat) then return true end
  end
  return false
end

-- Does not stop at the first hole. The state file is meant to be hand-edited,
-- and a hole (say sink.0 and sink.2 with no sink.1) would SILENTLY drop
-- everything after it, including devices that are simply not connected right
-- now. All indices are collected and compacted.
local function load_list (kind)
  local idx = {}
  for k, v in pairs (st) do
    local n = k:match ("^" .. kind .. "%.(%d+)$")
    if n then idx[#idx + 1] = { tonumber (n), v } end
  end
  table.sort (idx, function (a, b) return a[1] < b[1] end)
  -- Deduplicated here: the list must NEVER hold repeats. A duplicate added by
  -- hand would survive to_front (which only looks at position) and pile up on
  -- every promotion.
  local out, taken = {}, {}
  for _, e in ipairs (idx) do
    if not taken[e[2]] then
      taken[e[2]] = true
      out[#out + 1] = e[2]
    end
  end
  return out
end

local function save_list (kind, list)
  for k in pairs (st) do
    if k:match ("^" .. kind .. "%.%d+$") then st[k] = nil end
  end
  for j, v in ipairs (list) do st[kind .. "." .. (j - 1)] = v end
  state:save_after_timeout (st)
end

-- Removes EVERY occurrence, not just the first: the state is hand-editable and
-- a duplicate would otherwise stay forever, accumulating on each promotion.
local function to_front (list, name)
  for i = #list, 1, -1 do
    if list[i] == name then table.remove (list, i) end
  end
  table.insert (list, 1, name)
end

local function contains (list, name)
  for _, v in ipairs (list) do if v == name then return true end end
  return false
end

-- The list only ever grows: every device seen is remembered forever. Bound it
-- by dropping the oldest entries that are NOT present, so something currently
-- in use is never forgotten.
local function trim (list, present)
  for i = #list, 1, -1 do
    if #list <= MAX_REMEMBERED then break end
    if not present[list[i]] then table.remove (list, i) end
  end
end

--------------------------------------------------------------------------
-- Undo the protective mute when Bluetooth comes back.
--
-- device.routes.mute-on-bluetooth-playback-removed mutes every output when the
-- Bluetooth device goes away, and never unmutes. Its purpose is "you walked
-- away, I do not want sound coming out of the speakers". If Bluetooth is back,
-- that condition is over. If it does not come back the mute stays, so the
-- protection is intact.
--------------------------------------------------------------------------
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
      -- Only ALSA devices: that is exactly what device/mute-alsa-devices
      -- muted. Undoing more than was done would clear a mute the user set by
      -- hand on some other device.
      if device.properties["device.api"] == "alsa" then
      for p in device:iterate_params ("Route") do
        local route = cutils.parseParam (p, "Route")
        if route and route.direction == "Output" and route.available ~= "no" then
          set_route_mute (device, route, false)
          n = n + 1
        end
      end
      end
    end
    if n > 0 then
      log:info ("bluetooth back: undid the protective mute on " .. n .. " routes")
    end
  end
}:register ()

--------------------------------------------------------------------------
-- Impose the preferred device profile BEFORE the stored one is restored.
--
-- Needed because WirePlumber overwrites the stored profile with whatever it
-- ends up choosing (degrading e.g. a2dp-sink-sbc_xq to a2dp-sink, that is
-- SBC-XQ down to plain SBC), and once a profile is selected
-- device/find-preferred-profile skips itself. Runs AFTER
-- device/find-calling-profile and respects an already selected profile, so an
-- ongoing call is never cut off.
--------------------------------------------------------------------------
SimpleEventHook {
  name = "preferred-devices/prefer-profile",
  after = { "device/find-calling-profile" },
  before = { "device/find-stored-profile" },
  interests = {
    EventInterest { Constraint { "event.type", "=", "select-profile" } },
  },
  execute = function (event)
    if event:get_data ("selected-profile") then return end  -- call in progress

    local device = event:get_subject ()
    local props = JsonUtils.match_rules_update_properties (profile_rules,
                                                           device.properties)
    local wanted = props["priorities"]
    if not wanted then return end

    for _, want in ipairs (Json.Raw (wanted):parse ()) do
      for p in device:iterate_params ("EnumProfile") do
        local profile = cutils.parseParam (p, "EnumProfile")
        -- available ~= "no": imposing a profile the device reports as
        -- unavailable leaves it with no working route.
        if profile and profile.name == want and profile.available ~= "no" then
          event:set_data ("selected-profile", profile)
          log:info ("imposed preferred profile: " .. want)
          return
        end
      end
    end
  end
}:register ()

--------------------------------------------------------------------------
-- Pick the default node: first device in the preferred list that is present.
--------------------------------------------------------------------------
SimpleEventHook {
  name = "preferred-devices/select",
  -- After the three native hooks, so we can see what they chose and detect a
  -- manual selection before imposing ours.
  after = { "default-nodes/find-best-default-node",
            "default-nodes/find-selected-default-node",
            "default-nodes/find-stored-default-node" },
  -- ESSENTIAL: apply-default-node declares the SAME 'after' list we do, so
  -- without this the order between the two is undefined and our decision can
  -- land after theirs has already been applied.
  before = { "default-nodes/apply-default-node" },
  interests = {
    EventInterest { Constraint { "event.type", "=", "select-default-node" } },
  },
  execute = function (event)
    local dtype = event:get_properties ()["default-node.type"]
    local kind, want_class
    if dtype == "audio.sink" then kind, want_class = "sink", SINK_CLASSES
    elseif dtype == "audio.source" then kind, want_class = "source", SOURCE_CLASSES
    else return end

    local avail = event:get_data ("available-nodes")
    avail = avail and avail:parse ()
    if not avail then return end

    -- NOTE: 'available-nodes' carries EVERY node, not just the ones for this
    -- direction. WirePlumber's own scripts filter by media.class by hand;
    -- without this the source list fills up with sinks.
    local present, order = {}, {}
    for _, np in ipairs (avail) do
      local n = np["node.name"]
      if n and want_class[np["media.class"]] then
        -- Smart filters (echo-cancel, filter chains) present as nodes but must
        -- never become the default: upstream's find-best-default-node skips
        -- them for the same reason. The direction mapping is theirs.
        local link_group = np["node.link-group"]
        local smart = false
        if link_group then
          local direction = (kind == "source") and "output" or "input"
          smart = futils.is_filter_smart (direction, link_group)
        end
        if not smart then
          present[n] = true
          order[#order + 1] = n
        end
      end
    end

    local list = load_list (kind)

    -- Seed: any present node missing from the list joins it at the end.
    -- Without this the list starts empty and the component never picks
    -- anything, silently. The initial order comes from the current selection,
    -- handled further down.
    for _, n in ipairs (order) do
      if not contains (list, n) then list[#list + 1] = n end
    end

    -- 1. Arrivals move to the front. Nothing counts as an arrival on the first
    --    event, there is nothing to compare against. If MORE THAN ONE shows up
    --    at once it is a graph event (a restart makes everything reappear) and
    --    not a user action: they join the list but at the end, unpromoted.
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
            log:info ("arrived: " .. n .. " -> front")
          end
        end
      end
    end
    seen[kind] = present

    -- 2. A manual choice moves to the front. The native
    --    find-selected-default-node hook will have set it at >= 30000; that is
    --    the signal.
    local sel = event:get_data ("selected-node")
    local sel_prio = event:get_data ("selected-node-priority") or 0
    if sel and sel_prio >= 30000 and present[sel] and last_conf[kind] ~= sel then
      to_front (list, sel)
      last_conf[kind] = sel
      log:info ("chosen by hand: " .. sel .. " -> front")
    end

    -- 3. The first device in the list that is present wins.
    local win
    for _, n in ipairs (list) do
      if present[n] then win = n break end
    end

    if win then
      event:set_data ("selected-node-priority", WIN_PRIO)
      event:set_data ("selected-node", win)

      -- Keep default.configured in sync with the winner. Without this, picking
      -- by hand the device that was already configured changes no metadata,
      -- emits no event, and the click does nothing.
      if sel ~= win and wrote[kind] ~= win then
        local mom = event:get_source ():call ("get-object-manager", "metadata")
        local md = mom and mom:lookup { Constraint { "metadata.name", "=", "default" } }
        if md then
          md:set (0, "default.configured." .. dtype, "Spa:String:JSON",
                  Json.Object { name = win }:to_string ())
          last_conf[kind] = win
          wrote[kind] = win
        end
      end
    end

    trim (list, present)
    save_list (kind, list)
  end
}:register ()

log:info ("preferred-devices component loaded")
