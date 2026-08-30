-- Tests for the component's logic, using the configurable double.
-- Each test builds its own Fake with the values it needs, loads the real
-- component and asserts on what it did.

local HERE = arg[0]:match ("(.*)/") or "."
local Fake = dofile (HERE .. "/fake-wireplumber.lua")
local SRC  = HERE .. "/../src/preferred-devices.lua"

local SINK, SOURCE = "Audio/Sink", "Audio/Source"
local pass, fail = 0, 0

local function check (name, got, want)
  if got == want then
    pass = pass + 1
    print (string.format ("  ok    %s", name))
  else
    fail = fail + 1
    print (string.format ("  FAIL  %s\n          want: %s\n          got:  %s",
                          name, tostring (want), tostring (got)))
  end
end

local function sinks (...)
  local t = {}
  for _, n in ipairs {...} do table.insert (t, { name = n, class = SINK }) end
  return t
end

local function select (comp, wp, spec)
  local ev = wp:select_event (spec)
  comp:run ("preferred-devices/select", ev)
  return ev
end

local function count (list, name)
  local n = 0
  for _, v in ipairs (list) do if v == name then n = n + 1 end end
  return n
end

--------------------------------------------------------------------------
print ("a device arrives")
do
  local wp = Fake.new { state = { ["sink.0"] = "speakers" } }
  local c = wp:load (SRC)
  -- first event only takes the initial snapshot; nothing counts as an arrival
  select (c, wp, { kind = "audio.sink", nodes = sinks ("speakers") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("speakers", "headset") })
  check ("the arriving device wins", ev:selected (), "headset")
  check ("and lands at the front of the list", wp:preferred ("sink")[1], "headset")
end

--------------------------------------------------------------------------
print ("manual choice while the headset is connected")
do
  local wp = Fake.new { state = { ["sink.0"] = "headset", ["sink.1"] = "dock" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("headset", "dock") })
  -- the native hook already picked "dock" with the manual-selection bonus
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("headset", "dock"),
                              selected = "dock", priority = 30900 })
  check ("the manual choice beats the headset", ev:selected (), "dock")
  check ("and moves to the front", wp:preferred ("sink")[1], "dock")
end

--------------------------------------------------------------------------
print ("disconnect")
do
  local wp = Fake.new { state = { ["sink.0"] = "headset", ["sink.1"] = "dock",
                                  ["sink.2"] = "speakers" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("headset", "dock", "speakers") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("dock", "speakers") })
  check ("falls back to the next present entry, in list order", ev:selected (), "dock")
end

--------------------------------------------------------------------------
print ("reconnect")
do
  local wp = Fake.new { state = { ["sink.0"] = "dock", ["sink.1"] = "headset" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("dock") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("dock", "headset") })
  check ("wins again on reconnect", ev:selected (), "headset")
end

--------------------------------------------------------------------------
print ("devices that must not steal focus (no-arrival patterns)")
do
  local wp = Fake.new { state = { ["sink.0"] = "headset" },
                        no_arrival = { "^network%-" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("headset") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("headset", "network-sink") })
  check ("a matching device does not steal focus", ev:selected (), "headset")
  check ("but still joins the list", count (wp:preferred ("sink"), "network-sink"), 1)
end

--------------------------------------------------------------------------
print ("graph restart (several nodes reappear at once)")
do
  local wp = Fake.new { state = { ["sink.0"] = "headset" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("headset") })
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("headset", "hdmi1", "hdmi2") })
  check ("multiple arrivals do not reorder", ev:selected (), "headset")
  check ("and do not jump to the front", wp:preferred ("sink")[1], "headset")
end

--------------------------------------------------------------------------
print ("direction filtering")
do
  local wp = Fake.new {}
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.source", nodes = {
    { name = "a-sink", class = SINK },
    { name = "a-mic",  class = SOURCE },
  } }
  c:run ("preferred-devices/select", ev)
  check ("a source event ignores sinks", ev:selected (), "a-mic")
end

do
  -- rescan collects Audio/Duplex for both directions and
  -- Audio/Source/Virtual for sources. Matching only the plain classes would
  -- make those devices permanently unselectable.
  local wp = Fake.new {}
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.sink", nodes = {
    { name = "duplex-card", class = "Audio/Duplex" },
  } }
  c:run ("preferred-devices/select", ev)
  check ("a duplex device can be the default sink", ev:selected (), "duplex-card")
end

do
  local wp = Fake.new {}
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.source", nodes = {
    { name = "virtual-mic", class = "Audio/Source/Virtual" },
  } }
  c:run ("preferred-devices/select", ev)
  check ("a virtual source can be the default source", ev:selected (), "virtual-mic")
end

--------------------------------------------------------------------------
print ("smart filters")
do
  -- Echo-cancel and filter chains show up as nodes but must never become the
  -- default; upstream's find-best-default-node skips them too.
  local wp = Fake.new { smart_filters = { ["echo-cancel"] = true } }
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.sink", nodes = {
    { name = "filter", class = SINK, link_group = "echo-cancel" },
    { name = "speakers", class = SINK },
  } }
  c:run ("preferred-devices/select", ev)
  check ("a smart filter is never chosen", ev:selected (), "speakers")
  check ("and does not enter the list", count (wp:preferred ("sink"), "filter"), 0)
end

do
  -- A node with a link-group that is NOT a registered smart filter is fine.
  -- The Bluetooth microphone loopback is exactly this case.
  local wp = Fake.new {}
  local c = wp:load (SRC)
  local ev = wp:select_event { kind = "audio.source", nodes = {
    { name = "bt-mic", class = SOURCE, link_group = "loopback-1" },
  } }
  c:run ("preferred-devices/select", ev)
  check ("a plain loopback is still selectable", ev:selected (), "bt-mic")
