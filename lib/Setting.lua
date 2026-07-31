-- One of this mod's settings: an ordered ladder of values, the labels the
-- player cycles through, and the two rows that show it.
--
-- The engine hands a render pipeline its ladder, row, hotkey and
-- persistence for free, but only to something that owns a pass of the
-- frame.  This mod owns no pass -- it overrides a uniform inside a pass the
-- ENGINE owns -- so it gets none of that and this is the adapter.
--
-- Two surfaces read and write one stored value, so they cannot disagree:
--   mod.options:define    a home in options.modOptions.DECK_TILT, and a row
--                         on this mod's page in the mod manager
--   ui.options.rows       the same setting on the main OPTIONS menu

local V = ...

local Setting = {}
Setting.__index = Setting

local MOD_ID = "DECK_TILT"

-- `default` is the value used when nothing is stored, and the fallback for an
-- unrecognised one; omit it and values[1] is used.  It exists because two
-- settings can share one ladder of values and still want different defaults --
-- the horizontal and vertical gains are the same six levels, but sideways
-- needs more of it to cover the same screen (see Motion).
function Setting.new(key, label, values, labels, help, default)
  return setmetatable({
    key = key, label = label, values = values, labels = labels, help = help,
    default = default,
    index = nil, -- nil until read back from the persisted options
  }, Setting)
end

function Setting:defaultIndex()
  if self.default ~= nil then
    for i, v in ipairs(self.values) do
      if v == self.default then return i end
    end
  end
  return 1
end

-- Read lazily rather than at load: the loader fills modOptions before a mod
-- runs, but going through the API keeps this honest about where it lives.
function Setting:pos()
  if self.index then return self.index end
  local stored
  local mod = V.mod
  if mod and mod.options then
    local ok, got = pcall(mod.options.get, mod.options, self.key)
    if ok then stored = got end
  end
  self.index = self:defaultIndex()
  for i, v in ipairs(self.values) do
    if v == stored then self.index = i break end
  end
  return self.index
end

function Setting:get()
  return self.values[self:pos()]
end

function Setting:text()
  return self.labels[self:pos()]
end

-- `defer` skips the file write, for callers changing several settings at
-- once: RESET ALL would otherwise rewrite options.lua once per row.
function Setting:setPos(i, game, defer)
  local n = #self.values
  i = ((i - 1) % n + n) % n + 1
  self.index = i
  local value = self.values[i]
  -- mirror what the manager's own page does: the live save's options, the
  -- loader's copy that mod.options:get reads, then the file
  local opts = game and game.save and game.save.options
  if opts then
    opts.modOptions = opts.modOptions or {}
    opts.modOptions[MOD_ID] = opts.modOptions[MOD_ID] or {}
    opts.modOptions[MOD_ID][self.key] = value
  end
  local loader = game and game.mods
  if loader then
    loader.modOptions = loader.modOptions or {}
    loader.modOptions[MOD_ID] = loader.modOptions[MOD_ID] or {}
    loader.modOptions[MOD_ID][self.key] = value
  end
  if not defer and game and game.writeOptions then
    pcall(game.writeOptions, game)
  end
  return value
end

-- Adopt a value set elsewhere (the manager's page persists on its own):
-- nothing to store, just move the cached index.
function Setting:sync(value)
  self.index = self:defaultIndex()
  for i, v in ipairs(self.values) do
    if v == value then self.index = i return end
  end
end

-- The descriptor src/ui/OptionRows.lua renders for the OPTIONS menu.
function Setting:row()
  local this = self
  return {
    id = MOD_ID .. ":" .. self.key,
    label = self.label,
    value = function() return this:text() end,
    step = function(game, dir)
      this:setPos(this:pos() + (dir or 1), game)
      return true
    end,
  }
end

-- The row the mod manager's settings page builds.
function Setting:schema()
  local choices = {}
  for i, v in ipairs(self.values) do choices[i] = { self.labels[i], v } end
  return { key = self.key, type = "choice", label = self.label,
           choices = choices, default = self.values[self:defaultIndex()],
           help = self.help }
end

return Setting
