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

-- TURN rather than SIDE by default.
--
-- SIDE is the better movement in principle -- it is the only sideways gesture
-- gravity can see when the console is held upright -- but it is measured from
-- the centre angle, so it reads exactly zero until you have recentred in the
-- pose you actually play in. A default that does nothing until you find a
-- button and press it is a broken default, whatever its merits afterwards.
--
-- TURN works from a centre captured anywhere near flat, which is where most
-- people will first meet it. Change this row to SIDE once you have recentred
-- upright. See the note in the handoff about removing the choice entirely.
Settings.srcx = Setting.new("srcx", "SIDEWAYS",
  SRC_VALUES, SRC_LABELS, SRC_HELP, "turn")
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

-- ------- the TV/RF pass
--
-- Six rows for one optional effect is a lot on a page this mod deliberately
-- shrank to one menu row.  They are here rather than folded into a single
-- dial because the artefacts are independent CAUSES, not strengths of one
-- thing: dot crawl is a bad Y/C split, cross-colour is chroma bandwidth,
-- scanlines and curvature are the tube, and snow is the aerial.  A player who
-- wants a soft CRT but no snow, or colour bleed but a flat screen, is asking
-- for a different combination rather than a smaller number -- and one dial
-- cannot answer that.
--
-- OFF is the default on the master row, so nothing below it runs and nothing
-- anyone already has changes.  Every row is a no-op while TV/RF is OFF.
Settings.rf = Setting.new("rf", "TV/RF",
  { "off", "soft", "normal", "harsh" },
  { "OFF", "SOFT", "NORMAL", "HARSH" },
  "Draws the picture as if it came through an aerial into an old TV. This "
  .. "adds moving dots, colour that spreads past an edge, scan lines and a "
  .. "curved screen. OFF removes all of it and the rows below do nothing. "
  .. "SOFT mixes a little of it with the plain picture. NORMAL is most of "
  .. "it. HARSH is all of it. The light of this mod is drawn on top of this "
  .. "effect, not under it.",
  "off")

Settings.rfdots = Setting.new("rfdots", "RF DOTS",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How many moving dots appear where colour meets colour. A TV separates "
  .. "the brightness from the colour, and the part it fails to separate "
  .. "becomes these dots. They move because the signal changes each field. "
  .. "HIGH is a worse TV. OFF is a perfect separation, which no real TV has.",
  "normal")

Settings.rfcolour = Setting.new("rfcolour", "RF COLOUR",
  { "off", "faint", "low", "normal", "high", "max" },
  { "OFF", "FAINT", "LOW", "NORMAL", "HIGH", "MAX" },
  "How strong the colour is, and how much false colour appears on fine "
  .. "detail. A TV carries colour separately from brightness, and turning "
  .. "this up puts more of it in the signal, so more of it leaks into places "
  .. "it does not belong. Use RF CHROMA to change how far it spreads instead. "
  .. "OFF gives a black and white picture.",
  "normal")

-- Bandwidth is a different question from gain, and one row cannot ask both:
-- RF COLOUR is how MUCH colour there is, this is how far it RUNS. Two sets
-- fed the same tape differ here more than anywhere else.
Settings.rfchroma = Setting.new("rfchroma", "RF CHROMA",
  { "studio", "tight", "normal", "wide", "portable" },
  { "STUDIO", "TIGHT", "NORMAL", "WIDE", "PORTABLE" },
  "How far colour spreads sideways past an edge. A TV carries colour with "
  .. "less detail than brightness, so colour runs past an edge while the edge "
  .. "itself stays sharp. STUDIO is a monitor that holds colour almost as "
  .. "tightly as brightness. PORTABLE is a cheap set that lets a red roof "
  .. "smear into the sky. This row does nothing while RF COLOUR is OFF.",
  "normal")

