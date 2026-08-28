# Versions and other mods

## Confirmed against

Deck Tilt 0.7.2 was tested on a Steam Deck with LOVE 11.5, on Red, Blue and
Yellow, alongside these versions (2026-08-20):

| | |
| --- | --- |
| Engine | `bryanthaboi/gen1recomp`, `main` |
| Dramatic Shape Voxel Mod | 1.8.1 |
| Wilds of Kanto | 2.1.8 |
| Stadium Battle FX | 2.1.8 |
| All Pokemon Catchable 151 | 0.3.3-beta |
| Quality of Life | 1.3.0 |
| Useful Bag | 2.4.1 |
| Gen 3 Box | 1.9.2 |
| Multiple Save Slots | 1.0.0 |
| Access PC Anywhere | 1.0.1 |
| Controller Rumble | 1.0.3 |
| Run Mode | 1.2.0 |
| Voxel Characters | 1.8.1 |
| Free Fly | 1.8.0 |
| Safe Save Backup | 1.0.0 |

Every mod above loaded clean beside this one. Nothing here depends on any of
them.

Kanto in First Person was dropped from the set; Dramatic Shape declares a
conflict with it and this engine disables the DECLARING mod, so enabling it
turned the whole 3D build off.

`DramaticShape/DramaticShapeVoxelMod` has been **deleted from GitHub**. 1.8.1
above is a local copy. The forks that continue it are `DRAMALESS_SHAPE`,
`BATTLE_ART_VOXEL_FORK` and `potato_voxel`; none has been tested with this mod.

Update this table whenever the shader passes change, and say what the new
work was tested against.

0.7.2 changed one pass, `CRT TUBE`. The mask is now drawn by coverage rather
than by a hard edge, `SHADOW` and `DOT` sit on a real delta lattice, and there
is a new `CRT ROTATE` row. The numbers in that work were measured from
rendered output at every pitch rung; none of the mods above changed.

## Engine

The mod draws through one of two seams, and since 0.9.1 it claims BOTH
whenever each is offered, because which one is live is a fact about the
renderer, not about which files exist:

* **The GBCFX takeover** (0.2.15 and the git-era engines). The mod reads
  `game/src/render/GBCFX.lua`'s shader text, rewrites one statement in
  memory, compiles its own copy, and wraps `present()`/`active()`. No engine
  file is written to. If a future engine writes that statement differently,
  the rewrite misses, the status row says so, and the game draws its own
  light. The test suite runs the rewrite against the engine's real shader,
  so it fails there instead.

* **The `render.output_enabled` / `render.output` hooks** (upstream 0.2.36,
  which deleted GBCFX.lua for the ShaderFX presets). The same pass chain and
  the same overlay, handed the finished composite; answering "not handled"
  on any failure gives the frame back to the engine.

The seams cannot double-draw — an engine that raises `render.output` checks
it before its own present effects and skips them when the frame is handled,
and an engine that drives GBCFX never raises `render.output` — and 0.9.1
exists because choosing by the MODULE was wrong: an install can restore
GBCFX.lua as a compatibility library for other mods while its renderer never
calls it. The status row now reports GBCFX only when the engine actually
speaks through it (`OVERLAY OFF`, not `GBCFX OFF`, on a hook-driven engine).

## Games

Red, Blue, Yellow — and, since the `gen2-port` work, **Gold and Silver**. The
mod reads no game data. It moves a light and draws over the finished picture.

`manifest.json` declares `"games": ["gen1", "gen2"]`. Upstream skips a mod on a
Gold/Silver boot unless it says so, silently and with no error, so the
declaration is the difference between running and simply not being there.

### What the Gen 2 boot needed

**DMG PALETTE had to learn a second target.** Gold does not read
`PaletteFX.CLASSIC`. Its present pass — `src/core/Game2.lua`, `Game2:blitZones`
— asks `src/render/GbcPalette.lua` for `presentColors()`, which returns its own
private `CLASSIC_SHADES`. Both tables hold the identical pea-green ramp, so the
measured palette is right for either, but writing only PaletteFX left the row
reading ON while Gold's screen stayed stock green. `lib/DmgPalette.lua` now
keeps a list of live tables with a snapshot per table, so OFF restores each
engine's own shipped values rather than the other's.

Gold's colour ladder is its own: **GBC / DMG / CLASSIC** (`GbcPalette.MODES`),
separate from Gen 1's `COLORS` row. The measured palette shows in **CLASSIC**.

**Two `src.ui.OptionRows` reaches are skipped on Gen 2.** Neither could ever
have drawn there — `DeckIcon` *wraps* `OptionRows.draw` and Gold builds no menu
on it, and `GyroMenu` only wanted `clampScroll` — but a mod that merely
mentions one of the fifteen gated Gen 1 names from its own chunk is reported
once, which put this mod in the manager's error feed and reddened its row.
Gen 1 still defers to the engine's `clampScroll` so the two cannot drift.

`isGen2()` asks `src.core.GameVersion`, deliberately not one of the gated
names, so the question itself costs nothing.

**What is not verified on Gold:** the battle-art cache invalidation. Gold has
no `BattleState.invalidate` and its overworld is not `MapLoader`, so
`DmgPalette`'s invalidate finds nothing to call. That is correct rather than
missing — Gold substitutes the palette in the present shader, so nothing is
baked against it — but a palette change mid-battle has not been eyeballed.

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
