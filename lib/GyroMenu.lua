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

-- Put the picture effects back to stock and leave the tilt setup alone.
--
-- Same two-press arming as RESET ALL, and for a sharper reason: the two rows
-- sit next to each other and differ only in how much they destroy, so the
-- one that destroys less must still not be a single accidental press.
local function resetFxRow()
  local armed, flash = 0, 0
  return {
    id = "resetfx",
    label = "RESET FX",
    value = function()
      if flash > 0 then flash = flash - 1 return "DONE" end
      if armed > 0 then armed = armed - 1 return "SURE? A" end
      return "PRESS A"
    end,
    activate = function(game)
      if armed > 0 then
        Settings.resetFx(game)
        pcall(function() V.require("DmgPalette").apply() end)
        armed, flash = 0, 45
      else
        armed = 150
      end
    end,
    helpTitle = "RESET FX",
    helpBody = "Puts every effect that changes the picture back to how it "
      .. "started: the Game Boy screen, the Game Boy panel, the trail, the "
      .. "television, the tube, the colours and the room light. It does NOT "
      .. "touch how the console tilts, or the light that moves when you tilt "
      .. "it, so the setting up you did for the motion is safe. Press A one "
      .. "time to prepare. Press A again to do it. Use RESET ALL below to "
      .. "put back everything, motion included.",
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

-- A vibration you can feel while standing on the row that sets it.
--
-- Every other row on this mod's pages shows its effect on the screen the
-- moment it changes. This one cannot: the only way to know what 200% feels
-- like is to feel it, and the alternative is leaving the menu, finding a
-- battle, and coming back.
local function rumbleTestRow()
  local flash = 0
  return {
    id = "rumbletest",
    label = "RUMBLE TEST",
    value = function()
      if flash > 0 then flash = flash - 1 return "BUZZ" end
      return "PRESS A"
    end,
    activate = function()
      V.require("DeckRumble").test()
      flash = 30
    end,
    helpTitle = "RUMBLE TEST",
    helpBody = "Press A to feel the vibration at the strength on the RUMBLE "
      .. "AMP row. Use it to set that row without leaving this page. The "
      .. "pulse is the strength of a firm effect in the game, such as a hit "
      .. "in a battle. It is not the strongest the console can do.",
  }
end

-- What the RUMBLE page can and cannot see, for the same reason the SENSOR row
-- exists: a row that does nothing and a row that is working on a console with
-- no motor look identical from the inside.
local function rumbleStatusRow()
  return {
    id = "rumblestate",
    label = "MOTOR",
    value = function() return V.require("DeckRumble").status() end,
    step = function() return false end,
    helpTitle = "MOTOR",
    helpBody = "This row shows whether this page can change the vibration. "
      .. "DIRECT: the strong route to the console is open, which is what "
      .. "every value above STOCK uses. "
      .. "STOCK: running on the gentle route the game always used. "
      .. "NO HID: the strong route could not be opened, so the gentle one is "
      .. "used instead and the higher values will feel no stronger. "
      .. "NO PAD: the game cannot find a controller at all. "
      .. "OFF: the RUMBLE row is off.",
  }
end

-- Extra rows some group pages carry beyond their settings. Kept here rather
-- than in Settings because they are UI -- an action and a readout -- and
-- Settings is the list of stored values.
local PAGE_EXTRAS = {
  rumble = {
    before = { rumbleStatusRow },
    after  = { rumbleTestRow },
  },
}

-- One setting -> one row descriptor, with the two rows that carry more than
-- their value. `page` collects the swatch id, which belongs to whichever page
-- GLOW COLOUR ends up on rather than to the root.
local function settingRow(setting, page)
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
  -- The palette rewrite has to happen the moment the row moves. Our own page
  -- writes through Setting:setPos, which does NOT emit mod.options_changed --
  -- that event belongs to the manager's page -- so a row changed here would
  -- otherwise not take effect until the next launch.
  if setting.key == "dmgpal" then
    local base = row.step
    row.step = function(g, dir)
      local changed = base(g, dir)
      if changed then pcall(function() V.require("DmgPalette").apply() end) end
      return changed
    end
  end

  -- remembered by ID rather than by position: the row list grows, and a
  -- hardcoded index would put the swatches beside whatever moved into
  -- that slot next.
  --
  -- Two rows want a palette now, and they live on DIFFERENT pages (GLOW
  -- COLOUR on CRT TUBE, GLARE TINT on LIGHT FX), so one slot per page is
  -- still one strip on screen. Each records which palette is its own.
  if setting.key == "beamglowcol" then
    page.swatchRowId, page.swatchSetting = row.id, setting
    page.swatchPalette = nil -- nil means the tube palette, CrtBeam.GLOWCOL
  elseif setting.key == "glaretint" then
    page.swatchRowId, page.swatchSetting = row.id, setting
    page.swatchPalette = V.require("GbcLight").GLARETINT
  elseif setting.key == "ptback" then
    -- the plate behind the GBC panel: a colour row like the two above, so it
    -- gets the same strip -- the raw palette, because the swatch answers
    -- "which colour is this" and the brightness-normalised copy the shader
    -- receives answers a different question (see PixelTrans.backingColour)
    page.swatchRowId, page.swatchSetting = row.id, setting
    page.swatchPalette = V.require("PixelTrans").BACKING
  end
  return row
end

local function newPage(game, rows, page)
  local self = setmetatable({}, GyroMenu)
  self.game = game
  self.index = 1
  self.scroll = 0
  self.isOpaque = true
  self.rows = rows
  page = page or {}
  self.swatchRowId = page.swatchRowId
  self.swatchSetting = page.swatchSetting
  self.swatchPalette = page.swatchPalette
  return self
end

-- One group's page: its settings, plus whatever extras it declares.
function GyroMenu.group(game, group)
  local page = { swatchRowId = nil }
  local rows = {}
  local extras = PAGE_EXTRAS[group.id] or {}
  for _, make in ipairs(extras.before or {}) do rows[#rows + 1] = make() end
  for _, setting in ipairs(group.rows) do
    rows[#rows + 1] = settingRow(setting, page)
  end
  for _, make in ipairs(extras.after or {}) do rows[#rows + 1] = make() end
  return newPage(game, rows, page)
end

-- ------- the root page
--
-- Eleven rows where there were thirty-seven, and the two worth having without
-- opening anything are the first two.
--
-- SENSOR moved from the BOTTOM of the old list to the top. It was last, which
-- is the wrong end for the one row that answers "why is nothing happening" --
-- ASLEEP there means the gyro is off in Steam Input, a fix that is outside
-- the game entirely and cannot be guessed at from a dead effect. Nine pages
-- of scrolling stood between the player and that word.
--
-- AXIS MAP is second because it explains what every movement row below it
-- means, so it has to be found before them rather than after.
--
-- MOTION is third and stays on the root: it is the master switch, and a
-- master switch inside a submenu is a switch you cannot find in a hurry.
--
-- RECENTRE and RESET ALL stay on the root as well, at the bottom, because
-- they are ACTIONS rather than settings and do not belong to any one group.
function GyroMenu.new(game)
  local rows = {}
  local function add(row) rows[#rows + 1] = row end

  local st = statusRow()
  st.helpTitle, st.helpBody = "SENSOR",
    "This row shows the condition of the motion sensor. "
    .. "LIVE: the sensor works. "
    .. "ASLEEP: the sensor is off. Set Gyro Behavior to a value that is not "
    .. "Off in the Steam controller settings for this game. "
    .. "GBCFX OFF: the light effect is off. Increase GBC FX in the options "
    .. "menu. "
    .. "NO DEV: the game cannot find the console."
  add(st)

  -- Also a name with nothing under it, for the same reason the group rows
  -- are: it opens a page rather than holding a value. (It used to carry a
  -- `>`, which the font cannot draw, so it has always looked like this --
  -- the difference is that it is now deliberate.)
  add({
    id = "axismap",
    label = "AXIS MAP",
    activate = function(g) g.stack:push(V.require("AxisMap").new(g)) end,
    helpTitle = "AXIS MAP",
    helpBody = "This page shows the console and the light. The light moves "
      .. "when you move the console. Use this page to select the movement "
      .. "for each direction.",
  })

  local page = { swatchRowId = nil }
  for _, setting in ipairs(Settings.top) do add(settingRow(setting, page)) end

  -- One row per group: the category name and nothing under it. No `value`
  -- function at all, which OptionRows renders as an empty second line -- see
  -- the note in Settings.groups for why a mark and a summary were both worse.
  for _, group in ipairs(Settings.groups) do
    add({
      id = "group:" .. group.id,
      label = group.label,
      activate = function(g) g.stack:push(GyroMenu.group(g, group)) end,
      helpTitle = group.label,
      helpBody = group.help,
    })
  end

  local rec = recentreRow()
  rec.helpTitle, rec.helpBody = "RECENTRE",
    "This row moves the light to the centre of the screen. It uses the "
    .. "angle of the console at the time you press A. Then you can tilt the "
    .. "console to move the light. See QUICK CENTRE on the TILT SETUP page "
    .. "to do this with a button."
  add(rec)

  add(resetFxRow())

  local rst = resetRow()
  rst.helpTitle, rst.helpBody = "RESET ALL",
    "This row sets EVERY row on this page and on all the pages it opens back "
    .. "to its initial value, including how the console tilts. It also "
    .. "removes the centre angle that RECENTRE sets. Use RESET FX above "
    .. "instead if you only want the picture effects back to how they "
    .. "started. Press A one time to prepare. Press A again to do it."
  add(rst)

  return newPage(game, rows, page)
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

-- GLOW COLOUR shows its colours, not just their names.
--
-- 9300K means nothing to anyone who has not lined a monitor up, and AMBER
-- against GREEN against 5500K is not a choice anybody can make from five
-- letters. So the row carries a strip of the actual colours with a mark
-- under the chosen one -- the same job the measured readout does on CRT
-- ROLL: put the thing you need in order to choose next to the choice.
--
-- The strip cannot be drawn here. This page draws into the Game Boy
-- framebuffer, which PaletteFX then remaps by SHADE -- so a colour drawn
-- here arrives as a grey. What this does instead is publish WHERE the row
-- is, and GbcLight draws the strip after the frame is composed and past the
-- palette. See drawSwatches there.
--
-- Published only when the row is actually on screen: a request carrying a
-- slot that has scrolled away would draw the strip against the wrong row.
function GyroMenu:publishSwatches()
  local OptionRows = require("src.ui.OptionRows")
  local scroll = self.scroll or 0
  local okB, CrtBeam = pcall(V.require, "CrtBeam")
  if not okB or not CrtBeam then return end
  for slot = 1, OptionRows.VISIBLE do
    local row = self.rows[scroll + slot]
    if row and row.id == self.swatchRowId and self.swatchSetting then
      -- values and index come from the page's OWN setting, so adding a
      -- second colour row did not mean a second copy of this loop
      CrtBeam.swatchStrip = {
        slot = slot,
        values = self.swatchSetting.values,
        index = self.swatchSetting:pos(),
        palette = self.swatchPalette,
      }
      return
    end
  end
end

function GyroMenu:draw()
  local OptionRows = require("src.ui.OptionRows")
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "BACK", #self.rows + 1)
  self:publishSwatches()

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
