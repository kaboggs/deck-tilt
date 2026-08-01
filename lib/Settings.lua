-- This mod's settings, in the order they appear on both menus.
--
-- Its own module rather than locals in main.lua so Motion can read the live
-- values without main.lua having to push them in on every change.

local V = ...
local Setting = V.require("Setting")

local Settings = {}

Settings.motion = Setting.new("motion", "MOTION",
  { "tilt", "demo", "off" }, { "TILT", "DEMO", "OFF" },
  "TILT moves the light with the motion sensor. DEMO moves the light "
  .. "through a test pattern. Use DEMO if you do not have a motion sensor. "
  .. "OFF gives the light back to the game. The game then moves the light "
  .. "slowly, as it does without this mod.",
  "tilt")

-- Horizontal and vertical gain, as two independent rows over one shared
-- ladder.  They are separate because the axes do not have the same range of
-- motion behind them: pitching the top edge towards or away from you is a
-- wrist movement with enormous travel (measured on hardware, gravity swung
-- -0.89 to +0.77 without effort), while turning the console about the
-- screen's vertical axis runs out around 25 degrees before you are no longer
-- looking at the screen.  One gain across both is what made sideways
-- movement feel stiff, so sideways simply defaults higher.
local GAIN_VALUES = { "subtle", "low", "normal", "high", "wide", "max" }
local GAIN_LABELS = { "SUBTLE", "LOW", "NORMAL", "HIGH", "WIDE", "MAX" }

Settings.xrange = Setting.new("xrange", "SIDEWAYS AMT",
  GAIN_VALUES, GAIN_LABELS,
  "This row sets the distance that the light moves to the left and to the "
  .. "right. A higher value moves the light more.",
  "wide")

Settings.yrange = Setting.new("yrange", "UP/DOWN AMT",
  GAIN_VALUES, GAIN_LABELS,
  "This row sets the distance that the light moves up and down. A higher "
  .. "value moves the light more.",
  "high")

Settings.smooth = Setting.new("smooth", "SMOOTHING",
  { "tight", "normal", "loose" }, { "TIGHT", "NORMAL", "LOOSE" },
  "How hard the accelerometer is filtered. TIGHT follows your hands "
  .. "closely and carries their shake; LOOSE glides and lags.")

-- The one thing about the Deck's IMU that cannot be settled by reading the
-- report: which way its axes point relative to the screen, and with what
-- sign.  Rather than bake a guess in, the guess is the default and this row
-- flips it.
-- Which sensor axis drives each direction of light travel, and its sign.
--
-- Every axis the hardware reports is offered, because the whole point is to
-- let a player try things.  Gravity supplies only TWO independent directions
-- -- a unit vector has two degrees of freedom, so TURN and TIP exhaust it --
-- and FLAT is the same vector's third component, useful as "how face-up is
-- it" rather than as a direction.
--
-- The gyro supplies the axis gravity physically cannot: TWIST. Rotating the
-- console about the screen normal leaves the gravity vector pointing exactly
-- where it was, so no accelerometer can see it; spin a Deck flat on a table
-- and it reads the same throughout.
local SRC_VALUES = { "tip", "twist", "turn", "spinx", "spiny", "off" }
local SRC_LABELS = { "TIP", "SIDE", "TURN", "SPIN-V", "SPIN-H", "OFF" }
local SRC_HELP =
  "This row selects the movement that moves the light. "
  .. "TIP: move the top edge away from you or toward you. "
  .. "SIDE: lift one side of the console. Hold the console upright to use "
  .. "SIDE. "
  .. "TURN: turn the console like a page. Put the console flat to use TURN. "
  .. "SPIN-V and SPIN-H: the light moves while you turn the console. The "
  .. "light stops when you stop. "
  .. "OFF: the light does not move in this direction."

Settings.srcx = Setting.new("srcx", "SIDEWAYS",
  SRC_VALUES, SRC_LABELS, SRC_HELP, "twist")
Settings.srcy = Setting.new("srcy", "UP/DOWN",
  SRC_VALUES, SRC_LABELS, SRC_HELP, "tip")

Settings.signx = Setting.new("signx", "SIDEWAYS +/-",
  { "pos", "neg" }, { "NORMAL", "FLIPPED" },
  "This row reverses the direction. Use it if the light moves to the left "
  .. "when you want it to move to the right.", "pos")
Settings.signy = Setting.new("signy", "UP/DOWN +/-",
  { "pos", "neg" }, { "NORMAL", "FLIPPED" },
  "This row reverses the direction. Use it if the light moves up when you "
  .. "want it to move down.", "pos")

Settings.shadow = Setting.new("shadow", "SHADOW",
  { "follow", "fixed", "off" }, { "FOLLOW", "FIXED", "OFF" },
  "FOLLOW moves the shadow below the text and the sprites. The shadow "
  .. "moves away from the light. FIXED keeps the shadow in one position. "
  .. "OFF removes the shadow.",
  "follow")

