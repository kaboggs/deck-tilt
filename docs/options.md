# Every row

Press `SELECT` on any row in the game for the same text there.

## First page

| Row | What it does |
| --- | --- |
| `SENSOR` | Whether the sensor works. See [sensor.md](sensor.md). |
| `AXIS MAP` | A picture of the console and the light. |
| `SCREEN FX` | One switch for every screen effect. Keeps their settings. |
| `ROOM LIGHT` | How much light is on the screen. Changes both Game Boy screens. |
| `MOTION` | The tilt light. DEMO moves it with no sensor. |
| `RECENTRE` | Put the light back in the middle. |
| `RESET FX` | Screen effects back to how they started. Keeps the motion setup. |
| `RESET ALL` | Everything back, motion included. |

## TILT SETUP

| Row | What it does |
| --- | --- |
| `SIDEWAYS`, `UP/DOWN` | Which movement moves the light. |
| `... FLIP` | Reverse a direction. |
| `... AMT` | How far the light travels. |
| `SMOOTHING` | How hard the sensor is filtered. |
| `AUTO LEVEL` | Moves the centre towards how you hold the console. |
| `QUICK CENTRE` | Lets `LEFT CONTROL` recentre without a menu. |

## LIGHT FX

The mod's own light, for when the game's own light effect is off.

| Row | What it does |
| --- | --- |
| `3D LIGHT` | Draw the light when the game's own is off. |
| `GLARE`, `GLARE TINT` | How bright it is, and its colour. |
| `COLOUR` | How much coloured shimmer it has. |
| `SHADOW`, `SHADOW AMT` | The drop shadow, and how far it falls. |

Screen effects: [screens.md](screens.md). Vibration: [rumble.md](rumble.md).

## Rows that need another row

- Everything on `GBC SCREEN` needs `GBC SCREEN` on.
- `RAINBOW BANDS` and `FILM MARKS` change the rainbow, so they need `RAINBOW`.
- Everything on `TV / RF` needs `TV/RF` on.
- `ROOM LIGHT` reaches the Game Boy panel only with `PANEL TRIM` on.
- `LINE STRENGTH` and `LINE SEED` need `DEAD LINES` on.
- `SCREEN FX` off silences every screen effect.
