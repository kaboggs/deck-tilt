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

-- ------- one switch for every picture effect
--
-- The mod has grown five passes that change what the picture looks like --
-- the GBC panel, the DMG panel, the LCD trail, TV/RF and the CRT tube --
-- each with its own rows on its own page. Turning them all off to see the
-- game plainly, or to find out which of them you are actually looking at,
-- meant visiting five pages and remembering what every row had been.
--
-- This is that, as one row, and it FORGETS NOTHING: it gates the passes at
-- the point they run rather than changing any of their settings, so they all
-- come back exactly as they were when it goes back on.
--
-- It deliberately does NOT cover the tilt light. That is the mod's reason for
-- existing rather than an effect laid over the picture, and it already has
-- its own master on the MOTION row below.
Settings.screenfx = Setting.new("screenfx", "SCREEN FX",
  { "on", "off" }, { "ON", "OFF" },
  "One switch for every effect that changes how the picture looks: the Game "
  .. "Boy screen, the Game Boy panel, the trail, the television and the tube. "
  .. "OFF turns all of them off at once and keeps their settings, so ON puts "
  .. "everything back the way you had it. Use OFF to see the game plainly, or "
  .. "to find out whether one of these effects is what you are looking at. "
  .. "This row does not change the light that moves when you tilt the "
  .. "console. Use the MOTION row below for that.",
  "on")

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

-- "FLIP", not "+/-".
--
-- The Game Boy font has no `+`. Font.encode substitutes a SPACE for a glyph
-- the charmap lacks and warns once to the log, so these two rows had been
-- reading "SIDEWAYS  /-" on screen since they were written -- a defect
-- invisible in the source, invisible in a test, and only ever visible on a
-- running console. See the renderable-character test in the suite, which now
-- fails on any label or value this font cannot draw.
Settings.signx = Setting.new("signx", "SIDEWAYS FLIP",
  { "pos", "neg" }, { "NORMAL", "FLIPPED" },
  "This row reverses the direction. Use it if the light moves to the left "
  .. "when you want it to move to the right.", "pos")
Settings.signy = Setting.new("signy", "UP/DOWN FLIP",
  { "pos", "neg" }, { "NORMAL", "FLIPPED" },
  "This row reverses the direction. Use it if the light moves up when you "
  .. "want it to move down.", "pos")

Settings.shadow = Setting.new("shadow", "SHADOW",
  { "follow", "fixed", "off" }, { "FOLLOW", "FIXED", "OFF" },
  "FOLLOW moves the shadow below the text and the sprites. The shadow "
  .. "moves away from the light. FIXED keeps the shadow in one position. "
  .. "OFF removes the shadow.",
  "follow")

-- How far the shadow is thrown, in Game Boy pixels.
--
-- The stock throw is 3.45px, which is the engine's own 3px plus a shade. That
-- number was chosen to make the shadow CLEAR THE SPRITE equally on both
-- sides, not to be seen moving -- and at that length the swing across the
-- full range of the light is about seven pixels, which on a 160x144 screen
-- shown at a distance is a movement you have to be told about before you
-- notice it.
--
-- This row is for seeing the motion rather than for realism. NORMAL is
-- exactly the stock throw, so the default changes nothing; every rung above
-- it is a literal pixel length, because the useful question here is "how far
-- does it move" and a word like STRONG does not answer it.
--
-- The rungs stop at 28px. Past roughly a third of the screen the shadow stops
-- reading as attached to the thing that casts it and becomes a second copy of
-- the text, which is a different effect and not a better one.
Settings.shadowamt = Setting.new("shadowamt", "SHADOW AMT",
  { "stock", "5", "7", "10", "14", "20", "28" },
  { "NORMAL", "5PX", "7PX", "10PX", "14PX", "20PX", "28PX" },
  "How far the shadow falls away from the text and the sprites. NORMAL is "
  .. "the distance the game itself uses, which is about 3 pixels. The other "
  .. "values are the distance in pixels. A longer distance makes the movement "
  .. "of the shadow easy to see when you tilt the console. A very long "
  .. "distance makes the shadow look like a second copy of the text instead "
  .. "of a shadow. This row needs SHADOW set to FOLLOW to show movement. "
  .. "While SHADOW is FIXED the shadow does not move, and this row only makes "
  .. "it fall further. This row does nothing while SHADOW is OFF.",
  "stock")

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

-- The colour of the glare, as a row of actual colours beside it.
--
-- The glare is a reflection off the front of the glass, so its colour is the
-- colour of the room being reflected -- and neutral white, which is what it
-- always added, is the one lighting condition almost nobody plays under.
--
-- Like GLOW COLOUR, this row draws its palette next to itself rather than
-- asking anyone to pick a colour from a word. See GbcLight.drawSwatches: the
-- strip is drawn INTO the frame, so the curve and the mask happen to it and
-- it bends with its own row.
--
-- Normalised to constant brightness in GbcLight.glareTint, so this row is
-- purely a hue and the GLARE row above it remains the only one that changes
-- how strong the highlight is.
Settings.glaretint = Setting.new("glaretint", "GLARE TINT",
  { "white", "warm", "cool", "amber", "gold", "green", "blue", "violet",
    "pink" },
  { "WHITE", "WARM", "COOL", "AMBER", "GOLD", "GREEN", "BLUE", "VIOLET",
    "PINK" },
  "The colour of the bright reflection that moves with the console. The "
  .. "reflection takes the colour of the room, and WHITE is the plain light "
  .. "this mod used before. WARM is an indoor bulb. COOL is daylight from a "
  .. "window. The colours after those are not rooms. They are a choice, for "
  .. "a picture where the highlight is a colour of its own. The colours are "
  .. "shown next to this row, with a mark under the one you have chosen. "
  .. "Every colour is the same brightness, so this row changes the colour of "
  .. "the reflection and not how strong it is. Use GLARE above for that. "
  .. "This row does nothing while GLARE is OFF, and nothing while the game "
  .. "draws its own GBC FX light.",
  "white")

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

