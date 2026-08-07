# How it works

## Reading the sensor

LOVE 11.5 has no sensor module, and the SDL it ships has no sensor back end on
Linux. The controller sends a 64-byte report on `/dev/hidraw`; the mod reads
that directly. Acceleration is at byte 24, turn rate at byte 30.

Those bytes stay zero until Steam Input asks for the sensor. That is `ASLEEP`,
and it is why the game must start from Steam.

## Turning that into a light position

- **Both sensors together.** Acceleration alone measures your hands as well as
  gravity. The turn rate is not affected by that but drifts. Each corrects the
  other.
- **A cross product, not an angle per axis.** Angles taken separately report
  the same value for a left lift and a right lift. The cross product of down
  now against down at the centre gives three independent movements.
- **A centre you set.** `RECENTRE` reads the unfiltered value, because the
  filtered one is where the console was a moment ago.

## Reaching the engine

The engine computes its light inside its own shader, from a clock, so there is
nothing to send it. The mod reads that shader's text, rewrites one statement
into a value it can send, and compiles the result as its own shader.

No engine file is written to. If a future engine writes that statement
differently the rewrite misses, the status row says so, and the game draws its
own light. The test suite runs the rewrite against the engine's real shader
every time, so it fails there rather than on a console.

## Order of the effects

```
the panel  ->  the signal  ->  the tube  ->  the light on the glass
```

Panel effects are part of the picture, so the curve and the tube pattern
happen to them. The glare and shadow are a reflection off the front, so they
are last.

## Failing safely

Every part can fail: no sensor, no device, a shader that will not rewrite, a
controller that will not vibrate. Each is caught, shown on a row, and switched
off for the session. The mod can stop working; it cannot stop the game
drawing.

## Tests

```
cd <engine>/game
lua5.4 mods/DECK_TILT/tests/deck_tilt_test.lua
```
