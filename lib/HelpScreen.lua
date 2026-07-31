-- A full page of plain English for one setting.
--
-- The row labels on the gyro page are short because they have to be: the
-- screen is 160px and the font advances 8, so a row that also shows a value
-- affords about ten characters for its name.  "SIDEWAYS AMT" is not a
-- description, and no amount of rewording makes it one inside that budget.
--
-- Rather than spend two menu rows on a cramped two-line caption -- which
-- still only affords ~34 characters -- SELECT opens this.  A whole screen
-- costs nothing until it is asked for, and it has room to say what the
-- setting is FOR rather than what it is called.

local V = ...

local HelpScreen = {}
HelpScreen.__index = HelpScreen

local MARGIN = 8
local TOP = 30
local LINE = 12
local GLYPH_H = 8              -- a drawn line occupies y .. y + GLYPH_H - 1
local FOOTER_Y = 130           -- where "B: BACK" sits

-- Last y a body line may START at, derived from the footer rather than
-- guessed: a line at 126 runs to 133 and printed straight through the
-- footer at 130.  Two pixels of air so they read as separate rows.
local BOTTOM = FOOTER_Y - GLYPH_H - 2
local VISIBLE = math.floor((BOTTOM - TOP) / LINE) + 1
local LAST_Y = TOP + (VISIBLE - 1) * LINE

-- Exposed so the layout can be asserted rather than eyeballed.
HelpScreen.METRICS = { top = TOP, line = LINE, glyphH = GLYPH_H,
                       footerY = FOOTER_Y, visible = VISIBLE, bottom = BOTTOM }

-- Wrap on glyph advances, not byte counts.  Font.width understands the
-- charmap's multi-byte entries; #text does not, and would wrap short.
local function wrap(text, budget)
  local Font = require("src.render.Font")
  local lines, line = {}, nil
  for word in tostring(text or ""):gmatch("%S+") do
    local try = line and (line .. " " .. word) or word
    if Font.width(try) <= budget then
      line = try
    else
      if line then lines[#lines + 1] = line end
      line = word
    end
  end
  if line then lines[#lines + 1] = line end
  return lines
end

function HelpScreen.new(game, title, body)
  local self = setmetatable({}, HelpScreen)
  self.game = game
  self.title = title or ""
  self.isOpaque = true
  self.lines = wrap(body, 160 - MARGIN * 2)
  self.scroll = 0
  return self
end

-- Match the page it was opened from, so this reads as the same screen
-- rather than a different program.
function HelpScreen:sgbPalettes(game)
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok or not PaletteFX.wholeNamed then return nil end
  return PaletteFX.wholeNamed(game.data, "MEWMON")
end

function HelpScreen:maxScroll()
  return math.max(0, #self.lines - VISIBLE)
end

function HelpScreen:update()
  local input = self.game.input
  -- Scrolling, because the text is written to explain rather than to fit.
  -- Without it a long description silently lost its tail off the bottom of
  -- the page, which is worse than no description: it reads as complete.
  if input:wasPressed("down") then
    self.scroll = math.min(self.scroll + 1, self:maxScroll())
  elseif input:wasPressed("up") then
    self.scroll = math.max(self.scroll - 1, 0)
  elseif input:wasPressed("b") or input:wasPressed("a")
      or input:wasPressed("start") or input:wasPressed("select") then
    self.game.stack:pop()
  end
end

function HelpScreen:draw()
  local Font = require("src.render.Font")
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)

  Font.draw(self.title, MARGIN, 8)
  -- rule under the title, so the heading reads as a heading at this size
  love.graphics.rectangle("fill", MARGIN, 22, 160 - MARGIN * 2, 1)

  for row = 0, VISIBLE - 1 do
    local line = self.lines[self.scroll + row + 1]
    if not line then break end
    Font.draw(line, MARGIN, TOP + row * LINE)
  end

  -- Say so when there is more, and which way: a page that silently ends
  -- mid-sentence is indistinguishable from one that finished.
  if self.scroll > 0 then Font.draw("^", 152, TOP) end
  if self.scroll < self:maxScroll() then Font.draw("v", 152, LAST_Y) end

  -- rule above the footer, so a full page of text cannot look like it runs
  -- into the button hint even when it stops right above it
  love.graphics.rectangle("fill", MARGIN, FOOTER_Y - 5, 160 - MARGIN * 2, 1)
  Font.draw("B: BACK", MARGIN, FOOTER_Y)
end

return HelpScreen
