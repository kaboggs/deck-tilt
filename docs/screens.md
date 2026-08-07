# The screen effects

Each one copies a real piece of hardware. Every row starts off.

`SCREEN FX` turns all of them off at once and keeps their settings.
`ROOM LIGHT` sets how much light the Game Boy screens have, because neither
makes light of its own. `DIM` is a dark room, and the picture is hard to read
— which is how the real console was.

## GBC SCREEN

A Game Boy Color has no backlight, so a light pixel is a window onto the grey
plate behind the screen. Games used white as see-through; a modern lit screen
gives back hard white instead. This puts the plate back.

| Row | What it does |
| --- | --- |
| `GBC SCREEN` | Which pixels become see-through: white only, bright, or all. |
| `SEE-THROUGH` | How see-through they are. |
| `BACKING` | The colour of the plate. Shown as colours beside the row. |
| `SHEET GRAIN` | How rough the plate looks. It is pressed material, not a mirror. |
| `LCD SHADOW` | The shadow the pixel layer drops onto the plate. |
| `RAINBOW`, `RAINBOW BANDS` | The rainbow in strong light, and how fine its rings are. |
| `FILM MARKS` | The film is uneven, so the rings bend. Changes the rainbow only. |

The rainbow is real: the film shifts light by a quarter wave at one colour and
not the others, and the mismatch leaks through as colour that changes with
angle. It moves when you tilt.

## DMG PANEL

| Row | What it does |
| --- | --- |
| `CROSSTALK` | Dark shapes smear down the screen. |
| `CELL SHADOW` | The shadow each dark dot throws on the sheet behind it. |
| `PANEL TRIM` | The screen's own colour: less colour, warmer, no true black. |
| `DEAD LINES` | Lines that stop working on an old console. |
| `LINE STRENGTH` | How badly they have failed. |
| `LINE SEED` | Which lines died. Each number is a different console. |

**Crosstalk matters most.** There is no switch behind each dot, so a dark
block pulls on every dot in its column. The smear is strong below the shape
and weak above it. This is what makes a screen look like a Game Boy, more than
the colour does.

**Dead lines are light, not dark.** The line stops being driven, so it shows
the silver sheet. Only a few settle dark. They arrive in groups near one edge,
where the ribbon is glued.

**There is no true black.** The darkest thing on screen is the silver sheet
seen through a dark dot.

## LCD GHOST

Moving things leave a trail. The screen goes dark quickly and light slowly, so
the trail is *behind* a sprite that has moved, not in front of one arriving.
`GHOST GATE` sets how much a thing must change before it trails, which keeps
still text sharp.

## TV / RF

The picture as a signal through an aerial. `TV/RF` is the master row.

Each row is a separate cause rather than a strength: moving dots are a bad
brightness and colour split, colour running past an edge is bandwidth, scan
lines and the curve are the tube, snow is the aerial.

## CRT CONTROLS and CRT TUBE

`CRT CONTROLS` is the three knobs on the front of a set. They act before
everything on `CRT TUBE`.

`CRT TUBE` is the tube: the pattern on the glass, its size, the glow and its
colour, the darkening at the edges, and the beam. `CRT PITCH` decides which
kind of set you are looking at more than the pattern does. `GLOW COLOUR`
offers fifteen colours with a strip beside the row — the first six are whites
a real tube left the factory at, the rest are single-colour tubes.

## COLOUR

`DMG SHADES` changes what the game's own `CLASSIC` setting looks like. The
built-in greens run together at the light end; `REAL DMG` uses shades measured
from hardware, warmer and properly separated. `OFF` gives the built-in colours
back exactly.

## Order

```
the panel  ->  the signal  ->  the tube  ->  the light on the glass
```

Panel effects are part of the picture, so the curve and the tube pattern
happen to them. This is why a curved screen bends the plate, the grain and the
dead lines along with the game.
