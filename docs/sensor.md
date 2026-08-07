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
