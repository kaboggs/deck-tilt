-- Replace what the engine's CLASSIC colour mode looks like, without touching
-- the engine.
--
-- ------- what is wrong with the built-in one
--
-- `PaletteFX.CLASSIC` is the pea-green everybody uses for "original Game Boy":
--
--     155,188,15   139,172,15   48,98,48   15,56,15
--
-- Those four numbers are a convention rather than a measurement. They come
-- from the web-safe-era approximation that spread through emulators, and the
-- top two are nearly the same colour -- 155,188,15 against 139,172,15 is a
-- sixteen-point difference on one channel -- so the lightest two shades of the
-- picture very nearly collapse into one. A real DMG separates them clearly.
--
-- ------- what replaces it
--
-- The palette measured from real hardware:
--
--     219,207,136  140,179,102  71,130,66  33,92,43
--
-- Two things are different and both matter. It is WARMER -- the lightest
-- shade is a pale khaki, not a yellow-green, because the unlit panel is a
-- reflector behind a green LC layer and what you see is room light coming
-- back through it. And it is properly SEPARATED: the four shades step evenly
-- instead of bunching at the light end, which is what makes text on a real
-- DMG readable.
--
-- ------- how it is applied, and why this way
--
-- The engine reads PaletteFX.CLASSIC live, inside the function that builds a
-- zone (PaletteFX.lua, `out = PaletteFX.CLASSIC`), so the values can simply
-- be rewritten. Three rules make that safe rather than a hack:
--
--   * The TABLE is mutated in place, never reassigned. Anything that captured
--     a reference to it keeps working and sees the new values.
--   * The engine's own numbers are copied out first, so OFF restores exactly
--     what shipped rather than a remembered approximation of it.
--   * Nothing is written to an engine FILE. update.sh rsyncs --delete over
--     game/ and would revert an edit; this survives because it lives here.
--
-- Future-proofing, since this reaches into another module's data: every step
-- is guarded and the whole thing degrades to doing nothing. If a future
-- engine renames CLASSIC, drops it, or changes its shape from four RGB
-- triples, `install` refuses and the row reports NO HOOK instead of writing
-- nonsense into the palette.
--
-- Adding another palette is one entry in PALETTES and one label on the row.

local V = ...

local DmgPalette = {}

-- Lightest shade first, matching PaletteFX's own ordering.
DmgPalette.PALETTES = {
  -- measured from real hardware
  realdmg = {
    { 219, 207, 136 }, { 140, 179, 102 }, { 71, 130, 66 }, { 33, 92, 43 },
  },
}

-- TWO engines, two CLASSIC tables.
--
-- Gen 1 presents CLASSIC through src/render/PaletteFX.lua's `PaletteFX.CLASSIC`.
-- Gold does not read that table at all: src/core/Game2.lua's present pass asks
-- src/render/GbcPalette.lua for `GbcPalette.presentColors()`, which hands back
-- its own private CLASSIC_SHADES. Both hold the identical pea-green ramp
-- (155,188,15 / 139,172,15 / 48,98,48 / 15,56,15), so the measured palette is
-- the right answer for either -- but writing only PaletteFX left Gold's screen
-- untouched, which is the whole reason this file grew a list.
--
-- `targets` is every live table found; `originals[i]` is the shipped copy of
-- targets[i]. A boot finds one of them (Gen 1 has no GbcPalette in its render
-- path; a Gold boot still has PaletteFX loaded but unused) or both, and OFF
-- restores each from its own snapshot rather than from a shared assumption.
local originals = {}   -- the engines' own four triples, copied at install
local targets = {}     -- the live CLASSIC tables, written in place
local failure = nil

local function looksRight(t)
  if type(t) ~= "table" or #t ~= 4 then return false end
  for i = 1, 4 do
    local c = t[i]
    if type(c) ~= "table" or #c ~= 3 then return false end
    for j = 1, 3 do
      if type(c[j]) ~= "number" then return false end
    end
  end
  return true
end

