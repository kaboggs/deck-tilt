# Deck Tilt

A mod for the Gen 1 recomp. It moves the screen light with the motion sensor
of the Steam Deck, and it draws the screens that Game Boy games were made for.

Tilt the console and the glare moves across the picture. Turn on the screen
effects and the game looks like a Game Boy Color in sunlight, or a Game Boy in
a dark room, or a television in 1996.

Everything is off until you turn it on. The mod changes no game file and no
engine file.

---

## What you need

- The Gen 1 recomp, with `game/src/render/GBCFX.lua`.
- A Steam Deck. The motion part needs one. The screen effects do not.
- LOVE 11.5. The recomp already includes it.

You supply your own game files. This mod contains none.

---

## Install

```
./install.sh
```

The script finds the engine, copies the mod into `game/mods/DECK_TILT/`, and
runs the tests. Give it a path if it cannot find the engine:

```
./install.sh /path/to/engine
```

To remove it:

```
./install.sh --uninstall
```

See [docs/install.md](docs/install.md) to install by hand.

---

## Start the game through Steam

**The motion sensor does not work if you start the game from a folder or a
terminal.** Steam owns the sensor. It gives it only to a game that Steam
started.

1. Add the game to Steam as a non-Steam game.
2. Start it from your Steam library.
3. Open the controller settings for it and set Gyro Behavior to any value
   that is not Off.

The `SENSOR` row at the top of the mod's page tells you which of these is
missing. See [docs/sensor.md](docs/sensor.md).

The vibration works the same way. It needs a Steam launch too.

---

## Where the settings are

Open `OPTIONS` and choose `SD-GYRO`. It is the first row.

```
SENSOR       LIVE          is the sensor working
AXIS MAP                   a picture of which movement does what
SCREEN FX    ON            one switch for every screen effect
ROOM LIGHT   NORMAL        how much light is on the screen
MOTION       TILT          the tilt light itself

TILT SETUP                 which movement moves the light, and how far
LIGHT FX                   the glare, its colour, and the shadow
GBC SCREEN                 a Game Boy Color screen with no backlight
TV / RF                    the picture through an aerial into a television
CRT CONTROLS               the three knobs on the front of a set
CRT TUBE                   the tube the picture is painted onto
COLOUR                     the colours the game is drawn in
DMG PANEL                  what a real Game Boy panel does to the picture
LCD GHOST                  the trail that moving things leave behind
RUMBLE                     how strong the vibration is

RECENTRE     PRESS A       put the light back in the middle
RESET FX     PRESS A       put the screen effects back, keep the motion setup
RESET ALL    PRESS A       put everything back
```

Press `SELECT` on any row for a page of plain English about it.

---

## The screen effects

Each one is a separate page, and every row starts off.

| Page | What it does |
| --- | --- |
| `GBC SCREEN` | Light pixels become see-through, as they were with no backlight. The grey plate behind the screen shows through, with its grain. In strong light a rainbow appears. |
| `DMG PANEL` | What a Game Boy screen does to a picture: the smear dark shapes drag down it, the shadow each dot throws, the screen's own colour, and dead lines. |
| `LCD GHOST` | Moving things leave a trail. The screen goes dark quickly and light slowly, so the trail is behind a sprite that has moved. |
| `TV / RF` | The picture as a signal through an aerial: moving dots, colour that runs past an edge, scan lines, a curved screen, snow. |
| `CRT CONTROLS` | Black and white, colour, contrast. The three controls on the front of a television. |
| `CRT TUBE` | The pattern of stripes or dots on the glass, the glow, the darkening at the edges, the beam. |
| `COLOUR` | Changes what the game's own `CLASSIC` colour setting looks like. |

`SCREEN FX` turns all of them off at once and keeps their settings.
`ROOM LIGHT` changes how much light the Game Boy screens have to work with,
because neither of them makes any light of its own.

Full detail: [docs/screens.md](docs/screens.md).

---

## Documentation

| Page | What is in it |
| --- | --- |
| [docs/options.md](docs/options.md) | Every row and what it does. |
| [docs/screens.md](docs/screens.md) | The screen effects, and the hardware each one copies. |
| [docs/sensor.md](docs/sensor.md) | Setting up the gyro, and what each `SENSOR` value means. |
| [docs/rumble.md](docs/rumble.md) | The vibration, and why it needed a new route. |
| [docs/internals.md](docs/internals.md) | How the mod reads the sensor and reaches the engine. |
| [docs/compatibility.md](docs/compatibility.md) | Versions, other mods, and known clashes. |

---

## Licence

MIT. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md).
