# Versions and other mods

## Confirmed against

Deck Tilt 0.7.0 was tested on a Steam Deck with LOVE 11.5, on Red, Blue and
Yellow, alongside these versions:

| | |
| --- | --- |
| Engine | `bryanthaboi/gen1recomp`, `main` |
| Dramatic Shape Voxel Mod | 1.7.0 |
| Wilds of Kanto | 1.9.0 |
| All Pokemon Catchable 151 | 0.3.3-beta |
| Quality of Life | 1.2.6 |
| Useful Bag | 2.4.1 |
| Gen 3 Box | 1.5.2 |
| Multiple Save Slots | 1.0.0 |
| Access PC Anywhere | 1.0.1 |
| Controller Rumble | 1.0.3 |
| Run Mode | 1.2.0 |
| Kanto in First Person | 1.40.1 |

Every mod above loaded clean beside this one. Nothing here depends on any of
them.

Update this table whenever the shader passes change, and say what the new
work was tested against.

## Engine

The mod needs `game/src/render/GBCFX.lua`. It reads that shader's text,
rewrites one statement in memory, and compiles its own copy. No engine file is
written to.

If a future engine writes that statement differently, the rewrite misses, the
status row says so, and the game draws its own light. The test suite runs the
rewrite against the engine's real shader, so it fails there instead.

## Games

Red, Blue and Yellow. The mod reads no game data. It moves a light and draws
over the finished picture.

## With the voxel mod

That mod holds the game's own light effect at zero, which turns off the light
this mod moves. The `3D LIGHT` row answers it: on `AUTO` the mod draws its own
light whenever the game's is off. The screen effects do not need the game's
light at all.

## With the rumble mod

Both can be installed. Set `RUMBLE` to `OFF` here and the other mod behaves as
it always did. Do not run both at once with `RUMBLE` above `OFF` — two things
driving one haptic part fight each other.

## Buttons

The mod claims no game button. It listens for `LEFT CONTROL` for
`QUICK CENTRE`, and only when that row is `ON`. Bind it to a rear button; the
game uses neither.

## Cost

An effect that is off is skipped, not run with a zero. `SCREEN FX` turns all
of them off at once.

The most expensive is `CROSSTALK`, which reads twenty-four neighbouring pixels
per pixel. Turn it off first if the game runs slowly.