-- Take a live table under our wing: snapshot it, then keep the reference.
local function adopt(t)
  if not looksRight(t) then return end
  for _, seen in ipairs(targets) do
    if seen == t then return end          -- same table via two names
  end
  local snap = {}
  for i = 1, 4 do snap[i] = { t[i][1], t[i][2], t[i][3] } end
  targets[#targets + 1] = t
  originals[#originals + 1] = snap
end

-- Gold keeps CLASSIC_SHADES as a local and only returns it from
-- presentColors() when the COLOR mode is already CLASSIC. Borrowing the mode
-- for the length of one call is how the reference is reached without the
-- player having to be in that mode -- it is restored before anything can draw,
-- and pcall'd so a throw cannot strand the setting.
local function gbcClassicTable()
  local ok, Gbc = pcall(require, "src.render.GbcPalette")
  if not ok or type(Gbc) ~= "table" or type(Gbc.presentColors) ~= "function" then
    return nil
  end
  local prev = Gbc.mode
  local okCall, shades = pcall(Gbc.presentColors)
  if not okCall or not looksRight(shades) then
    Gbc.mode = "classic"
    okCall, shades = pcall(Gbc.presentColors)
    Gbc.mode = prev
  end
  return okCall and shades or nil
end

function DmgPalette.install()
  if #targets > 0 or failure then return #targets > 0 end

  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if ok and type(PaletteFX) == "table" then adopt(PaletteFX.CLASSIC) end

  adopt(gbcClassicTable())

  if #targets == 0 then failure = "NO HOOK" return false end
  return true
end

-- Ids stored by an earlier build, mapped to what they are called now. Empty:
-- this row did not exist in any released version, so nothing is stored under
-- an older name. Kept as the place to put one if that ever changes, because
-- an unrecognised value falls back to the default and would silently switch
-- somebody's palette off.
DmgPalette.ALIASES = {}

-- Write `name`'s colours in, or the engine's own back when it is nil/off.
local function write(name)
  if #targets == 0 then return false end
  name = DmgPalette.ALIASES[name] or name
  local named = (name and name ~= "off") and DmgPalette.PALETTES[name] or nil
  local changed = false
  for t = 1, #targets do
    -- OFF restores THIS table's own shipped values, not the other engine's.
    local src = named or originals[t]
    if looksRight(src) then
      local target = targets[t]
      for i = 1, 4 do
        for j = 1, 3 do
          if target[i][j] ~= src[i][j] then
            target[i][j] = src[i][j]
            changed = true
          end
        end
      end
    end
  end
  return changed
end

-- The engine bakes sprites, maps and battle art against the palette, so a
-- change has to invalidate the same three caches PaletteFX.setMode does --
-- otherwise the new colours appear only on things drawn after the switch and
-- the screen ends up half in each palette.
-- All three are Gen 1 seams and all three are pcall'd, so a Gold boot simply
-- finds nothing to call: src/ui/gen2/BattleState.lua has no invalidate and
-- Gold's overworld is src/world/gen2/Map.lua rather than MapLoader. That is
-- correct rather than a gap -- Gold substitutes the palette in the present
-- shader (Game2:blitZones), so nothing is baked against it and the next frame
-- already carries the new colours.
local function invalidate()
  pcall(function() require("src.battle.BattleState").invalidate() end)
  pcall(function() require("src.render.SpriteRenderer").invalidate() end)
  pcall(function() require("src.world.MapLoader").invalidateAll() end)
end

-- Bring the palette into line with the setting. Safe to call every frame;
-- it does nothing at all unless a value actually differs.
function DmgPalette.apply()
  if not DmgPalette.install() then return false end
  local name = "off"
  local ok, Settings = pcall(function() return V.require("Settings") end)
  if ok and Settings and Settings.dmgpal then
    local okV, v = pcall(function() return Settings.dmgpal:get() end)
    if okV and type(v) == "string" then name = v end
  end
  if write(name) then invalidate() return true end
  return false
end

-- What the row shows.
--   NO HOOK  the engine's palette is not the shape this can write to
--   ON/OFF   whether ours is in place
function DmgPalette.status()
  if failure then return failure end
  if #targets == 0 then return DmgPalette.install() and "OFF" or (failure or "OFF") end
  local ok, Settings = pcall(function() return V.require("Settings") end)
  if ok and Settings and Settings.dmgpal and Settings.dmgpal:get() ~= "off" then
    return "ON"
  end
  return "OFF"
end

-- for the tests
function DmgPalette.originalColours() return originals[1] end
function DmgPalette.liveColours() return targets[1] end
-- Every table adopted, so a test can assert Gold's got written too.
function DmgPalette.allTargets() return targets end

return DmgPalette
