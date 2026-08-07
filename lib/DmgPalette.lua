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

local original = nil   -- the engine's own four triples, copied at install
local target = nil     -- the live PaletteFX.CLASSIC table
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

function DmgPalette.install()
  if original or failure then return original ~= nil end
  local ok, PaletteFX = pcall(require, "src.render.PaletteFX")
  if not ok or type(PaletteFX) ~= "table" then
    failure = "NO HOOK" return false
  end
  local classic = PaletteFX.CLASSIC
  if not looksRight(classic) then failure = "NO HOOK" return false end

  original = {}
  for i = 1, 4 do
    original[i] = { classic[i][1], classic[i][2], classic[i][3] }
  end
  target = classic
  return true
end

-- Values stored by an earlier build, mapped to the id they are now called.
-- Dropping this would read an unrecognised value, fall back to the default,
-- and silently switch the palette off for anyone who had chosen it.
DmgPalette.ALIASES = { brickboy = "realdmg" }

-- Write `name`'s colours in, or the engine's own back when it is nil/off.
local function write(name)
  if not target then return false end
  name = DmgPalette.ALIASES[name] or name
  local src = (name and name ~= "off") and DmgPalette.PALETTES[name] or original
  if not looksRight(src) then return false end
  local changed = false
  for i = 1, 4 do
    for j = 1, 3 do
      if target[i][j] ~= src[i][j] then
        target[i][j] = src[i][j]
        changed = true
      end
    end
  end
  return changed
end

-- The engine bakes sprites, maps and battle art against the palette, so a
-- change has to invalidate the same three caches PaletteFX.setMode does --
-- otherwise the new colours appear only on things drawn after the switch and
-- the screen ends up half in each palette.
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
  if not original then return DmgPalette.install() and "OFF" or (failure or "OFF") end
  local ok, Settings = pcall(function() return V.require("Settings") end)
  if ok and Settings and Settings.dmgpal and Settings.dmgpal:get() ~= "off" then
    return "ON"
  end
  return "OFF"
end

-- for the tests
function DmgPalette.originalColours() return original end
function DmgPalette.liveColours() return target end

return DmgPalette
