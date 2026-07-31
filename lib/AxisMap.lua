-- AXIS MAP: which movement drives which direction, shown rather than named.
--
-- "SIDEWAYS = SPIN-H" tells you nothing about what to do with your hands, so
-- this page draws the console and puts each rotation on it as an arc in the
-- plane you would actually move it -- TURN arcing over the top, TIP arcing
-- down the side, TWIST circling beside the face -- each labelled where it is.
-- Greyscale throughout: see sgbPalettes for why colour was dropped.
--
-- An abstract X/Y/Z gnomon was tried first and rejected: it answers "what are
-- the axes called", which nobody asked, rather than "which way do I turn it".
-- A separate colour key went the same way -- it makes the reader hold three
-- colours in their head and look twice, where a word beside the motion needs
-- no looking up at all and the colour merely reinforces it.
--
-- The light dot inside the console's own little screen is fed from the real
-- sensor, so tilting the Deck in your hands moves it while you read the rows.
-- That makes this a debugging tool as much as a settings page: mapping, sign
-- and current value are all visible at once.

local V = ...
local Settings = V.require("Settings")
local Motion = V.require("Motion")
local Imu = V.require("Imu")
local DeckSprite = V.require("DeckSprite")

local AxisMap = {}
AxisMap.__index = AxisMap

local SH = DeckSprite.SHADE

-- Console placement.  Everything else is laid out around it, and the tile
-- rects in sgbPalettes below depend on these -- a zone that overlaps the
-- console would recolour the hardware, and one that clips an arc makes the
-- arc change colour halfway along rather than simply ending.
local DX, DY = 40, 32
local DW, DH = DeckSprite.W, DeckSprite.H

local ROWS = {
  { label = "SIDEWAYS",     key = "srcx",  src = "srcx" },
  { label = "SIDEWAYS +/-", key = "signx", src = "srcx" },
  { label = "UP/DOWN",      key = "srcy",  src = "srcy" },
  { label = "UP/DOWN +/-",  key = "signy", src = "srcy" },
}
local ROW_Y = { 88, 100, 112, 124 }

-- Which drawn rotation each selectable source corresponds to.  FLAT is the
-- gravity vector's third component and TWIST the gyro's, and both describe
-- rotation about the screen normal, so both light up the roll arc.
-- Source id -> which arc on the diagram it is.  These must track the source
-- names in Settings: the arcs are the only explanation of what the words on
-- the rows mean, so a stale label here is worse than no diagram.
local ROT_OF = {
  turn = "yaw",    spiny = "yaw",     -- about the vertical centre line
  tip  = "pitch",  spinx = "pitch",   -- about the horizontal width line
  twist = "roll",                     -- raising one side
}

function AxisMap.new(game)
  local self = setmetatable({}, AxisMap)
  self.game = game
  self.index = 1
  self.t = 0
  self.isOpaque = true
  return self
end

