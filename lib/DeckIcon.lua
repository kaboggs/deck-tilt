-- The little console that tilts, beside the mod's name on the OPTIONS menu.
--
-- ------- why an icon at all
--
-- `SD-GYRO` is now the first row on the OPTIONS menu, which is a good place
-- for a front door and a slightly rude one to take from the engine.  The icon
-- is what earns it: it says at a glance that the row belongs to a mod and
-- what the mod is about, without a word of explanation and without making the
-- label longer.  It tilts because that is the whole feature in one gesture.
--
-- ------- it is the AXIS MAP's console, scaled down
--
-- Not a second drawing of the same object.  `DeckSprite` already holds the
-- console as pixel art -- the screen, both sticks, the d-pad, the face
-- buttons, the grips -- and it is the one the player meets on the AXIS MAP
-- page.  Two hand-drawn consoles in one mod would drift apart the moment
-- either was touched, and the smaller one would lose the buttons first,
-- which are most of what makes it read as a Steam Deck rather than as a
-- rounded rectangle.
--
-- So this draws DeckSprite's image at a reduced scale and adds the tilt.
-- There is one console in this mod and this is a smaller view of it.
--
-- ------- black and white art, drawn UNDER the filters like any other sprite
--
-- It goes into the Game Boy framebuffer with the rest of the row, so
-- PaletteFX colourises it and the RF and CRT passes then land on it exactly
-- as they land on the text beside it.  With a phosphor mask running it picks
-- up the mask; that is not the icon going wrong, that is the icon being on
-- the same screen as everything else.  Drawing it over the finished frame
-- instead was tried and is the wrong answer: it makes the one thing on the
-- menu that ignores the television you have spent eleven rows building.
--
-- The ART is black and white, and that is what has to be kept.  Nothing here
-- introduces a colour of its own -- the sprite is DMG shades in and DMG
-- shades out, and every colour you see on it came from the palette or the
-- mask, which is the same place the colour on the label came from.
--
-- Nearest filtering is what keeps that true through the scale and the
-- rotation.  Both resample, and a FILTERED pixel is a blend of two shades,
-- which lands between them and comes out of the colouriser as something
-- nobody chose.  Nearest only ever returns a shade that was already in the
-- art, at any angle and any scale.  DeckSprite already sets it, and this
-- does not set a filter of its own, so there is one place to get it wrong.

local V = ...

local DeckIcon = {}

-- ------- how big, and why not smaller
--
-- The row's label sits at x=16 and `SD-GYRO` is seven glyphs of 8px, so it
-- ends at 72. That leaves the strip from 80 to the box's right edge, and the
-- icon is sized to fit it rather than to a number that looked nice.
--
-- There is a floor and a ceiling and the useful range between them is narrow.
--
-- 0.5 was tried first and is below the floor: at half scale nearest sampling
-- drops every other pixel, and the buttons -- two and three pixels wide in
-- the source -- are the first thing to go. What is left is the shell and the
-- screen, which is the rounded rectangle this was meant not to be.
--
-- 0.65 kept the buttons and was over the ceiling: tilted, its corners reached
-- the drawn frame of the row's box, so the console looked wedged into the
-- row rather than sitting in it. 0.585 is that minus a tenth -- still well
-- clear of the point where the buttons go, and inside the frame at every
-- angle in the cycle. GAP below is what holds it there.
DeckIcon.SCALE = 0.585
DeckIcon.X = 80

-- A clear gap on every side, in Game Boy pixels, between the icon at its most
-- tilted and anything it could touch -- the drawn frame of the row's box
-- above and below, the label to its left.
--
-- Three and not one, because one is the gap that LOOKS like a mistake: a
-- sprite a single pixel off a border reads as having failed to line up,
-- where three reads as having been placed. It is asserted rather than
-- eyeballed because the thing that eats it is a scale or an angle changed
-- for an unrelated reason, and the tilt is what closes it -- the icon fits
-- level at sizes that foul the frame at the ends of the cycle.
DeckIcon.GAP = 3

-- How far it tips, in radians. About 7 degrees: enough to read as a tilt at
-- this size, little enough that the corners stay inside the strip.
DeckIcon.ANGLE = 0.12

-- ------- why the tilt is stepped rather than continuous
--
-- A sine of the clock is the obvious way to rock something and it is wrong
-- here for the same reason the filter is: every intermediate angle resamples
-- the art differently, so the sprite's edges crawl and shimmer from frame to
-- frame while the console barely moves. Three fixed angles hold still
-- between steps -- each one is a stable picture the eye can settle on -- and
-- the motion happens in the change, which is what animation is anyway.
--
-- LEFT, LEVEL, RIGHT, LEVEL: it rocks THROUGH the middle rather than
-- snapping between the extremes, which is four steps of movement out of
-- three angles.
DeckIcon.CYCLE = { -1, 0, 1, 0 }

