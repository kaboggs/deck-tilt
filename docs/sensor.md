# The motion sensor

## Start the game through Steam

The sensor does not work if you start the game from a folder or a terminal.
This is not a fault in the mod. Steam owns the controller and gives the sensor
only to a game that Steam started.

1. Add the game to Steam as a non-Steam game.
2. Start it from your Steam library.
3. Open the controller settings for that game.
4. Set Gyro Behavior to any value that is not Off.

The `SENSOR` row changes to `LIVE` as soon as the sensor starts sending. You
do not have to restart the game.

## What the SENSOR row means

| Value | What it means | What to do |
| --- | --- | --- |
| `LIVE` | The sensor works. | Nothing. |
| `ASLEEP` | The game is reading the controller, but the sensor part of the report is all zeroes. | Start the game from Steam. Set Gyro Behavior to a value that is not Off. |
| `SEEK` | The game is looking for the controller. | Wait a moment. If it stays, press a button on the controller. |
| `NO DEV` | The game cannot find the controller at all. | Check the controller is connected. |
| `NO FFI` | This build of LOVE cannot read the device. | Nothing. The mod stays off. |
| `GBCFX OFF` | The light effect is off in the game's own options. | Raise GBC FX in the main options menu, or use the `3D LIGHT` row. |

`ASLEEP` is the common one and it always means the same thing: Steam has not
been asked for the sensor.

## The above is only fully true on the git-checkout engine

Everything up to here describes the direct-HID reader (`lib/Imu.lua`'s own
`/dev/hidraw` path), and on that engine it is accurate: Steam Input really
does gate whether the controller's report carries live accelerometer/gyro
bytes, and setting Gyro Behavior really does flip `ASLEEP` to `LIVE` without
a restart.

Every **packaged** build (every release engine from 0.2.15 on, including
this install's 0.2.36) denies mods `require("ffi")`, so that reader never
runs there at all — the mod falls back to the engine's own
`src/core/Sensors.lua` instead (0.9.0, `677c382`). Since **2026-08-29** the
Start-through-Steam instructions at the top of this page are accurate on a
packaged engine again too, through a different mechanism than Gyro
Behavior — read on before assuming it is still stuck.

### 2026-08-29 update: fixed, via an engine patch, not a mod change

`SDL_NumSensors()` really is permanently 0 on this engine (verified
2026-08-29, `review/w13-decktilt-2026-08-29/sensors-*.log`) — Steam
Input's Gyro Behavior setting does not gate that API at all, and the
joystick-sensor API that might (`SDL_JoystickGetSensorData`) is an
undefined symbol in the linked SDL2. Both genuinely dead ends; W13 was
right to call SDL2 a dead end on this engine.

What is **not** a dead end is reading the controller's HID report
directly, the same way `lib/Imu.lua` always has — just from ENGINE code
instead of mod code, where `require("ffi")` is not sandboxed away.
`patches/0003-sensors-hidraw-imu.patch` (install-local, in the top-level
`patches/` directory, re-applied automatically by `apply-patches.sh` after
every engine update) adds exactly that to `src/core/Sensors.lua`: a third
fallback, after `love.sensor` and the SDL sensor API, that opens
`/dev/hidraw*` and decodes the same 64-byte report `lib/Imu.lua` always
has. No mod code changed — DECK_TILT's existing `EngineSensors` fallback
(`677c382`) already called `Sensors.read()`; it started receiving real
data the moment the engine started answering honestly.

**Device-proven 2026-08-29** on this install, under a real Steam launch
(`review/w14-gyro-2026-08-29/live-steam-yellow-4-final.log`): 300 samples
over ~5s, accelerometer magnitude 9.79–9.83 m/s² (essentially exactly
standard gravity, i.e. the Deck lying still), non-frozen (real per-sample
jitter), `SENSOR` row (`Imu.status`) reading `LIVE` with
`Imu.path = "engine:sensors"`. Also re-confirmed: a desktop/terminal
launch still reads `ASLEEP` honestly (Steam is not populating the report's
IMU block outside a Steam launch) — that part of this page was never
wrong, and still is not.

If a future engine bump ships a newer SDL2 with a working
`SDL_JoystickGetSensorData`, that would be a cleaner long-term path than a
raw hidraw read and could replace this patch; until then, this is the
fix. Drop `patches/0003-sensors-hidraw-imu.patch` only once that happens
(see its header comment in `apply-patches.sh` for the exact condition).

## Set the centre

The light moves away from a centre angle. Set that centre to the way you
actually hold the console.

- Open the mod's page and press A on `RECENTRE`.
- Or set `QUICK CENTRE` to `ON` and bind the `LEFT CONTROL` key to a rear
  button in the Steam controller settings. The game does not use the rear
  buttons.

`AUTO LEVEL` moves the centre slowly towards however you are holding the
console. Use it if the light drifts to one edge and stays there.

## Choose the movements

Open `AXIS MAP` for a picture of the console and the light. Then use
`TILT SETUP`.

| Movement | What you do |
| --- | --- |
| `TIP` | Move the top edge away from you or towards you. |
| `SIDE` | Lift one side. Hold the console upright for this. |
| `TURN` | Turn the console like a page. Hold it flat for this. |
| `SPIN-V`, `SPIN-H` | The light moves while you turn, and stops when you stop. |

`SIDE` is measured from the centre angle, so it does nothing until you have
recentred in the pose you play in. `TURN` is the default because it works from
a centre captured anywhere near flat.
