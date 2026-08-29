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
`src/core/Sensors.lua` instead (0.9.0, `677c382`). `ASLEEP` still means "no
usable reading", but the fix above does not apply the same way, and this
matters enough to write down rather than let someone chase a phantom Gyro
Behavior toggle:

- **Verified 2026-08-29** (`review/w13-decktilt-2026-08-29/sensors-*.log`,
  `game/tests/drivers/w13_sensors_probe.lua`): on this engine,
  `Sensors.read()` goes through SDL2's *standalone* Sensor-device API
  (`SDL_NumSensors`/`SDL_SensorOpen`) — a different subsystem from a
  joystick's own embedded sensor. `SDL_NumSensors()` reads **0** on this
  machine every time it was checked: on a plain desktop launch, under a
  real Steam launch (`SteamGameId` confirmed set), and with
  `SDL_JOYSTICK_HIDAPI_STEAM=1` and `SDL_JOYSTICK_HIDAPI_STEAMDECK=1` both
  forced on. Gyro Behavior does not gate this API at all — it is not the
  mechanism Steam Input uses to expose gyro to a game, so changing it
  cannot change this number.
- The one API that plausibly could see the Deck's built-in IMU is the
  *joystick's own* sensor API (`SDL_JoystickHasSensor` /
  `SDL_JoystickGetSensorData`, attached to the controller SDL does see —
  it opens as `SDL_NumJoysticks()==1`, named `"Steam Deck"` via the raw
  Joystick API and `"Microsoft X-Box 360 pad 0"` via `love.joystick`, in
  every launch mode tried). `src/core/Sensors.lua` never calls this API.
- On this install it would not matter yet if it did:
  `SDL_JoystickHasSensor` is an **undefined symbol** in the linked
  `libSDL2.so` (`sdl2-compat 2.32.56`) — confirmed by calling it, not by
  reading a changelog. Wiring the engine to the joystick-sensor API is a
  real fix to *try*, but it needs a newer/different SDL2 underneath LÖVE
  before it can even link, which is outside what a mod-side change (or a
  `patches/` diff) can do — this belongs in a future engine-side
  investigation, not a quick patch.
- Net effect: on a packaged engine, `ASLEEP` currently means "gyro is not
  reachable through SDL2 on this system", full stop — not "Steam has not
  been asked for it". The row is honest that nothing is coming through; the
  one thing it cannot yet say is *why*, because the engine's own contract
  (`Sensors.read`) always answers `0, 0, 0` for "no device" and "device
  present but empty" alike, so the mod has no signal to tell them apart
  without re-implementing this probe itself. Left as found rather than
  patched under time pressure: the collapse is a known, deliberate tradeoff
  (see the comment above `pollEngine` in `lib/Imu.lua`), and untangling it
  correctly is engine work.

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