end

--------------------------------------------------------------------------
print ("preferred profile")
do
  local wp = Fake.new { profile_rules = { priorities = { "a2dp-sink-sbc_xq", "a2dp-sink" } } }
  local c = wp:load (SRC)
  local ev = wp:profile_event {
    device_props = { ["device.api"] = "bluez5" },
    profiles = { "a2dp-sink", "a2dp-sink-sbc_xq", "headset-head-unit" },
  }
  c:run ("preferred-devices/prefer-profile", ev)
  check ("picks the best available profile", ev:selected (), "a2dp-sink-sbc_xq")
end

do
  -- Imposing a profile the device reports as unavailable leaves it with no
  -- working route.
  local wp = Fake.new { profile_rules = { priorities = { "a2dp-sink-sbc_xq", "a2dp-sink" } } }
  local c = wp:load (SRC)
  local ev = wp:profile_event {
    device_props = { ["device.api"] = "bluez5" },
    profiles = { "a2dp-sink" },
    unavailable = { ["a2dp-sink-sbc_xq"] = true },
  }
  c:run ("preferred-devices/prefer-profile", ev)
  check ("skips an unavailable profile", ev:selected (), "a2dp-sink")
end

do
  local wp = Fake.new { profile_rules = { priorities = { "a2dp-sink-sbc_xq" } } }
  local c = wp:load (SRC)
  local ev = wp:profile_event {
    device_props = { ["device.api"] = "bluez5" },
    profiles = { "a2dp-sink-sbc_xq", "headset-head-unit" },
    selected = { name = "headset-head-unit" },   -- call in progress
  }
  c:run ("preferred-devices/prefer-profile", ev)
  check ("does not override an ongoing call", ev:selected (), "headset-head-unit")
end

--------------------------------------------------------------------------
print ("unmute when bluetooth returns")
do
  local wp = Fake.new {}
  wp.devices = { wp:device {
    { index = 7, device = 0, direction = "Output", available = "yes" },
    { index = 8, device = 0, direction = "Input",  available = "yes" },
  } }
  local c = wp:load (SRC)
  c:run ("preferred-devices/unmute-on-bt-return", wp:node_added_event ())
  check ("unmutes the output route", wp.route_mutes[1] and wp.route_mutes[1].index, 7)
  check ("with mute = false", wp.route_mutes[1] and wp.route_mutes[1].mute, false)
  check ("and leaves the input route alone", #wp.route_mutes, 1)
end

do
  -- device/mute-alsa-devices only mutes ALSA devices, so undoing more than
  -- that would clear a mute the user set by hand elsewhere.
  local wp = Fake.new {}
  wp.devices = {
    wp:device ({ { index = 1, device = 0, direction = "Output", available = "yes" } }, "bluez5"),
    wp:device ({ { index = 2, device = 0, direction = "Output", available = "yes" } }, "alsa"),
  }
  local c = wp:load (SRC)
  c:run ("preferred-devices/unmute-on-bt-return", wp:node_added_event ())
  check ("only touches ALSA devices", #wp.route_mutes, 1)
  check ("and it is the ALSA one", wp.route_mutes[1] and wp.route_mutes[1].index, 2)
end

--------------------------------------------------------------------------
-- Regressions. The state file is documented as hand-editable, so it has to
-- survive being edited badly.
--------------------------------------------------------------------------
print ("regression: hole in a hand-edited state")
do
  -- sink.0 and sink.2 with no sink.1. "saved-headset" is not connected now.
  local wp = Fake.new { state = { ["sink.0"] = "speakers", ["sink.2"] = "saved-headset" } }
  local c = wp:load (SRC)
  local ev = select (c, wp, { kind = "audio.sink", nodes = sinks ("speakers") })
  check ("keeps the entry after the hole", count (wp:preferred ("sink"), "saved-headset"), 1)
  check ("and still picks correctly", ev:selected (), "speakers")
end

print ("regression: the stored order is respected")
do
  -- pairs() has no defined order in Lua, so the indices must be sorted
  -- explicitly. With enough entries an unsorted load comes out scrambled.
  local st, names = {}, {}
  for i = 0, 7 do
    st["sink." .. i] = "dev" .. i
    names[#names + 1] = "dev" .. i
  end
  local wp = Fake.new { state = st }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks (table.unpack (names)) })
  check ("loads in index order", table.concat (wp:preferred ("sink"), ","),
         table.concat (names, ","))
end

print ("regression: duplicates in the state")
do
  local wp = Fake.new { state = { ["sink.0"] = "a", ["sink.1"] = "b", ["sink.2"] = "a" } }
  local c = wp:load (SRC)
  select (c, wp, { kind = "audio.sink", nodes = sinks ("a", "b") })
  check ("leaves no duplicates", count (wp:preferred ("sink"), "a"), 1)
end

print ("regression: the list is bounded")
do
  local wp = Fake.new {}
  local c = wp:load (SRC)
  for i = 1, 60 do
    select (c, wp, { kind = "audio.sink", nodes = sinks ("dev" .. i) })
  end
  local l = wp:preferred ("sink")
  check ("history is capped", #l <= 32, true)
  check ("and the present device is never dropped", count (l, "dev60"), 1)
end

--------------------------------------------------------------------------
print ()
print (string.format ("%d tests, %d failures", pass + fail, fail))
os.exit (fail == 0 and 0 or 1)