-- ONE greyscale zone over the whole diagram, and no colour anywhere.
--
-- Per-rotation colour was tried and dropped.  Colour only exists in this
-- renderer as a four-shade palette applied to a rectangle, so three coloured
-- arcs meant three rectangles -- and a rectangle cannot follow an arc.  Every
-- head, label and curve that strayed a pixel past its rect did not clip, it
-- CHANGED COLOUR partway along, which reads as corruption rather than as
-- overflow.  Overlapping rects also made the result depend on the order they
-- were added, so the console itself picked up a tint from a neighbouring
-- zone.  Fragile to place, and the payoff was redundant: each arc is already
-- labelled where it sits, and the one being edited already pulses.
--
-- A single grey rect over the whole diagram cannot have a boundary problem,
-- because nothing in the diagram is outside it.  PaletteFX.GRAYS is the
-- engine's own 255/170/85/0, exactly the values the art is drawn in, so the
-- console also stops inheriting whatever the player set COLORS to.
function AxisMap:sgbPalettes(game)
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok then return nil end
  local zones = PaletteFX.wholeNamed(game.data, "MEWMON") or {}
  local grey = PaletteFX.zone(PaletteFX.GRAYS, 0, 1, 19, 8)
  if grey then zones[#zones + 1] = grey end
  return zones
end

function AxisMap:update(dt)
  self.t = self.t + (dt or 0)
  local input = self.game.input
  local n = #ROWS

  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or n
  elseif input:wasPressed("down") then
    self.index = self.index < n and self.index + 1 or 1
  elseif input:wasPressed("left") or input:wasPressed("right") then
    local dir = input:wasPressed("left") and -1 or 1
    local setting = Settings[ROWS[self.index].key]
    if setting then
      setting:setPos(setting:pos() + dir, self.game)
      if self.game.writeOptions then self.game:writeOptions() end
    end
  elseif input:wasPressed("select") then
    self.game.stack:push(V.require("HelpScreen").new(self.game, "GYRO SETUP",
      "This needs the console's motion sensor switched on, which is a Steam "
      .. "setting, not a game one. Hold the STEAM button, open Controller "
      .. "Settings for this game, and set Gyro Behavior to anything other "
      .. "than Off. The sensor row reads LIVE once it is on."))
  elseif input:wasPressed("b") or input:wasPressed("start")
      or input:wasPressed("a") then
    self.game.stack:pop()
  end
end

-- An elliptical arc with a head on the leading end.  Ellipses rather than
-- circles because these stand for rotations seen edge-on: a yaw seen from
-- in front is a wide, flat sweep, not a circle.
local function arc(cx, cy, rx, ry, a1, a2, thick)
  local steps = 18
  local px, py
  for i = 0, steps do
    local a = a1 + (a2 - a1) * i / steps
    local x, y = cx + math.cos(a) * rx, cy + math.sin(a) * ry
    if px then
      love.graphics.line(px, py, x, y)
      if thick then love.graphics.line(px, py + 1, x, y + 1) end
    end
    px, py = x, y
  end
  -- head: a small wedge along the tangent at the far end
  local a = a2
  local tx, ty = -math.sin(a) * rx, math.cos(a) * ry
  local len = math.sqrt(tx * tx + ty * ty)
  if len > 0 then
    tx, ty = tx / len, ty / len
    local hx, hy = cx + math.cos(a) * rx, cy + math.sin(a) * ry
    local nx, ny = -ty, tx
    love.graphics.polygon("fill",
      hx + tx * 4, hy + ty * 4,
      hx - tx * 2 + nx * 3, hy - ty * 2 + ny * 3,
      hx - tx * 2 - nx * 3, hy - ty * 2 - ny * 3)
  end
end

function AxisMap:drawRotations(active)
  -- With colour gone, the row being edited is picked out by weight instead:
  -- its arc thickens on a slow blink.  That survives greyscale, colour
  -- blindness and a dim screen, none of which a hue does.
  local pulse = math.floor(self.t * 4) % 2 == 0
  local function set(on)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.setLineWidth(1)
    return on and pulse
  end

  local Font = require("src.render.Font")

  -- Each arc is LABELLED WHERE IT IS.  With no colour to lean on, position
  -- and the word carry the whole meaning -- which they did anyway; the hues
  -- were only ever repeating what the layout already said.

  -- TURN: about the screen's vertical axis. A flat sweep over the top, which
  -- is what that rotation looks like from where the player is sitting.
  local thick = set(active == "yaw")
  arc(80, 29, 29, 6, math.pi * 1.20, math.pi * 1.80, thick)
  Font.draw("TURN", 64, 10)

  -- TIP: top edge towards or away. A tall narrow sweep beside the console,
  -- that rotation seen from the left.
  thick = set(active == "pitch")
  arc(28, 50, 6, 12, -math.pi * 0.40, math.pi * 0.40, thick)
  Font.draw("TIP", 4, 44)

  -- SIDE: raising one side, about the screen face.  Nearly a full circle,
  -- since this rotation is seen face-on.  Held upright this is the only
  -- sideways gesture gravity can see -- turning it like a page spins around
  -- the gravity vector and leaves the reading unchanged.
  thick = set(active == "roll")
  arc(138, 48, 9, 9, math.pi * 0.25, math.pi * 1.75, thick)
  Font.draw("SIDE", 128, 62)
end

-- When the sensor is not live nothing on this page moves, and the reason is
-- outside the game entirely -- so say so here, and say where to go, rather
-- than leaving a dead diagram and a status word nobody can act on.
function AxisMap:drawSensorNote()
  local Font = require("src.render.Font")
  if Imu.status == "LIVE" or Imu.status == "FAKE" then return end
  love.graphics.setColor(0, 0, 0, 1)
  local msg = (Imu.status == "ASLEEP") and "GYRO IS OFF" or "NO SENSOR"
  Font.draw(msg, 8, 68)
  Font.draw("SELECT: HOW TO FIX", 8, 78)
end

function AxisMap:draw()
  local Font = require("src.render.Font")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw("AXIS MAP", 8, 0)

  local img = DeckSprite.image()
  if img then
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, DX, DY)
  end

  -- the live light, inside the console's own screen.  A soft falloff rather
  -- than a dot, because that is what the effect looks like on the real
  -- screen; scissored so the glow cannot spill onto the bezel.
  local S = DeckSprite.SCREEN
  local lx = Motion.lastLightX and Motion.lastLightX() or 0.5
  local ly = Motion.lastLightY and Motion.lastLightY() or 0.5
  local px = DX + S.x + math.max(0, math.min(1, lx)) * S.w
  local py = DY + S.y + math.max(0, math.min(1, ly)) * S.h
  love.graphics.setScissor(DX + S.x, DY + S.y, S.w, S.h)
  for _, ring in ipairs({ { 7, 2 }, { 4.5, 1 }, { 2, 0 } }) do
    local g = SH[ring[2]]
    love.graphics.setColor(g, g, g, 1)
    love.graphics.circle("fill", px, py, ring[1])
  end
  love.graphics.setScissor()

  local srcSetting = Settings[ROWS[self.index].src]
  self:drawRotations(ROT_OF[srcSetting and srcSetting:get() or ""])
  self:drawSensorNote()

  love.graphics.setColor(0, 0, 0, 1)
  for i, row in ipairs(ROWS) do
    local y = ROW_Y[i]
    local setting = Settings[row.key]
    local value = setting and setting:text() or "?"
    if i == self.index then Font.draw(">", 2, y) end
    Font.draw(row.label, 10, y)
    Font.draw(value, 160 - 8 - Font.width(value), y)
  end

  Font.draw("B:BACK", 2, 136)
  -- proof the recentre button is reaching the game at all
  Font.draw("RC:" .. tostring(Motion.recentreCount or 0), 52, 136)
  local st = Imu.status or ""
  Font.draw(st, 160 - 8 - Font.width(st), 136)
end

return AxisMap
