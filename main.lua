-- Deck Tilt: moves the GBC FX light with the motion sensor of the console.
--
-- The GBC FX effect of the engine (src/render/GBCFX.lua) draws an unlit LCD
-- screen under a light -- a reflective backing, an LCD grid, drop shadows
-- floating over that backing, and at the top rung a specular glare with the
-- rainbow quarter-wave-plate shimmer of the front polarizer.  The last two
-- are lit effects: both read a light position, and the shimmer's whole
-- character is where that light is relative to each pixel.
--
-- That light is a canned Lissajous drift off the clock.  On hardware that
-- knows which way up it is, it does not have to be.  This mod reads the
-- Deck's IMU and puts the light where the room actually is, so tipping the
-- console sweeps the glare and rolls the interference bands across the
-- screen when you tilt the console.
--
--   lib/Imu       the accelerometer, read from /dev/hidraw via the FFI
--   lib/Motion    gravity in, screen-space light position out
--   lib/GbcLight  patches the light into the engine's own shader
--
-- Scope, deliberately narrow:
--   * No engine file is modified.  The shader is rewritten in memory from
--     the source GBCFX already exports, so update.sh can rsync --delete
--     over game/ and this keeps working.
--   * No hotkey is claimed.  The engine owns 2-5 and DRAMATIC_SHAPE owns
--     3 and 5-8; there is nothing left worth fighting over for a setting
--     that is set once.
--   * Every failure -- no LuaJIT, no HID node, an IMU Steam has not woken,
--     a shader that would not patch -- falls through to the engine's own
--     present, unchanged.  This mod can stop working; it cannot break a
--     frame.
--   * Presentational only.  It moves a light. Nothing reads it back.

local mod = ...

-- ------- the mod namespace
--
-- lib/ modules load through V rather than package.path: a mod directory is
-- not on it, and may live inside a mounted .love archive that plain require
-- cannot reach.  Each is loaded once with V as its vararg (`local V = ...`).

local V = { mod = mod, path = mod.path }

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local rel = "lib/" .. name .. ".lua"
  local source = mod:read(rel)
  if not source then
    error(("DECK_TILT: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("DECK_TILT: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  local value = chunk(V)
  modules[name] = value
  return value
end

local Settings = V.require("Settings")
local GbcLight = V.require("GbcLight")

-- The mod's own page.  Registered as a screen so the engine owns its
-- lifetime, and so a fault in it degrades to the builtin rather than
-- stranding the player (src/ui/Screens.lua pcalls mod screens).
local SCREEN = "DeckTiltGyro"
mod.content.screens:register(SCREEN, {
  new = function(game) return V.require("GyroMenu").new(game) end,
})

-- ------- take over the light

GbcLight.install()

-- ------- settings

mod.options:define(Settings.schema())

-- call next() first and append, so every other mod's rows survive this one
-- ONE row on the main OPTIONS menu, not nine.
--
-- The mod had grown to more rows than the engine's entire display section,
-- for something most players set once.  The row carries the sensor state as
-- its value so the page is still worth a glance without opening it -- ASLEEP
-- there tells you the gyro is off in Steam Input, which is the one failure
-- you cannot diagnose from inside the game.
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end
  out[#out + 1] = {
    id = "DECK_TILT:gyro",
    label = "SD-GYRO",
    value = function() return GbcLight.status() end,
    activate = function(g) mod.ui.push(g, SCREEN) end,
  }
  return out
end)

-- The manager's page writes and persists on its own; all that is left is to
-- move our cached index so the next read agrees with it.
mod.events:on("mod.options_changed", function(payload)
  if not (payload and payload.mod == mod.id) then return end
  Settings.sync(payload.key, payload.value)
end)

-- ------- the quick-centre key
--
-- There is no input hook, so this wraps Game.keypressed -- the same route
-- the other mod here takes for its hotkeys, and the only one available.
-- Checked BEFORE delegating, so it works from anywhere including inside a
-- menu; re-centring is a global gesture, not a screen's business.
--
-- Left Control, because Steam Input is the thing that has to send it and
-- LEFT_CONTROL is a key Steam demonstrably emits -- it appears in its own
-- stock templates.  The previous choice, F9, does not: a search of every
-- stock template and saved config on the test system found exactly one
-- function-key binding, and it was the one written here.  Unverified syntax
-- on the far
-- side of a black box is not a binding, it is a guess, and a guess that
-- fails silently looks exactly like a broken feature.
--
-- The engine binds no control key, and unlike a letter it cannot collide
-- with the naming screen.
local RECENTRE_KEY = "lctrl"

do
  local Game = require("src.core.Game")
  local inner = Game.keypressed
  function Game:keypressed(key)
    if key == RECENTRE_KEY and Settings.hotkey:get() == "on" then
      V.require("Motion").recentre()
      return
    end
    -- accept the old key too, so a config that was not migrated still works
    if key == "f9" and Settings.hotkey:get() == "on" then
      V.require("Motion").recentre()
      return
    end
    return inner(self, key)
  end
end

mod.exports.version = "0.1.0"
-- the lib namespace, so tests and probes can read the sensor state without
-- going through the render path
mod.exports.lib = V
