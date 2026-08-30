# wireplumber-macos-policy

[![CI](https://github.com/gach87/wireplumber-macos-policy/actions/workflows/ci.yml/badge.svg)](https://github.com/gach87/wireplumber-macos-policy/actions/workflows/ci.yml)

macOS-style audio device selection for WirePlumber 0.5+, as a native component.

Plug in headphones and the audio follows them. Pick another output by hand and
that is respected. Unplug and you land back on what you were using before. All
three at once.

## The problem

WirePlumber picks the default sink by scoring every node with three hooks. The
largest bonus, **+30000**, goes to the last device you selected by hand. That
makes these two mutually exclusive:

- Bluetooth wins when it connects → needs a priority above 30000
- You can still pick another output by hand while it is connected → needs below

This is not a missing setting. Both situations — "I chose the speakers before
connecting" and "I chose them after" — produce **exactly the same state**, and
WirePlumber has no notion of "just arrived" to tell them apart.

## The macOS model

macOS does solve it, and not with priorities. Reading
`/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist` shows a
`preferred devices` key holding an **ordered** list per direction, plus a
`global.arrival` `{seed,time}` per device and a global arrival counter:

```
"preferred devices" => {
  "output" => [ { "uid" => "AppleUSBAudioEngine:...:1,2" },
                { "uid" => "BuiltInSpeakerDevice" } ]
}
"device.AppleUSBAudioEngine:...:1,2" => {
  "global.arrival" => { "seed" => 39, "time" => 40200000000 }
}
"seed" => 74
```

The rule that reproduces its behaviour:

> **An arriving device moves to the front of the list.
> The first device in the list that is present wins.**

An ordered list expresses all three behaviours without contradiction, because
an arrival and a manual choice are both "move to front", and unplugging is
simply "next one present".

## What it does

- **Arrival moves to the front.** Plug something in and it wins, with no
  configuration. Works with devices it has never seen before.
- **A manual choice moves to the front.** Respected and remembered.
- **On disconnect it falls to the next present device**, in list order — not to
  whatever the stored-history score happens to rank highest.
- **Prefers the best available device profile** (for example SBC-XQ over plain
  SBC), even when WirePlumber has already stored a degraded one.
- **Undoes the protective mute when Bluetooth returns.**
  `mute-on-bluetooth-playback-removed` mutes everything when Bluetooth goes
  away and never unmutes; if Bluetooth is back, that condition is over.

It runs **inside the WirePlumber process**: no extra processes, no polling.

## Install

Download the `.zip` or `.tar.gz` from the
[latest release](https://github.com/gach87/wireplumber-macos-policy/releases),
unpack, and:

```sh
./install.sh
```

Or from source:

```sh
git clone https://github.com/gach87/wireplumber-macos-policy
cd wireplumber-macos-policy
./install.sh
```

`./uninstall.sh` reverts it. The installer checks that WirePlumber comes back
up and rolls itself back if it does not.

Requires WirePlumber 0.5+.

## Configuration

The preferred list **builds itself** as you use the machine. It lives in
`~/.local/state/wireplumber/audio-preferred-devices`:

```
sink.0=bluez_output.XX_XX_XX_XX_XX_XX.1
sink.1=alsa_output.usb-...
sink.2=alsa_output.pci-...
```

Edit it by hand to set an initial order. Names are `node.name`, from
`wpctl inspect <id>`. Holes and duplicates are tolerated: the list is compacted
and deduplicated on load.

### Devices that must not steal focus

Some nodes appear and disappear on their own — network sinks tracking a remote
host, virtual monitors, loopbacks — and that is not a user action. In
`90-preferred-devices.conf`:

```
preferred-devices.no-arrival = [ "^rtp%-", "^network%-audio%-" ]
```

Lua patterns, matched against `node.name`. Matching devices stay selectable by
hand and usable as a fallback; they just do not become the default merely by
showing up. Without this, a remote host rebooting yanks the audio out of your
headphones.

### Preferred device profiles

`91-bt-profile.conf` uses `device.profile.priority.rules`, WirePlumber's own
declarative section:

```
device.profile.priority.rules = [
  {
    matches = [ { device.name = "~bluez_card.*" } ]
    actions = { update-props = { priorities = [ "a2dp-sink-sbc_xq", "a2dp-sink" ] } }
  }
]
```

To see what a device offers: `pw-cli enum-params <device-id> EnumProfile`.

## Side effect worth knowing about

To make the desktop's output picker work, the component keeps
`default.configured.<type>` in sync with whichever device it selects. Without
that, clicking the device that was already configured changes no metadata,
emits no event, and does nothing.

WirePlumber's own `default-nodes/store-configured-default-nodes` hook reacts to
**any** change of that key, so it records the component's automatic choices in
its stored history as if you had made them by hand. That history has no cap
upstream, so it grows. It only matters if you uninstall the component: the
fallback order it would then use has been shaped by automatic switches rather
than by your choices. `~/.local/state/wireplumber/default-nodes` can be deleted
to reset it.

## Known limitation

**Restarting WirePlumber while Bluetooth headphones are connected loses the
A2DP endpoint registration**, and the device is left offering only HFP (mono,
8 kHz). Reconnect the device to fix it.

The component **cannot cure this**: it needs to talk to BlueZ over D-Bus, and
WirePlumber's Lua sandbox does not expose it (the library exports no `wp_dbus`
symbols at all). It mostly affects manual restarts, not normal boots, where
Bluetooth connects after WirePlumber is already up.

## Implementation notes

Things that each cost a real failure and are not documented anywhere obvious:

- **A `requires` naming a feature that does not exist is not ignored: it stops
  WirePlumber from starting**, and you lose audio entirely. Check names against
  `grep "provides =" /usr/share/wireplumber/wireplumber.conf`.
- **`available-nodes` carries every node**, not just the ones for the event's
  direction. You must filter by `media.class` yourself.
- **You need `before = { "default-nodes/apply-default-node" }`.** That hook
  declares the same `after` list you would, so the order between them is
  undefined and your decision can land after theirs was applied. The symptom
  misleads: the log says you picked correctly and `wpctl` shows something else.
- **A manual choice only counts when it changes.** The native hook re-proposes
  it at 30000 on every event; without remembering the last one seen, you
  re-promote it and override a device that just arrived.
- **You must write `default.configured` with the winner.** Otherwise picking by
  hand the device that was already configured changes no metadata, emits no
  event, and the click does nothing.
- The Lua sandbox exposes neither `io` nor `os`; use `State` to persist.
- `log:info` is invisible at the default log level. Use `log:warning` to debug.

## Development

```
src/
  preferred-devices.lua        the component
  config/*.conf                shipped configuration
test/
  fake-wireplumber.lua         configurable double of the WirePlumber API
  test-preferred-devices.lua
  check-configs.sh
```

The tests run the **component's real logic without WirePlumber**.
`fake-wireplumber.lua` implements the globals WirePlumber injects into the Lua
sandbox (`Log`, `State`, `Json`, `SimpleEventHook`, ...) with values each test
configures, captures the hooks as they register, and invokes them with fake
events:

```lua
local wp = Fake.new { state = { ["sink.0"] = "speakers" } }
local c  = wp:load ("src/preferred-devices.lua")
local ev = wp:select_event { kind = "audio.sink", nodes = {...} }
c:run ("preferred-devices/select", ev)
assert (ev:selected () == "headset")
```

```sh
lua5.3 test/test-preferred-devices.lua   # or lua5.4
./test/check-configs.sh
```

Every test is verified by breaking the code it is supposed to protect.

## License

MIT, same as WirePlumber.
