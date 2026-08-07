# The vibration

## The short version

Set `RUMBLE` on the `RUMBLE` page. `STOCK` is the gentle vibration the game
always had. Everything above it is much stronger. Use `RUMBLE TEST` on the
same page to feel a value without leaving the menu.

Start the game from Steam. The vibration needs that, the same as the sensor.

## Why there is a new route

The Steam Deck has no rumble motors. It has two haptic parts behind the
trackpads, and the usual way for a game to ask for vibration does not reach
them with any strength.

Measured on a Deck:

```
setVibration(1, 1, 2.0)   returned true
getVibration              0 / 0
```

The call reports success and nothing happens. The game is talking to a
controller that Steam pretends to have, not to the console. Even when Steam
passes it through, the result is very weak.

So above `STOCK` the mod sends the vibration straight to the console instead.

## What the rows do

| Row | What it does |
| --- | --- |
| `MOTOR` | Whether the strong route is open. `DIRECT` is good. |
| `RUMBLE` | How strong. `OFF`, then `STOCK`, then nine steps up to `MAX`. |
| `FINE TUNE` | Makes all of it weaker or stronger. Goes below 1X as well as above. |
| `BATTLE FX` | Vibration for shakes, damage, faints and the HP bar. |
| `STORY` | Catching, levelling up, evolving, finding an item. |
| `AMBIENT` | Footsteps, and the heartbeat when your Pokemon is nearly out of HP. |
| `MENUS` | A tick when the cursor moves and when you press A. |
| `RUMBLE TEST` | Press A to feel the current setting. |

`RUMBLE` sets how hard the hardest hit is. `FINE TUNE` moves all of it up or
down without changing rung. Each step up `RUMBLE` also brings the quiet
effects up more than the loud ones, so a cursor tick becomes easy to feel
before a faint becomes painful.

## What MOTOR tells you

| Value | What it means |
| --- | --- |
| `DIRECT` | The strong route is open. |
| `STOCK` | Running on the gentle route, because `RUMBLE` is set to `STOCK`. |
| `NO HID` | The strong route did not open. The gentle one is used instead. |
| `NO PAD` | No controller found. |
| `OFF` | The `RUMBLE` row is off. |

## The limit

There is no volume control in the console's haptic hardware. Strength comes
from how the part is driven, not from a number that can keep going up. `MAX`
is everything the console can do at once. If `MAX` is not enough, nothing
further is available.

The other rumble mod can stay installed. Set `RUMBLE` to `OFF` here and it
keeps working as before. Do not run both at once with this one on: two things
driving one part fight each other.