-- What to do when the engine's own GBC FX is not available.
--
-- The 3D voxel mod holds GBC FX at zero while it is installed, because a
-- full-screen LCD simulation over a diorama fights it.  That is a fair call
-- about the PANEL -- the backing plate, the subpixel grid -- and it is not
-- a call about the light.  OVERLAY draws the light on its own: the glare,
-- the coloured shimmer and a drop shadow, and none of the panel.
--
-- AUTO rather than ON by default, because it must not change what anyone
-- already has.  With GBC FX available nothing here runs at all; the engine
-- keeps its light and this mod keeps moving it, exactly as before.
Settings.overlay = Setting.new("overlay", "3D LIGHT",
  { "auto", "on", "off" }, { "AUTO", "ON", "OFF" },
  "What to do when the GBC FX light is not available. Another mod can hold "
  .. "GBC FX off. AUTO draws the light again in that condition only. ON "
  .. "always draws it. OFF never draws it, and this mod then does nothing "
  .. "while GBC FX is off. The light is the glare, the colour and the drop "
  .. "shadow. It does not change the 3D world or its own shadows. Use the "
  .. "SHADOW row to remove the drop shadow by itself.",
  "auto")

-- How strong the coloured shimmer is on the overlay pass.
--
-- Its own row because it is the part most likely to be unwanted: the bands
-- are thin-film interference rings, and over a large flat pale surface they
-- have nothing to break them up and read as contour lines rather than as
-- iridescence. SUBTLE is the default for that reason. This row does not
-- touch the engine's own GBC FX shimmer, which is fixed at level 4.
Settings.shimmer = Setting.new("shimmer", "COLOUR",
  { "off", "subtle", "normal", "full", "max" },
  { "OFF", "SUBTLE", "NORMAL", "FULL", "MAX" },
  "How much colour the light adds on the 3D LIGHT overlay. The colour is a "
  .. "set of rings around the light. FULL is as strong as the effect of the "
  .. "game. MAX is stronger than the game. OFF removes the colour and keeps "
  .. "the glare and the drop shadow. Use a low value if the rings look like "
  .. "thin lines on large pale surfaces. This row does nothing while the "
  .. "game draws its own GBC FX light.",
  "max")

-- How bright the specular hotspot is.
--
-- Its own row because the engine's value is calibrated for a 160x144 panel,
-- where 0.15 is a clear hotspot.  The same number spread over a full screen
-- is very nearly nothing, which is what it looked like on hardware -- so
-- this reaches well past the engine's strength rather than only below it.
Settings.glare = Setting.new("glare", "GLARE",
  { "off", "low", "normal", "high", "max" },
  { "OFF", "LOW", "NORMAL", "HIGH", "MAX" },
  "How bright the light is on the 3D LIGHT overlay. NORMAL is as bright as "
  .. "the effect of the game. HIGH and MAX are brighter than the game, "
  .. "because a full screen spreads the light more than a small screen "
  .. "does. OFF removes the bright area and keeps the colour and the drop "
  .. "shadow. This row does nothing while the game draws its own GBC FX "
  .. "light.",
  "high")

-- Let the centre follow how you are holding the console.
--
-- Without this the centre is wherever you last put it, and it stays there
-- while your hold does not. Measured: 10 degrees of change is enough to hold
-- the light against one edge, and 25 degrees puts the centre off the screen.
Settings.level = Setting.new("level", "AUTO LEVEL",
  { "slow", "normal", "fast", "off" }, { "SLOW", "NORMAL", "FAST", "OFF" },
  "Moves the centre slowly to the angle that you hold. Use this if the "
  .. "light moves to one edge and stays there while you play. SLOW takes "
  .. "about 45 seconds, which can be too slow. NORMAL takes about 20 "
  .. "seconds. FAST takes about 8 seconds and can also absorb a tilt that "
  .. "you hold. OFF keeps the centre exactly where RECENTRE put it.",
  "normal")

-- A recentre you can reach without opening a menu.
--
-- The obvious gesture -- touching both capacitive stick tops -- turned out to
-- be unreachable: Steam Input never exposes the Deck's stick touch as a
-- binding source (its only mention anywhere is an internal preference that
-- uses it to mute the trackpads), and the raw HID button field reads as
-- permanently zero while Steam owns the controller.  So this listens for a
-- KEY instead, and the console's back buttons -- which the game does not use
-- at all -- can be bound to it in Steam Input.
Settings.hotkey = Setting.new("hotkey", "QUICK CENTRE",
  { "on", "off" }, { "ON", "OFF" },
  "This row lets a button move the light to the centre. You do not have to "
  .. "open this menu. Assign the LEFT CONTROL key to a rear button in the "
  .. "Steam controller settings. The game does not use the rear buttons.",
  "on")

Settings.order = { Settings.motion,
                   Settings.srcx, Settings.signx,
                   Settings.srcy, Settings.signy,
                   Settings.xrange, Settings.yrange,
                   Settings.smooth, Settings.level, Settings.shadow,
  Settings.overlay, Settings.shimmer, Settings.glare, Settings.hotkey }

function Settings.schema()
  local out = {}
  for i, s in ipairs(Settings.order) do out[i] = s:schema() end
  return out
end

-- Put every row back to the value it shipped with.
--
-- Worth having as one action rather than making the player walk the list:
-- there are ten rows, several interact (a source and its sign, a gain and
-- the centring it is measured from), and a half-reverted set is harder to
-- reason about than either extreme.
function Settings.resetAll(game)
  for _, s in ipairs(Settings.order) do
    s:setPos(s:defaultIndex(), game, true)
  end
  if game and game.writeOptions then pcall(game.writeOptions, game) end
end

-- Move whichever setting a "mod.options_changed" payload names.
function Settings.sync(key, value)
  for _, s in ipairs(Settings.order) do
    if s.key == key then s:sync(value) return end
  end
end

return Settings
