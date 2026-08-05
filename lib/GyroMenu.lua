-- The SD-GYRO screen: everything this mod owns, on its own page.
--
-- It exists because the mod had grown to nine rows on the main OPTIONS menu,
-- which is more than the engine's entire display section, for a feature most
-- players will set once.  One row opens this instead.
--
-- Built on the engine's OWN row renderer (src/ui/OptionRows.lua) rather than
-- a hand-drawn list.  That module was extracted so the mod manager could
-- render option schemas "in the same idiom", and it takes exactly the
-- descriptor shape Setting:row() already emits:
--
--   { id, label, value = fn(game) -> string, step = fn(game, dir), activate }
--
-- So the page inherits the four-box viewport, the cursor, the scroll
-- clamping and the typography for free, and it cannot drift out of step with
-- the engine's look the way a copy would.  The update loop below mirrors
-- OptionsMenu:update for the same reason.

local V = ...
local Settings = V.require("Settings")
local Motion = V.require("Motion")
local GbcLight = V.require("GbcLight")

local GyroMenu = {}
GyroMenu.__index = GyroMenu

-- pushed directly rather than through the screens registry: the help page
-- takes arguments, and a registered screen id would have to smuggle them
local function mod_push(game, title, body)
  game.stack:push(V.require("HelpScreen").new(game, title, body))
end

-- A read-only row.  The sensor state is the first thing to look at when
-- nothing is happening, so it sits on the page rather than being buried:
-- ASLEEP means the gyro is not enabled in Steam Input, which is a fix
-- outside the game entirely and impossible to guess at from a dead effect.
local function statusRow()
  return {
    id = "status",
    label = "SENSOR",
    value = function() return GbcLight.status() end,
    step = function() return false end,
  }
end

-- Re-anchor "centre" to however the console is being held right now.
-- Rows report their own outcome because an action row that looks identical
-- before and after leaves you wondering whether the press registered.
local function recentreRow()
  local flash = 0
  return {
    id = "recentre",
    label = "RECENTRE",
    value = function()
      if flash > 0 then
        flash = flash - 1
        return "SET"
      end
      return "PRESS A"
    end,
    activate = function()
      Motion.recentre()
      flash = 30
    end,
  }
end

-- Two presses, not one.  Undoing a careful tune by brushing a button would
-- be a worse fault than the missing option this fixes, and the row is next
-- to RECENTRE, which is a single press -- so the two need to look different
-- at the moment of pressing, not just afterwards.
local function resetRow()
  local armed, flash = 0, 0
  return {
    id = "reset",
    label = "RESET ALL",
    value = function()
      if flash > 0 then flash = flash - 1 return "DONE" end
      if armed > 0 then armed = armed - 1 return "SURE? A" end
      return "PRESS A"
    end,
    activate = function(game)
      if armed > 0 then
        Settings.resetAll(game)
        -- the hand-set anchor is a setting in every sense except that it
        -- lives in Motion rather than the options table, so it goes too
        Motion.resetCentre()
        armed, flash = 0, 45
      else
        armed = 150 -- about two and a half seconds at 60fps
      end
    end,
  }
end