-- ------- the GBC screen pass
--
-- Seven rows for the pixel-transparency effect (lib/PixelTrans, a port of
-- see lib/PixelTrans).  Same shape as the TV/RF section below and
-- for the same reason: the plate, its shadow and the rainbow are separate
-- CAUSES -- a player who wants the unlit-screen look without the sunlight
-- rainbow, or the rainbow over an untinted plate, is asking for a different
-- combination and not a smaller number.
--
-- OFF is the default on the master row, so nothing below it runs and nothing
-- anyone already has changes.  Every row is a no-op while GBC SCREEN is OFF.
Settings.pt = Setting.new("pt", "GBC SCREEN",
  { "off", "whites", "bright", "all" },
  { "OFF", "WHITES", "BRIGHT", "ALL" },
  "Shows the picture as the screen of a Game Boy Color. That screen has no "
  .. "light of its own, so its light pixels are not white. They are clear, "
  .. "and you see the plate behind the screen through them. WHITES makes "
  .. "only the white pixels clear. BRIGHT makes each pixel clear by how "
  .. "bright it is, which is the way the original effect ships. ALL makes "
  .. "every pixel a little clear. OFF removes the effect, and the rows "
  .. "below it then do nothing. The curved screen and the scan lines of the "
  .. "TV pages are drawn over this effect, so they bend it with the glass.",
  "off")

Settings.ptalpha = Setting.new("ptalpha", "SEE-THROUGH",
  { "low", "normal", "high", "max" }, { "LOW", "NORMAL", "HIGH", "MAX" },
  "How clear the clear pixels are. A higher value shows more of the plate "
  .. "behind the screen and less of the picture. NORMAL is the amount the "
  .. "original effect uses. This row does nothing while GBC SCREEN is OFF.",
  "normal")

-- The default is OLIVE and not PLAIN, deliberately: the row only does
-- anything after the master row is switched on, and the green-grey plate is
-- both the real console's colour and the reference's own screenshots.  A
-- player who turns the effect on gets the thing the effect is named for.
Settings.ptback = Setting.new("ptback", "BACKING",
  { "plain", "olive", "warm", "neutral", "silver" },
  { "PLAIN", "OLIVE", "WARM", "NEUTRAL", "SILVER" },
  "The colour of the plate behind the screen. You see this plate through "
  .. "the clear pixels. OLIVE is the green plate of a real Game Boy Color. "
  .. "WARM and NEUTRAL are lighter plates. SILVER is a metal plate. PLAIN "
  .. "is a grey plate with no colour. The colours are shown next to this "
  .. "row, with a mark under the one you have chosen. Every plate is the "
  .. "same brightness, so this row changes only the colour. This row does "
  .. "nothing while GBC SCREEN is OFF.",
  "olive")

-- How much light is in the room the console is in.
--
-- A Game Boy Color has no backlight: everything you see is room light passing
-- through the panel, bouncing off the reflector behind it and coming back
-- out. So this is not a brightness control in the television sense -- it is
-- how bright the ROOM is, and it is the single knob that decides whether the
-- screen looks like a sunny afternoon or like the back of a car at dusk.
--
-- The reference exposes it (PT_BACKING_BRIGHTNESS) and this port had it
-- welded to the shipped 0.48. NORMAL is that value, so the default is
-- unchanged; DIM is the real, genuinely murky low-light experience, and
-- SUNLIT is the top of the reference's range.
Settings.ptlight = Setting.new("ptlight", "ROOM LIGHT",
  { "dim", "low", "normal", "bright", "sunlit" },
  { "DIM", "LOW", "NORMAL", "BRIGHT", "SUNLIT" },
  "How much light is in the room. The screen of a Game Boy Color makes no "
  .. "light of its own, so all of the light you see came from the room and "
  .. "went back out again. DIM is a dark room, where the picture is hard to "
  .. "read, which is how the real console was. SUNLIT is a bright day. "
  .. "NORMAL is the value the original shader uses. It changes both the "
  .. "Game Boy Color screen and the Game Boy panel, because neither of them "
  .. "makes any light of its own. For the Game Boy panel it needs PANEL TRIM "
  .. "turned on, because that is the row that models how the panel answers "
  .. "to light. Use this row with RAINBOW: the rainbow on a real screen only "
  .. "appears in strong light.",
  "normal")

Settings.ptshadow = Setting.new("ptshadow", "LCD SHADOW",
  { "off", "soft", "normal", "deep" }, { "OFF", "SOFT", "NORMAL", "DEEP" },
  "The dark pixels of the screen sit a small distance above the plate, so "
  .. "they put a soft shadow on it. The shadow moves away from the light "
  .. "when you tilt the console. When the motion sensor is off, the shadow "
  .. "keeps one position. NORMAL is the darkness the original effect uses. "
  .. "OFF removes the shadow. This row does nothing while GBC SCREEN is OFF.",
  "normal")