-- The tint knob, and the reason it existed.
Settings.rftint = Setting.new("rftint", "RF TINT",
  { "off", "green", "greenmore", "red", "redmore" },
  { "OFF", "GREEN", "GREEN+", "RED", "RED+" },
  "Turns every colour in the picture one way or the other. American TVs sent "
  .. "colour in a way that let each set get the hue slightly wrong, so sets "
  .. "had a knob on the front to correct it and no two of them agreed. GREEN "
  .. "and RED are the two directions it went wrong in. OFF is a set that is "
  .. "correctly adjusted. This row does nothing while RF COLOUR is OFF.",
  "off")

Settings.rfscan = Setting.new("rfscan", "RF SCAN",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How dark the horizontal lines of the tube are. A tube draws the picture "
  .. "in lines with a gap between them. NORMAL is the darkness measured from "
  .. "real hardware. OFF removes the lines.",
  "normal")

Settings.rfcurve = Setting.new("rfcurve", "RF CURVE",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How much the screen bulges, and how dark the corners are. The glass of a "
  .. "tube is curved. LOW is the default because a strong curve moves the "
  .. "text of the game away from where you expect it. OFF gives a flat "
  .. "screen and even corners.",
  "low")

Settings.rfnoise = Setting.new("rfnoise", "RF NOISE",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How much snow the aerial picks up. This is the only row here that is not "
  .. "part of the picture. OFF is a clean signal and is the default.",
  "off")

-- ------- the controls on the front of the set
--
-- The three rows anyone who ever owned a television already knows how to
-- use. They are part of the beam pass because they are what the SET does to
-- the picture on its way to the phosphor -- so they run before the glow and
-- the mask, and turning contrast up makes the glow bloom harder, the way it
-- does on a real one.
--
-- Unlike every other row in this section these are not OFF by default in the
-- sense of being absent: they default to 100%, which is unchanged, and the
-- pass stays switched off until one of them is moved.
Settings.beammono = Setting.new("beammono", "CRT MONO",
  { "off", "on" }, { "OFF", "ON" },
  "Shows the picture in black and white, the way a set without colour did. "
  .. "This is a switch rather than a level, so you can turn it on and off "
  .. "without losing the amount of colour you set on CRT COLOUR. While it is "
  .. "ON, CRT COLOUR does nothing.",
  "off")