function GyroMenu.new(game)
  local self = setmetatable({}, GyroMenu)
  self.game = game
  self.index = 1
  self.scroll = 0
  self.isOpaque = true

  self.rows = {}
  local function add(row) self.rows[#self.rows + 1] = row end

  -- AXIS MAP sits directly under the master switch rather than at the end:
  -- it is the page that explains what every row below it means, so it has to
  -- be found before them, not after.
  local axisRow = {
    id = "axismap",
    label = "AXIS MAP",
    value = function() return ">" end,
    activate = function(g) g.stack:push(V.require("AxisMap").new(g)) end,
    helpTitle = "AXIS MAP",
    helpBody = "This page shows the console and the light. The light moves "
      .. "when you move the console. Use this page to select the movement "
      .. "for each direction.",
  }

  for _, setting in ipairs(Settings.order) do
    local row = setting:row()
    -- carried alongside the descriptor so SELECT has something to show;
    -- OptionRows ignores fields it does not know about
    row.helpTitle, row.helpBody = setting.label, setting.help
    -- CRT ROLL is the one setting whose usefulness depends on the DISPLAY
    -- rather than on the picture, and no player knows their refresh rate off
    -- hand. So the row carries the measurement next to its value, for the
    -- same reason SENSOR carries ASLEEP: the thing you need in order to know
    -- whether this setting can do anything is not visible from the setting.
    if setting.key == "beamroll" then
      local base = row.value
      row.value = function(g)
        local CrtBeam = V.require("CrtBeam")
        local note = CrtBeam.rollStatus()
        local text = base(g)
        return note and (text .. " " .. note) or text
      end
    end
    add(row)
    if setting.key == "motion" then add(axisRow) end
  end
  local rec = recentreRow()
  rec.helpTitle, rec.helpBody = "RECENTRE",
    "This row moves the light to the centre of the screen. It uses the "
    .. "angle of the console at the time you press A. Then you can tilt the "
    .. "console to move the light. See QUICK CENTRE to do this with a "
    .. "button."
  self.rows[#self.rows + 1] = rec

  local rst = resetRow()
  rst.helpTitle, rst.helpBody = "RESET ALL",
    "This row sets all the rows on this page to their initial values. It "
    .. "also removes the centre angle that RECENTRE sets. Press A one time "
    .. "to prepare. Press A again to do it."
  self.rows[#self.rows + 1] = rst

  local st = statusRow()
  st.helpTitle, st.helpBody = "SENSOR",
    "This row shows the condition of the motion sensor. "
    .. "LIVE: the sensor works. "
    .. "ASLEEP: the sensor is off. Set Gyro Behavior to a value that is not "
    .. "Off in the Steam controller settings for this game. "
    .. "GBCFX OFF: the light effect is off. Increase GBC FX in the options "
    .. "menu. "
    .. "NO DEV: the game cannot find the console."
  self.rows[#self.rows + 1] = st
  return self
end

-- Match the engine's own options page, including the palette, so this reads
-- as part of the game rather than as a mod's window.
function GyroMenu:sgbPalettes(game)
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok or not PaletteFX.wholeNamed then return nil end
  local zones = PaletteFX.wholeNamed(game.data, "MEWMON")
  return zones
end

-- Mirrors OptionsMenu:update.  BACK sits below the mod's rows for the same
-- reason CANCEL does there: a row list that can grow must never be able to
-- orphan the way out.
function GyroMenu:update(dt)
  local input = self.game.input
  local rows = self.rows
  local backRow = #rows + 1
  local changed = false

  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or backRow
  elseif input:wasPressed("down") then
    self.index = self.index < backRow and self.index + 1 or 1
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    local row = rows[self.index]
    if row and row.activate then
      if input:wasPressed("a") then row.activate(self.game) end
    elseif row and row.step then
      changed = row.step(self.game, dir) and true or false
    elseif input:wasPressed("a") then -- BACK
      self.game.stack:pop()
    end
  elseif input:wasPressed("select") then
    -- a whole page of plain English for the highlighted row.  The labels are
    -- short because a 160px screen with an 8px font leaves no room for them
    -- to be otherwise; this is where the explaining happens.
    local row = rows[self.index]
    if row and row.helpBody then
      mod_push(self.game, row.helpTitle, row.helpBody)
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    self.game.stack:pop()
  end

  if changed and self.game.writeOptions then
    self.game:writeOptions()
  end

  local OptionRows = require("src.ui.OptionRows")
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0,
                                       #rows, backRow)
end

-- The SELECT hint, exposed so its width can be asserted rather than eyeballed.
GyroMenu.HINT = "SELECT: MORE INFO"
GyroMenu.HINT_X = 8

function GyroMenu:draw()
  local OptionRows = require("src.ui.OptionRows")
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "BACK", #self.rows + 1)

  -- Every row has a page of plain English behind SELECT, which is worth
  -- nothing if nobody knows it is there.  OptionRows leaves this strip free:
  -- its four boxes end at 127 and the bottom label sits at 136.
  --
  -- x = HINT_X, not 16, and the text is short: a screenshot caught the older
  -- "SELECT: WHAT'S THIS" starting at 16 and running 8px past the 160px
  -- screen, so the last glyph was cut in half.  The width is asserted in the
  -- test suite now rather than left to eye.
  local Font = require("src.render.Font")
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(GyroMenu.HINT, GyroMenu.HINT_X, 128)
  love.graphics.setColor(1, 1, 1, 1)
end

return GyroMenu