Settings.ptrainbow = Setting.new("ptrainbow", "RAINBOW",
  { "off", "subtle", "normal", "strong", "max" },
  { "OFF", "SUBTLE", "NORMAL", "STRONG", "MAX" },
  "How strong the rainbow is. The screen of a Game Boy Color has a thin "
  .. "film on it, and in strong light that film turns the light into rings "
  .. "of colour. The rings move when you tilt the console. NORMAL is the "
  .. "strength of the original effect. OFF removes the rainbow. This row "
  .. "does nothing while GBC SCREEN is OFF.",
  "normal")

Settings.ptbands = Setting.new("ptbands", "RAINBOW BANDS",
  { "wide", "normal", "fine", "finest" },
  { "WIDE", "NORMAL", "FINE", "FINEST" },
  "How wide the rings of the rainbow are. WIDE gives a few large rings. "
  .. "FINEST gives many small rings. NORMAL is the width the original "
  .. "effect uses. This row does nothing while RAINBOW is OFF.",
  "normal")

-- The grain of the reflector sheet behind the panel.
--
-- It had no row: the reference's 0.065 was welded in, so the one part of the
-- plate you can actually see the texture of could not be tried. NORMAL is
-- that value exactly.
--
-- Only two spatial bands are drawn, and that is deliberate -- see
-- reflectorGrain in lib/PixelTrans. The reference measured three, and found
-- the finest sits below what the panel can resolve, so drawing it costs
-- samples and returns aliasing.
Settings.ptgrain = Setting.new("ptgrain", "SHEET GRAIN",
  { "off", "low", "normal", "high", "max" },
  { "OFF", "LOW", "NORMAL", "HIGH", "MAX" },
  "How rough the silver sheet behind the screen looks. The sheet is pressed "
  .. "material, not a mirror, so it has a texture you can see in the light "
  .. "areas of the picture. NORMAL is the amount measured from real "
  .. "hardware. Higher values make an older or dirtier sheet. This row needs "
  .. "GBC SCREEN turned on, because the sheet is only drawn where the "
  .. "picture is see-through.",
  "normal")

-- FILM MARKS varies the THICKNESS of the polarizer film, which changes the
-- rainbow's colour from place to place. It is therefore invisible with
-- RAINBOW off -- it modulates that effect and nothing else -- and the help
-- says so, because a row that appears to do nothing is worse than no row.
-- The sheet's own texture is SHEET GRAIN above; the two are easy to confuse
-- from their names alone.
Settings.ptfilm = Setting.new("ptfilm", "FILM MARKS",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "The film on a real screen is not perfectly even, so the rings of the "
  .. "rainbow bend into uneven patches. OFF gives clean round rings. HIGH "
  .. "gives strong patches. NORMAL is the amount the original effect uses. "
  .. "This row does nothing while RAINBOW is OFF.",
  "normal")

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
-- GREENER / REDDER, not GREEN+ / RED+: the font has no `+`, so the stronger
-- rungs drew as "GREEN " and "RED " -- indistinguishable from the rungs below
-- them, which made the row look like it had two dead positions.
  { "off", "green", "greenmore", "red", "redmore" },
  { "OFF", "GREEN", "GREENER", "RED", "REDDER" },
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
  { "0", "25", "50", "75", "100", "125", "150", "175", "200" },
  "How strong the colours are. 100% leaves the picture alone. 0% is black "
  .. "and white, reached with the colour control the way a real set does it. "
  .. "Above 100% the colours are pushed further than they really are, which "
  .. "is what a set looks like with its colour control wound up: reds glow "
  .. "and lose their detail. This is different from RF COLOUR, which changes "
  .. "how much colour is in the signal before the set sees it.",
  "100")