-- Seconds per step. Slow enough to read as a console being tilted rather
-- than as something flashing for attention: this sits on a menu a player is
-- trying to read, and an icon that demands the eye is worse than no icon.
DeckIcon.FRAME_TIME = 0.42

-- Which step is showing, from the wall clock.
--
-- The clock and not a counter, because this is drawn from a DRAW hook and
-- nothing here is guaranteed to be called once per logic step -- a menu that
-- redraws twice in a frame would run the animation at double speed off a
-- counter, and one that skips a draw would stall it. Time is the only thing
-- that advances correctly regardless of how often anyone asks.
function DeckIcon.frameAt(t)
  local n = #DeckIcon.CYCLE
  return (math.floor((t or 0) / DeckIcon.FRAME_TIME) % n) + 1
end

function DeckIcon.angleAt(t)
  return DeckIcon.CYCLE[DeckIcon.frameAt(t)] * DeckIcon.ANGLE
end

-- The drawn size, which the row geometry has to fit around.
function DeckIcon.size()
  local DeckSprite = V.require("DeckSprite")
  return DeckSprite.W * DeckIcon.SCALE, DeckSprite.H * DeckIcon.SCALE
end

-- ------- getting it onto a row
--
-- OptionRows.draw is the engine's own renderer and takes no per-row draw
-- hook, so there is nowhere to hand a picture to. It is wrapped instead --
-- the same move this mod already makes on GBCFX.present and Game.keypressed,
-- and for the same reason: the engine's function keeps doing its whole job
-- and we add one thing after it.
--
-- Wrapping rather than reimplementing matters here. The row geometry, the
-- scroll clamping and the viewport all stay the engine's, so the icon cannot
-- drift out of step with the row it is drawn beside -- it is positioned FROM
-- the same numbers the label was, every frame.
--
-- It lands on both menus for free, because the SD-GYRO page is built on
-- OptionRows too. That is deliberate: the icon marks the mod's own row on
-- the engine's menu, and the mod's own page carries no such row, so nothing
-- is drawn there and nothing needed a special case to stop it.
local ROW_ID = "DECK_TILT:gyro"
local installed = false

function DeckIcon.install()
  if installed then return end
  local ok, OptionRows = pcall(require, "src.ui.OptionRows")
  if not ok or type(OptionRows) ~= "table"
     or type(OptionRows.draw) ~= "function" then
    return
  end
  installed = true
  local inner = OptionRows.draw
  OptionRows.draw = function(game, rows, index, scroll, bottomLabel, bottomRow)
    inner(game, rows, index, scroll, bottomLabel, bottomRow)
    -- pcall'd whole: an icon is decoration, and decoration may not be able to
    -- take a menu down. If this throws once it simply does not draw.
    pcall(DeckIcon.drawOnRows, rows, scroll)
  end
end

-- Which visible slot the SD-GYRO row is in this frame, or nil if it is not on
-- screen. Cleared as it is consumed, so the icon cannot outlive the menu that
-- asked for it by even one frame.
DeckIcon.slot = nil

function DeckIcon.mark(rows, scroll)
  DeckIcon.slot = nil
  if type(rows) ~= "table" then return end
  local OptionRows = require("src.ui.OptionRows")
  scroll = scroll or 0
  for slot = 1, OptionRows.VISIBLE do
    local row = rows[scroll + slot]
    if not row then return end
    if row.id == ROW_ID then DeckIcon.slot = slot return end
  end
end

-- Where the icon's centre goes, in Game Boy pixels, for a given slot. Split
-- out so the gap can be asserted against the same arithmetic the frame uses
-- rather than against a restatement of it.
function DeckIcon.centreFor(slot)
  local w = DeckIcon.size()
  -- Centred in the row's 32px box rather than pinned to the label's
  -- baseline: the sprite is taller than one 8px line and is rotated about
  -- its own middle, so its middle is the thing that has to be placed.
  return DeckIcon.X + w * 0.5, (slot - 1) * 4 * 8 + 16
end

-- Drawn straight into the Game Boy framebuffer, in its own coordinates --
-- the same 160x144 space OptionRows just drew the label in, so the icon
-- needs no scale factor and no offset of its own and cannot drift from the
-- row when the window changes size.
function DeckIcon.drawOnRows(rows, scroll)
  DeckIcon.mark(rows, scroll)
  local slot = DeckIcon.slot
  if not slot then return end
  local DeckSprite = V.require("DeckSprite")
  local img = DeckSprite.image()
  if not img then return end

  local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local cx, cy = DeckIcon.centreFor(slot)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(img, cx, cy, DeckIcon.angleAt(t),
                     DeckIcon.SCALE, DeckIcon.SCALE,
                     DeckSprite.W * 0.5, DeckSprite.H * 0.5)
end

return DeckIcon