Settings.beamsat = Setting.new("beamsat", "CRT COLOUR",
  { "0", "25", "50", "75", "100", "125", "150", "175", "200" },
  { "0%", "25%", "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
  "How strong the colours are. 100% leaves the picture alone. 0% is black "
  .. "and white, reached with the colour control the way a real set does it. "
  .. "Above 100% the colours are pushed further than they really are, which "
  .. "is what a set looks like with its colour control wound up: reds glow "
  .. "and lose their detail. This is different from RF COLOUR, which changes "
  .. "how much colour is in the signal before the set sees it.",
  "100")

Settings.beamcontrast = Setting.new("beamcontrast", "CRT CONTRAST",
  { "50", "60", "70", "80", "90", "100", "110", "120", "130", "140", "150" },
  { "50%", "60%", "70%", "80%", "90%", "100%", "110%", "120%", "130%",
    "140%", "150%" },
  "The difference between the light and dark parts of the picture. 100% "
  .. "leaves it alone. Below that the picture flattens towards grey. Above "
  .. "it the bright parts get brighter and the dark parts get darker. Use "
  .. "some of this with CRT MASK, which costs contrast by design.",
  "100")

-- ------- the electron-beam pass
--
-- Additive with TV/RF and independent of it: RF is the SIGNAL arriving at the
-- set, this is the TUBE it is painted onto.  Each row is its own cause again,
-- and every one of them has an OFF, so any combination can be switched off
-- without touching the others -- including all of them, which is the default.
Settings.beammask = Setting.new("beammask", "CRT MASK",
  { "off", "grille", "slot", "shadow", "pvm", "trinitron", "dot" },
  { "OFF", "GRILLE", "SLOT", "SHADOW", "PVM", "TRINITRON", "DOT" },
  "The pattern of coloured dots or stripes on the front of a tube. GRILLE is "
  .. "unbroken vertical stripes. SLOT is stripes broken into short blocks "
  .. "that step sideways every other row, which is what most TVs in homes "
  .. "used. SHADOW is round dots. PVM is the stripes of a studio monitor, "
  .. "with black glass left between each group of three, which is what gives "
  .. "those monitors their deep picture. TRINITRON is stripes with the two "
  .. "fine wires that Sony strung across the tube to hold them steady: you "
  .. "can see their shadow across the picture, and that is correct. DOT is "
  .. "the fine round dots of an expensive set. Use CRT PITCH to set how "
  .. "large the pattern is. The picture is made brighter first, so the "
  .. "pattern costs light that was added rather than light you had. OFF "
  .. "removes the pattern.",
  "off")

-- Pitch is what actually separates one real tube from another: the same
-- geometry at 0.25mm and at 0.8mm are a broadcast monitor and a living-room
-- set, and no amount of choosing between GRILLE and SLOT expresses that.
Settings.beammaskpitch = Setting.new("beammaskpitch", "CRT PITCH",
  { "fine", "normal", "wide", "widest" },
  { "FINE", "NORMAL", "WIDE", "WIDEST" },
  "How large the pattern on the front of the tube is. An expensive monitor "
  .. "has a very fine pattern that you cannot see from a normal distance. A "
  .. "large old TV in a living room has a coarse one you can count from "
  .. "across the room. This is the row that decides which kind of set you "
  .. "are looking at, more than the pattern itself does. This row does "
  .. "nothing while CRT MASK is OFF.",
  "normal")

Settings.beamscan = Setting.new("beamscan", "CRT BEAM",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How much the lines of the tube change width with the picture. A bright "
  .. "line is wide and nearly touches the line below it. A dark line is thin "
  .. "with black on both sides. This is different from the RF SCAN row, "
  .. "which draws lines of one fixed darkness. OFF removes it.",
  "off")

Settings.beamglow = Setting.new("beamglow", "CRT GLOW",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How far light spreads out from a bright area, through the glass and "
  .. "across the coating behind it. Use some of this with CRT MASK, because "
  .. "the glow is what stops the pattern looking like dirt on the screen. "
  .. "OFF removes it.",
  "off")

-- The one row on this page with a picture instead of only a word: the swatch
-- strip is drawn beside it. A colour cannot be chosen from its name -- 9300K
-- means nothing to anyone who has not lined up a monitor -- so the page shows
-- the colours and marks the one you are on. See GyroMenu.drawSwatches.
Settings.beamglowcol = Setting.new("beamglowcol", "GLOW COLOUR",
  { "white", "k9300", "k7500", "k5500", "amber", "green", "blue" },
  { "WHITE", "9300K", "7500K", "5500K", "AMBER", "GREEN", "BLUE" },
  "The colour of the light that spreads out from bright areas. The coating "
  .. "inside a tube does not give back plain white light, and which white it "
  .. "gives back is most of what makes one set look different from another. "
  .. "9300K is the cold blue-white that nearly every Japanese set left the "
  .. "factory at. 7500K is what studio monitors were set to. 5500K is the "
  .. "warm white of a late or well-used set. AMBER, GREEN and BLUE are the "
  .. "single-colour tubes of old monitors rather than TVs. WHITE adds no "
  .. "colour at all. The colours are shown next to this row, with a mark "
  .. "under the one you have chosen. This row does nothing while CRT GLOW "
  .. "is OFF.",
  "white")

Settings.beamedge = Setting.new("beamedge", "CRT EDGE",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How much darker the picture gets towards the edges and corners. A tube "
  .. "does this for two reasons, and this row does both: the corners are dim "
  .. "because the beam works at an angle there, and the last part of the "
  .. "edge is dark because the coating stops and the frame of the set "
  .. "shadows it. NORMAL is the amount measured from real hardware. This is "
  .. "separate from RF CURVE, which darkens the corners of its own curved "
  .. "screen. Both can be on. OFF removes it.",
  "off")

-- Softness is its own row because it is a different question from strength.
-- CRT EDGE says how DARK the edges get; this says how FAR IN that reaches and
-- how gradually it arrives. Asking for a gentle wash over the outer third is
-- not asking for a darker corner, and one dial cannot express both.
Settings.beamedgesoft = Setting.new("beamedgesoft", "EDGE SOFT",
  { "tight", "normal", "soft", "softest" },
  { "TIGHT", "NORMAL", "SOFT", "SOFTEST" },
  "How gradual the darkening at the edges is. TIGHT keeps it in the corners. "
  .. "NORMAL is the shape measured from real hardware. SOFT and SOFTEST "
  .. "spread the same darkness further into the picture, for a gentle wash "
  .. "rather than a dark corner. This row does nothing while CRT EDGE is OFF.",
  "normal")

-- The one row here whose usefulness is a property of the DISPLAY rather than
-- of the picture, which is why its value carries a measured readout.
-- The rung names the TUBE, not the ratio.  The ratio that is any good depends
-- on the display, so a ladder of ratios is correct on one machine and wrong
-- everywhere else; the tube is the thing a player can actually have an
-- opinion about, and the ratio is then measured arithmetic.  See CrtBeam.
Settings.beamroll = Setting.new("beamroll", "CRT ROLL",
  { "off",
    "15hz", "20hz", "25hz", "30hz", "35hz", "40hz", "45hz", "50hz",
    "55hz", "60hz",
    "70hz", "80hz", "90hz", "100hz", "110hz", "120hz" },
  { "OFF",
    "15HZ", "20HZ", "25HZ", "30HZ", "35HZ", "40HZ", "45HZ", "50HZ",
    "55HZ", "60HZ",
    "70HZ", "80HZ", "90HZ", "100HZ", "110HZ", "120HZ" },
  "Lights each line for a moment instead of for the whole frame, the way a "
  .. "tube does. This makes movement clearer. Choose the speed of the tube. "
  .. "60HZ is the speed of a real one and is the right choice on this "
  .. "console. A lower speed makes movement clearer still, but it can "
  .. "flicker. The number next to this row is how much less blurred movement "
  .. "is, measured on your screen right now. It needs your screen to refresh "
  .. "faster than the tube: this console refreshes 90 times a second, so a "
  .. "60HZ tube gives 33 per cent. A faster screen gives more. 20HZ is not a "
  .. "real tube speed. It is there because it shows you the band of light "
  .. "sweeping down the screen instead of hiding it, which is what you see "
  .. "for a moment when the game starts up. It flickers. The speeds below "
  .. "about 30HZ all show the band this way. A speed FASTER than your screen "
  .. "cannot work at all, and this row will say NO HZ next to it when you "
  .. "pick one: on this console that is anything from 90HZ up. Those speeds "
  .. "are here for a faster screen, and the row measures rather than assumes, "
  .. "so it will tell you the truth on whatever you are playing on.",
  "off")

Settings.order = { Settings.motion,
                   Settings.srcx, Settings.signx,
                   Settings.srcy, Settings.signy,
                   Settings.xrange, Settings.yrange,
                   Settings.smooth, Settings.level, Settings.shadow,
  Settings.overlay, Settings.shimmer, Settings.glare,
  Settings.rf, Settings.rfdots, Settings.rfcolour, Settings.rfchroma,
  Settings.rftint, Settings.rfscan,
  Settings.rfcurve, Settings.rfnoise,
  Settings.beammono, Settings.beamsat, Settings.beamcontrast,
  Settings.beammask, Settings.beammaskpitch,
  Settings.beamscan, Settings.beamglow, Settings.beamglowcol,
  Settings.beamedge, Settings.beamedgesoft,
  Settings.beamroll,
  Settings.hotkey }

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