Settings.beamcontrast = Setting.new("beamcontrast", "CRT CONTRAST",
  { "50", "60", "70", "80", "90", "100", "110", "120", "130", "140", "150" },
  { "50", "60", "70", "80", "90", "100", "110", "120", "130",
    "140", "150" },
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
  { "white", "k9300", "k7500", "k6500", "k5500", "k4200", "amber", "gold",
    "green", "mint", "cyan", "blue", "violet", "pink", "red" },
  { "WHITE", "9300K", "7500K", "6500K", "5500K", "4200K", "AMBER", "GOLD",
    "GREEN", "MINT", "CYAN", "BLUE", "VIOLET", "PINK", "RED" },
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

-- ------- this mod's own rumble
--
-- ------- what was actually wrong
--
-- Measured on a Steam Deck, not inferred: `love.joystick.setVibration`
-- returns TRUE and reads back 0/0. LOVE is talking to Steam Input's emulated
-- "Microsoft X-Box 360 pad 0"; the Deck itself has no rumble motors, only two
-- LRA actuators behind the trackpads, and the real Valve device reports
-- FF=none. Whatever the game asked for went nowhere.
--
-- That is why the rumble always felt minimal and why no multiplier in any mod
-- ever helped: they were all scaling a number that never reached hardware.
--
-- The route with real strength is Valve's own haptic command written straight
-- to /dev/hidraw -- the same move this mod already makes for the gyro. See
-- lib/DeckHaptics for the protocol, the frequency sweep, and the two bugs
-- found proving it.
--
-- ------- the ladder
--
-- STOCK is the old kernel path, unchanged, so "put it back to what it was" is
-- an actual setting rather than an approximation of one. Everything above it
-- drives the actuators directly, and the rungs walk frequency-at-resonance,
-- duty from 35 to 95 per cent, and -- at the top -- the kernel path stacked
-- underneath, because both routes reach the same actuators and add.
--
-- The top rung is the HARDWARE limit. There is no amplitude field in the
-- protocol; the drive voltage is fixed. So MAX is everything the console can
-- physically do at once, and the reason the ladder is wide is that the bottom
-- is very quiet, not that the top goes somewhere new.
Settings.rumblepower = Setting.new("rumblepower", "RUMBLE",
  { "off", "stock", "faint", "light", "soft", "normal",
    "firm", "strong", "hard", "max" },
  { "OFF", "STOCK", "FAINT", "LIGHT", "SOFT", "NORMAL",
    "FIRM", "STRONG", "HARD", "MAX" },
  "How strong the vibration of the console is. OFF is no vibration. STOCK is "
  .. "the vibration this game had before, which is very gentle because it "
  .. "goes through Steam and not to the console. Every value above STOCK "
  .. "sends the vibration straight to the console, which is much stronger. "
  .. "MAX is the most the console can do. Use RUMBLE TEST on this page to "
  .. "feel a value without leaving the menu. The row above says DIRECT when "
  .. "the strong route is working.",
  "stock")

-- ------- the fine tune
--
-- The ladder above sets the character of the rumble; this scales the whole of
-- it, in BOTH directions.
--
-- The row it replaces was a curve that only went UP. That was the right maths
-- for the wrong question: it could not quieten anything, so "NORMAL but a bit
-- less" was not expressible, and having two rows that each made things louder
-- by different mechanisms is what made this page confusing to reason about.
-- This one does what a volume knob does, and the ladder above now handles the
-- quiet-end lifting on its own.
--
-- Applies to STOCK too, so the old gentle path can be taken further down
-- rather than only being the floor.
Settings.rumbletune = Setting.new("rumbletune", "FINE TUNE",
  { "25", "50", "75", "100", "150", "200", "300", "400" },
  { "0.25X", "0.5X", "0.75X", "1X", "1.5X", "2X", "3X", "4X" },
  "Makes the whole vibration weaker or stronger than the RUMBLE row above "
  .. "sets it. 1X is exactly what that row says. Below 1X everything is "
  .. "gentler, so use it to take a setting down a little without changing to "
  .. "the rung below. Above 1X everything is stronger. The console has a "
  .. "limit, so with both rows near the top this row stops making a "
  .. "difference.",
  "100")

-- Which events vibrate at all. Same four categories the other rumble mod
-- offers, so switching to this one is not a downgrade in control.
local CAT_HELP_TAIL =
  " This row does nothing while RUMBLE is OFF."
Settings.rumblebattle = Setting.new("rumblebattle", "BATTLE FX",
  { "on", "off" }, { "ON", "OFF" },
  "Vibration for the screen shake, damage, faints and the HP bar draining."
  .. CAT_HELP_TAIL, "on")
Settings.rumblestory = Setting.new("rumblestory", "STORY",
  { "on", "off" }, { "ON", "OFF" },
  "Vibration for catching, levelling up, evolving, finding an item and the "
  .. "other moments in the game." .. CAT_HELP_TAIL, "on")
Settings.rumbleambient = Setting.new("rumbleambient", "AMBIENT",
  { "on", "off" }, { "ON", "OFF" },
  "Vibration for footsteps and for the heartbeat when your Pokemon is nearly "
  .. "out of HP." .. CAT_HELP_TAIL, "on")
Settings.rumblemenus = Setting.new("rumblemenus", "MENUS",
  { "on", "off" }, { "ON", "OFF" },
  "A small tick when the cursor moves in a menu and when you press A."
  .. CAT_HELP_TAIL, "on")

-- ------- LCD persistence
--
-- A real Game Boy panel does not switch instantly. The liquid crystal is
-- driven dark quickly and relaxes back to clear slowly, so moving art leaves
-- a trail BEHIND it. The physics, the two time constants and the sign that everyone gets
-- backwards are all in lib/Ghost.
--
-- OFF by default. This is the one pass here that changes how the game READS
-- rather than how it looks -- a long trail on a fast-scrolling overworld is
-- authentic and also harder to follow -- so it must be opted into.
Settings.ghost = Setting.new("ghost", "LCD GHOST",
  { "off", "subtle", "normal", "strong", "max" },
  { "OFF", "SUBTLE", "NORMAL", "STRONG", "MAX" },
  "Makes moving things leave a trail behind them, the way the screen of a "
  .. "real Game Boy does. The screen of a Game Boy is slow to go light again "
  .. "after it goes dark, so the trail is behind a sprite that has moved and "
  .. "not in front of it. NORMAL is the speed measured from real hardware. "
  .. "SUBTLE is a faster screen than any real one. STRONG and MAX are slower "
  .. "than real, for the look rather than for accuracy. A long trail can make "
  .. "the game harder to read while you are walking. OFF removes it.",
  "off")

-- How different two frames must be before the trail applies at all.
--
-- Without a gate a static picture very slowly crawls toward itself through
-- floating-point noise, which on a menu reads as the text breathing. The
-- reference uses 0.05; this exposes it because the right value depends on
-- how much dither is on screen, and Gen 1 has a lot of it.
Settings.ghostgate = Setting.new("ghostgate", "GHOST GATE",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "How much a thing has to change before it leaves a trail. NORMAL is the "
  .. "value measured from real hardware. A higher value keeps still pictures "
  .. "and text sharp and only lets large movements trail. OFF lets even the "
  .. "smallest change trail, which can make a still screen look unsteady. "
  .. "This row does nothing while LCD GHOST is OFF.",
  "normal")

-- ------- the DMG shades
--
-- The engine's CLASSIC colour mode uses the pea-green convention everybody
-- uses -- and its lightest two shades are sixteen points apart on one
-- channel, so they very nearly collapse into one. A real DMG separates them.
-- This swaps in a palette measured from real hardware. See
-- lib/DmgPalette for the numbers and for why it is safe to write them into
-- the engine's table.
--
-- OFF restores the engine's own values exactly, so the built-in setting is
-- never lost -- it is overridden while this row is on and handed straight
-- back when it is off.
Settings.dmgpal = Setting.new("dmgpal", "DMG SHADES",
  { "off", "realdmg" }, { "OFF", "REAL DMG" },
  "Changes the four greens the game uses when its own COLORS setting is set "
  .. "to CLASSIC. OFF is the colours the game came with. REAL DMG is the "
  .. "colours measured from a real Game Boy: warmer, and with the two "
  .. "lightest shades further apart, which is what makes text on the real "
  .. "console easy to read. This row does nothing unless the COLORS setting "
  .. "in the main options menu is CLASSIC.",
  "off")

-- ------- the DMG panel
--
-- Four properties of a passive-matrix reflective LCD, ported from
-- See lib/DmgPanel for the physics and the
-- measured constants. EVERY row here is OFF by default and the whole pass is
-- skipped when they all are, so this costs nothing until it is asked for.
Settings.dmgxtalk = Setting.new("dmgxtalk", "CROSSTALK",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "Makes dark shapes smear down the screen, the way they do on a real Game "
  .. "Boy. The screen has no switch behind each dot, so a dark block pulls on "
  .. "every dot in its own column. The smear is strong below the shape and "
  .. "weak above it, which is how a real one looks. NORMAL is the amount "
  .. "measured from real hardware. This is the effect that makes a screen "
  .. "look like a Game Boy more than the colour does.",
  "off")

Settings.dmgshadow = Setting.new("dmgshadow", "CELL SHADOW",
  { "off", "low", "normal", "high" }, { "OFF", "LOW", "NORMAL", "HIGH" },
  "The shadow each dark dot throws onto the silver sheet behind the screen. "
  .. "There is a small air gap between them, so the shadow is what makes the "
  .. "screen look like it has depth instead of being printed. It has two "
  .. "parts, a sharp one close in and a soft one further out. The shadow "
  .. "moves when you tilt the console, because it follows the same light "
  .. "every other effect in this mod does.",
  "off")

Settings.dmgtrim = Setting.new("dmgtrim", "PANEL TRIM",
  { "off", "on" }, { "OFF", "ON" },
  "Applies the colour of a real Game Boy screen on top of whatever colours "
  .. "the game is using: a little less colour, a little warmer, less "
  .. "contrast, and no true black. A screen with no light of its own cannot "
  .. "make black, because the darkest thing on it is still the silver sheet "
  .. "seen through a dark dot. Use this with DMG SHADES on the COLOUR page.",
  "off")

Settings.dmgdead = Setting.new("dmgdead", "DEAD LINES",
  { "off", "few", "some", "many" }, { "OFF", "FEW", "SOME", "MANY" },
  "Adds the lines that stop working on an old Game Boy screen. They are "
  .. "almost always light, not dark: the line stops being driven at all, so "
  .. "it goes back to showing the silver sheet behind it. They also arrive in "
  .. "groups near one edge rather than spread out, because the ribbon that "
  .. "fails is glued along that edge. This is for the look of an old console "
  .. "and it does hide part of the picture.",
  "off")

-- How completely a failed line has failed.
--
-- A bond does not only fail totally. An intermittent one still passes some
-- drive, which reads as a faint line rather than a bright bar -- and a faint
-- line is the one most people actually have on a console they still play.
-- Which lines died.
--
-- The pattern is a pure function of the column index and this number -- the
-- same seed always gives the same panel, which is the point: a console has
-- ONE set of dead lines and they do not wander about while you play. Change
-- this to be handed a different console.
Settings.dmgdeadseed = Setting.new("dmgdeadseed", "LINE SEED",
  { "1", "2", "3", "4", "5", "6", "7", "8" },
  { "1", "2", "3", "4", "5", "6", "7", "8" },
  "Which lines are the dead ones. Each number is a different console with a "
  .. "different set of faults. The pattern never changes while you play, "
  .. "because a real console has one set of dead lines and they stay where "
  .. "they are. Change this number if you do not like where they fell. This "
  .. "row does nothing while DEAD LINES is OFF.",
  "1")

Settings.dmgdeadamt = Setting.new("dmgdeadamt", "LINE STRENGTH",
  { "faint", "half", "full" }, { "FAINT", "HALF", "FULL" },
  "How badly the dead lines have failed. FULL is a line that has stopped "
  .. "working completely and shows the silver sheet. FAINT is a line that "
  .. "still works a little, which is what an old console that still plays "
  .. "usually has. This row does nothing while DEAD LINES is OFF.",
  "full")

-- ------- the menu tree
--
-- The page was thirty-seven rows and the viewport shows FOUR, so every row
-- past the first four cost a scroll and the last of them cost nine -- for a
-- mod whose front door was put at position 1 precisely because a row nobody
-- can find is a row that may as well not exist. The same argument applies
-- inside the page.
--
-- `order` is DERIVED from this rather than written beside it. It is what the
-- mod manager's flat schema page renders and what RESET ALL and the options
-- sync walk, so a setting missing from it is a setting that cannot be reset
-- and does not persist -- and a second hand-maintained list of thirty-odd
-- names is exactly the kind of thing that silently loses one.
--
-- Grouped by CAUSE, the same principle the TV/RF rows were split on: the
-- signal arriving (TV/RF), the controls on the front of the set (CRT
-- CONTROLS), and the tube it is painted onto (CRT TUBE) are three different
-- machines that happen to sit in one cabinet, and a player wanting a softer
-- picture is reaching for a different one of them than a player wanting a
-- coarser mask.
-- ------- a group row is a NAME, and nothing else
--
-- Each row box in the engine's viewport has two lines: a label and a value.
-- A group row fills only the first. It names the category and you go in.
--
-- Both other options were tried and are worse. A mark like `>` cannot be
-- drawn at all -- the Game Boy charmap has no `>`, and Font.encode
-- substitutes a SPACE for anything it cannot map, so it renders as nothing.
-- A SUMMARY of the page behind it (the engine's MODS row does this, reading
-- "N INSTALLED") draws fine and still reads badly here: a second line under
-- TILT SETUP saying TURN/TIP invites you to read it as a SETTING on that row,
-- and the value shown is one arbitrary member of eight or nine rows behind
-- it. It answers a question nobody asked at the cost of making the row
-- ambiguous.
--
-- So: no value function on these rows, which OptionRows already renders as an
-- empty second line. The categories carry the meaning; the specifics live one
-- press away, which is the whole point of having pages.
-- The three masters, on the root, most-global first.
--
--   SCREEN FX   gates every pass that changes the picture
--   ROOM LIGHT  how much light the panels have to work with
--   MOTION      the tilt light this mod exists for
--
-- ROOM LIGHT is here rather than on a panel's page because it answers to
-- BOTH of them -- it started inside the GBC submenu, where it was unreachable
-- from the DMG side and read as broken. A control that governs two pages
-- belongs above them, not inside one.
Settings.top = { Settings.screenfx, Settings.ptlight, Settings.motion }

Settings.groups = {
  { id = "tilt", label = "TILT SETUP",
    help = "The rows that decide how the console's movement moves the light: "
      .. "which way you have to move it, how far the light goes, and how the "
      .. "centre is found. Set these once. Use the AXIS MAP page on the "
      .. "previous screen to see what each movement does.",
    rows = { Settings.srcx, Settings.signx, Settings.xrange,
             Settings.srcy, Settings.signy, Settings.yrange,
             Settings.smooth, Settings.level, Settings.hotkey } },

  { id = "light", label = "LIGHT FX",
    help = "The light itself: how bright it is, how much colour it has, and "
      .. "the shadow it casts. Most of these rows work only while this mod "
      .. "draws the light on its own, which happens when another mod holds "
      .. "the GBC FX effect off.",
    rows = { Settings.overlay, Settings.glare, Settings.glaretint,
             Settings.shimmer, Settings.shadow, Settings.shadowamt } },

  -- Between the light and the TV sections because that is its place in the
  -- frame: the panel is what the picture IS, the TV pages are what it goes
  -- THROUGH, and the light is the reflection on top. See GbcLight.present.
  { id = "gbc", fx = true, label = "GBC SCREEN",
    help = "The picture as the screen of a Game Boy Color, which has no "
      .. "light of its own. Light pixels are clear, and the plate behind "
      .. "the screen shows through them. In strong light the screen also "
      .. "shows a rainbow, and the rainbow moves when you tilt the console. "
      .. "GBC SCREEN is the master row. While it is OFF every other row on "
      .. "that page does nothing.",
    rows = { Settings.pt, Settings.ptalpha, Settings.ptback,
             Settings.ptgrain, Settings.ptshadow,
             Settings.ptrainbow, Settings.ptbands, Settings.ptfilm } },

  { id = "rf", fx = true, label = "TV / RF",
    help = "The picture as a signal through an aerial into a television: "
      .. "moving dots, colour that spreads past an edge, scan lines, a curved "
      .. "screen and snow. TV/RF is the master row. While it is OFF every "
      .. "other row on that page does nothing.",
    rows = { Settings.rf, Settings.rfdots, Settings.rfcolour,
             Settings.rfchroma, Settings.rftint, Settings.rfscan,
             Settings.rfcurve, Settings.rfnoise } },

  { id = "set", fx = true, label = "CRT CONTROLS",
    help = "The three controls on the front of a television set: black and "
      .. "white, colour and contrast. These change the picture on its way to "
      .. "the tube, so they happen before the pattern and the glow on the CRT "
      .. "TUBE page. They work whether or not TV/RF is on.",
    rows = { Settings.beammono, Settings.beamsat, Settings.beamcontrast } },

  { id = "tube", fx = true, label = "CRT TUBE",
    help = "The tube the picture is painted onto: the pattern of coloured "
      .. "stripes or dots on the glass, the glow around bright areas, the "
      .. "darkening at the edges, and the beam that draws each line. Every "
      .. "row here is OFF until you turn it on.",
    rows = { Settings.beammask, Settings.beammaskpitch, Settings.beamscan,
             Settings.beamglow, Settings.beamglowcol,
             Settings.beamedge, Settings.beamedgesoft, Settings.beamroll } },

  { id = "colour", fx = true, label = "COLOUR",
    help = "The colours the game itself is drawn in. This page changes what "
      .. "the game's own COLORS setting means rather than replacing it, so "
      .. "the setting in the main options menu still chooses the mode. How "
      .. "much light is on the screen is the ROOM LIGHT row on the previous "
      .. "page, because that one changes both panels.",
    rows = { Settings.dmgpal } },

  { id = "dmg", fx = true, label = "DMG PANEL",
    help = "What a real Game Boy screen does to the picture, apart from its "
      .. "colour: the smear that dark shapes drag down the screen, the shadow "
      .. "each dot throws on the sheet behind it, the screen's own colour, "
      .. "and the lines that fail on an old one. Every row is off until you "
      .. "turn it on.",
    rows = { Settings.dmgxtalk, Settings.dmgshadow,
             Settings.dmgtrim, Settings.dmgdead,
             Settings.dmgdeadamt, Settings.dmgdeadseed } },

  { id = "ghost", fx = true, label = "LCD GHOST",
    help = "The trail that moving things leave behind them on a real Game "
      .. "Boy screen. The screen is quick to go dark and slow to go light "
      .. "again, so the trail is behind a sprite that has moved rather than "
      .. "in front of the one arriving. Both rows are off until you turn "
      .. "them on.",
    rows = { Settings.ghost, Settings.ghostgate } },

  { id = "rumble", label = "RUMBLE",
    help = "How strong the vibration of the console is, and which events "
      .. "cause it. RUMBLE is the strength; FINE TUNE makes all of it weaker "
      .. "or stronger without changing rung. STOCK on the RUMBLE row is the "
      .. "gentle vibration the game had before; everything above it goes "
      .. "straight to the console and is much stronger.",
    rows = { Settings.rumblepower, Settings.rumbletune,
             Settings.rumblebattle, Settings.rumblestory,
             Settings.rumbleambient, Settings.rumblemenus } },
}

-- Flat, in page order: the top-level rows, then each group's rows in turn.
Settings.order = {}
do
  local n = 0
  local function take(s) n = n + 1 Settings.order[n] = s end
  for _, s in ipairs(Settings.top) do take(s) end
  for _, g in ipairs(Settings.groups) do
    for _, s in ipairs(g.rows) do take(s) end
  end
end

function Settings.schema()
  local out = {}
  for i, s in ipairs(Settings.order) do out[i] = s:schema() end
  return out
end

-- The shadow throw this row asks for, in GB pixels.
--
-- `stock` is passed in rather than written here so the number lives in exactly
-- one place -- GbcLight, next to the engine constant it is derived from --
-- and NORMAL therefore cannot drift away from what it claims to be.
function Settings.shadowLenPx(stock)
  local v = Settings.shadowamt:get()
  if v == "stock" then return stock end
  return tonumber(v) or stock
end

-- ------- this mod's own rumble engine
--
-- How hard the loudest effect in the game may hit, 0..1. STOCK is handled
-- separately (it is a different ROUTE, not a level) and reports 1 here so the
-- old path is driven at the amplitudes its author chose.
-- Each rung carries TWO numbers, and that is what makes one row enough.
--
--   ceiling  how hard the loudest effect in the game may hit
--   curve    an exponent applied first, which lifts the QUIET effects
--
-- Both move together as the row goes up. That was the missing piece: with a
-- ceiling alone, turning the row up made a faint louder and left a cursor
-- tick exactly as unfeelable, so a second row had to exist to fix the quiet
-- end -- and then the two had to be reasoned about together, which is the
-- confusion this replaces. Folding the curve into the same rung means
-- "stronger" means stronger for everything, with the quiet things gaining
-- most, which is what the word ought to mean.
--
-- Monotonic at every authored strength: each rung is louder than the one
-- below it for any input, so the ladder never crosses itself.
-- FAINT and LIGHT are cut hard against the rest of the ladder -- to a
-- quarter and a half of what they were -- because they were reported as
-- still too strong on hardware. Two things were wrong at once: these
-- ceilings, and a duty floor in DeckHaptics that put every low rung at
-- roughly the same real drive whatever this table said. Both are fixed; this
-- is the half that lives here.
local POWER = {
  off    = { 0.00, 1.00 },
  stock  = { 1.00, 1.00 },  -- the old path, authored strengths untouched
  faint  = { 0.075, 1.00 }, -- was 0.30: a quarter of it
  light  = { 0.21, 0.96 },  -- was 0.42: half of it
  soft   = { 0.36, 0.88 },
  normal = { 0.52, 0.80 },
  firm   = { 0.66, 0.70 },
  strong = { 0.80, 0.62 },
  hard   = { 0.90, 0.52 },
  max    = { 1.00, 0.45 },
}

function Settings.ownRumbleOn()
  return Settings.rumblepower:get() ~= "off"
end

-- True when the strong route should be used. STOCK deliberately is not: it
-- exists so the original, gentle behaviour is still reachable.
function Settings.rumbleDirect()
  local v = Settings.rumblepower:get()
  return v ~= "off" and v ~= "stock"
end

function Settings.rumblePower()
  return (POWER[Settings.rumblepower:get()] or POWER.off)[1]
end

function Settings.rumbleCurve()
  return (POWER[Settings.rumblepower:get()] or POWER.off)[2]
end

-- The FINE TUNE row as a plain multiplier. Both directions.
function Settings.rumbleTune()
  local pct = tonumber(Settings.rumbletune:get())
  if not pct or pct <= 0 then return 1 end
  return pct / 100
end

-- Authored event strength -> what to actually drive.
--
--   curve first   lifts the quiet end, and leaves 1.0 at 1.0
--   ceiling next  sets how hard the loudest may hit
--   tune last     scales the finished result, up or down
--
-- Pure, so the whole mapping is testable without a controller.
function Settings.rumbleShapeValue(v)
  local x = tonumber(v) or 0
  if x <= 0 then return 0 end        -- silence stays silent at every setting
  if x > 1 then x = 1 end
  local out = (x ^ Settings.rumbleCurve())
              * Settings.rumblePower()
              * Settings.rumbleTune()
  if out < 0 then return 0 elseif out > 1 then return 1 end
  return out
end

-- The GHOST GATE row as the shader's threshold. OFF is a hair above zero
-- rather than zero: a true zero makes smoothstep's edge degenerate.
local GHOST_GATE = { off = 0.001, low = 0.02, normal = 0.05, high = 0.12 }

function Settings.ghostGate()
  return GHOST_GATE[Settings.ghostgate:get()] or GHOST_GATE.normal
end

-- ------- how much light is in the room
--
-- Shared, because a room is a room. It started as a GBC-only row and did
-- nothing at all to the DMG path -- reported as "the GBC room lighting
-- controls don't affect DMG lighting scenarios", which was exactly true.
-- Both panels are reflective and neither makes light of its own, so ambient
-- level is a property of the ROOM rather than of either simulation.
--
-- The stored key is still `ptlight`. It is not worth renaming: the key is
-- invisible to the player and changing it would silently discard the value
-- of anyone who had already set it.
local ROOMLIGHT = {
  dim = 0.20, low = 0.32, normal = 0.48, bright = 0.58, sunlit = 0.65,
}
Settings.ROOMLIGHT_REF = 0.48

function Settings.roomLight()
  return ROOMLIGHT[Settings.ptlight:get()] or Settings.ROOMLIGHT_REF
end

-- As a multiplier on the reference level, which is what a pass wants.
function Settings.roomLightScale()
  return Settings.roomLight() / Settings.ROOMLIGHT_REF
end

-- Every picture pass asks this before it runs. See the SCREEN FX row.
function Settings.screenFxOn()
  return Settings.screenfx:get() ~= "off"
end

-- The dead-line seed as the number the shader hashes with. Spread apart so
-- consecutive rungs give unrelated panels rather than near-identical ones.
function Settings.deadSeed()
  return (tonumber(Settings.dmgdeadseed:get()) or 1) * 17.0
end

-- Category gates, by the ids lib/RumbleEvents asks for.
local CATEGORY = {
  battlefx = function() return Settings.rumblebattle end,
  story    = function() return Settings.rumblestory end,
  ambient  = function() return Settings.rumbleambient end,
  menus    = function() return Settings.rumblemenus end,
}

function Settings.rumbleCategory(name)
  local get = CATEGORY[name]
  if not get then return true end
  return get():get() == "on"
end

-- ------- reset just the picture effects
--
-- RESET ALL is the nuclear option and it takes the tilt setup with it -- the
-- source axes, the gains, the signs, the centring. Those are the settings
-- somebody spent real time on with the console in their hands, and wanting
-- the effects back to stock is not the same as wanting to tune the gyro
-- again from scratch.
--
-- Scoped by a FLAG on the group rather than by a list of keys, so a picture
-- pass added later is covered the moment it declares `fx = true` and a list
-- here cannot silently fall behind the menu. The two masters that govern the
-- passes go with them; MOTION and the tilt rows deliberately do not.
function Settings.resetFx(game)
  local done = {}
  for _, g in ipairs(Settings.groups) do
    if g.fx then
      for _, setting in ipairs(g.rows) do
        setting:setPos(setting:defaultIndex(), game, true)
        done[setting.key] = true
      end
    end
  end
  for _, setting in ipairs({ Settings.screenfx, Settings.ptlight }) do
    setting:setPos(setting:defaultIndex(), game, true)
    done[setting.key] = true
  end
  if game and game.writeOptions then pcall(game.writeOptions, game) end
  return done
end

-- Which settings RESET FX will touch, for the tests and for anything that
-- wants to reason about the split without performing it.
function Settings.fxKeys()
  local keys = {}
  for _, g in ipairs(Settings.groups) do
    if g.fx then
      for _, setting in ipairs(g.rows) do keys[setting.key] = true end
    end
  end
  keys[Settings.screenfx.key] = true
  keys[Settings.ptlight.key] = true
  return keys
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
