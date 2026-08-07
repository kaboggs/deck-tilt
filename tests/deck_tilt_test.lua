-- Deck Tilt's own SDK suite.
--
-- The mod is mostly untestable headlessly on purpose -- it reads a HID
-- device and drives a GLSL uniform, and neither exists in this harness.
-- What IS testable is the part most likely to break without anyone
-- noticing, and it is the reason this file exists:
--
--   the shader rewrite.  The mod's one assumption about engine internals is
--   that src/render/GBCFX.lua declares its light position as a statement
--   this can find and replace.  Nothing warns you when an engine update
--   rephrases that line -- the effect just silently stops, on a machine
--   you may not be holding.  So the substitution is run here against the
--   engine's ACTUAL current shader source, every test run.
--
-- Everything else asserted here is the graceful-degradation contract: on a
-- host with no LuaJIT, no HID node and no GPU -- which is precisely what
-- this harness is -- the mod must load clean and answer "no" rather than
-- throwing.

package.path = "./?.lua;./?/init.lua;" .. package.path

local T = require("tests.modkit")
local GBCFX = require("src.render.GBCFX")

local MOD_PATH = os.getenv("DECK_TILT_MOD_PATH") or "mods/DECK_TILT"
local run = T.sdk.loadMod(MOD_PATH)

T.eq(#run.errors, 0,
  "DECK_TILT loads clean: " .. table.concat(run.errors, "; "))

local exports = run.loader.exports.DECK_TILT
T.check(type(exports) == "table", "the mod publishes its exports")

-- Read the expected version OUT OF THE MANIFEST rather than writing it here.
-- A literal in this line is the exact trap main.lua describes: it went stale
-- the moment the manifest was bumped, and the only thing that noticed was
-- this assertion failing for a version bump that was entirely correct. What
-- is worth asserting is that exports.version AGREES with the manifest -- that
-- the mod is not carrying a second, hardcoded copy of its own version -- and
-- that survives every bump without an edit.
do
  local manifest = run.mod and run.mod.manifest
  T.check(type(manifest) == "table" and manifest.version ~= nil,
    "the manifest declares a version")
  T.eq(exports.version, manifest.version,
    "and the exported version is that one, not a second copy of it")
end

local V = exports.lib
T.check(type(V) == "table" and type(V.require) == "function",
  "and its lib namespace")

local GbcLight = V.require("GbcLight")
local Motion = V.require("Motion")
local Settings = V.require("Settings")
local Imu = V.require("Imu")

-- ------- the shader rewrite, against the engine's real source

T.check(type(GBCFX.SHADER_SRC) == "string",
  "the engine still exports its GBC FX shader source")

local patched, why = GbcLight.patchSource(GBCFX.SHADER_SRC)
T.check(patched ~= nil,
  "the lightPos statement is still findable in the engine's shader ("
  .. tostring(why) .. ")")

if patched then
  T.check(patched:find("extern vec2 deckLight;", 1, true) ~= nil,
    "the patched source declares the light uniform")
  T.check(patched:find("vec2 lightPos = deckLight;", 1, true) ~= nil,
    "and reads lightPos from it")
  T.check(patched:find("sin(time * 0.13)", 1, true) == nil,
    "the engine's clock-driven light expression is gone")
  -- the tilt uniform must reach BOTH rewritten statements, not just the
  -- light -- the shadow rewrite reads it too
  local _, uses = patched:gsub("deckLight", "")
  T.check(uses >= 2,
    "both the light and the shadow offset read the tilt uniform")
end

-- the shadow rewrite is optional but must land against the current engine
local _, _, hasShadow = GbcLight.patchSource(GBCFX.SHADER_SRC)
T.check(hasShadow == true,
  "the shOff statement is still findable, so the drop shadow can follow the "
  .. "light instead of always falling down-and-right")
T.check(patched and patched:find("extern vec2 deckShadowOff;", 1, true) ~= nil,
  "and the patched source declares the shadow uniform")

-- ------- the shadow throw
--
-- Two earlier versions of this were wrong in ways only visible on hardware,
-- so the contract is pinned here in the terms it actually failed in:
-- the shadow must clear the sprite on the LEFT by the same distance it
-- already does on the right, and must not grow longer than the engine's own.

local function shOff(lx, ly) return GbcLight.shadowOffset(lx, ly, "follow") end
local function len(x, y) return math.sqrt(x * x + y * y) end

local STOCK = 3.0

-- equal throw left and right: the failure that made left-hand shadows
-- invisible was +7.5 px one way against -1.5 px the other
local rx, ry = shOff(1.1, 0.5)
local lx2, ly2 = shOff(-0.1, 0.5)
T.check(math.abs(lx2 + rx) < 1e-6,
  ("left and right throws are mirror images (%.2f vs %.2f)"):format(lx2, rx))
T.check(math.abs(rx) >= STOCK * 0.9,
  ("a light on the right throws the shadow LEFT far enough to clear the "
   .. "sprite (%.2f px, stock is %.1f)"):format(rx, STOCK))

-- constant length in every direction -- a linear swing instead of a rotation
-- peaked at nearly double the engine's offset AND faded to nothing at centre,
-- which is exactly where the light rests during normal play
-- Constant AWAY from the pivot.  Near it the length deliberately eases to
-- nothing so the direction reversal happens with nothing on screen to see;
-- the rest point is placed clear of that region, so it keeps full length.
local dirs = { {1.1,0.5}, {-0.1,0.5}, {0.5,1.1}, {0.5,-0.1}, {0.5,0.5}, {1.1,1.1} }
local first = len(shOff(dirs[1][1], dirs[1][2]))
for _, d in ipairs(dirs) do
  local x, y = shOff(d[1], d[2])
  T.check(math.abs(len(x, y) - first) < 1e-6,
    ("throw length is constant at light (%.1f,%.1f): %.2f"):format(d[1], d[2], len(x, y)))
end
local rx2, ry2 = shOff(0.5, 0.5)
T.check(math.abs(len(rx2, ry2) - first) < 1e-6,
  "and is at FULL length where the light rests, not eaten by the softening")
T.check(first > STOCK and first < STOCK * 1.4,
  ("and stays close to the engine's own %.1f px (got %.2f)"):format(STOCK, first))

-- it must still reach upward, and rest pointing down like the engine does
local _, upY = shOff(0.5, 1.1)
T.check(upY <= -STOCK * 0.9,
  ("a light BELOW throws the shadow properly UP (%.2f px)"):format(upY))
local cx, cy = shOff(0.5, 0.5)
T.check(math.abs(cx) < 1e-6 and cy > 0,
  "with the light centred the shadow falls straight down, as stock does")

-- FIXED restores the engine's own constant exactly
local sx, sy = GbcLight.shadowOffset(0.2, 0.9, "fixed")
T.eq(sx, STOCK, "SHADOW FIXED restores the engine's constant X offset")
T.eq(sy, STOCK, "and its Y offset")

-- and OFF must genuinely remove the shadow, not merely stop it moving.
-- Zeroing the OFFSET cannot do that -- the shader still darkens the backing
-- under the sprite -- so OFF has to scale the strength term instead.
T.check(patched and patched:find("deckShadowAmt", 1, true) ~= nil,
  "the strength term is under our control, so OFF can mean off")

-- ------- the SHADOW AMT row
--
-- The stock throw was tuned to CLEAR THE SPRITE, not to be watched: across
-- the light's whole travel it swings about seven pixels, which is a movement
-- you have to be told about before you see it. This row lengthens it.
--
-- The invariant that matters is that NORMAL is not an approximation of the
-- old behaviour but exactly it -- a default that shifts the picture for
-- everyone who never touches the row is the one outcome that is not allowed.
do
  local STOCK_LEN = GbcLight.SHADOW_STOCK_LEN
  T.check(type(STOCK_LEN) == "number" and STOCK_LEN > 0,
    "the stock throw length is published rather than copied into the row")

  -- NORMAL resolves to the published constant, so the two cannot drift.
  --
  -- The SETTING is forced rather than read: Setting:pos resolves against the
  -- player's options.lua, so an install with SHADOW AMT on any other rung
  -- would fail this for no reason. It did exactly that once.
  T.eq(Settings.shadowamt:schema().default, "stock",
    "SHADOW AMT defaults to NORMAL")
  do
    local was = Settings.shadowamt.index
    Settings.shadowamt.index = nil; Settings.shadowamt:sync("stock")
    T.eq(Settings.shadowLenPx(STOCK_LEN), STOCK_LEN,
      "and NORMAL is the stock throw exactly, not an approximation of it")
    Settings.shadowamt.index = was
  end
  local dx, dy = GbcLight.shadowOffset(1.1, 0.5, "follow", STOCK_LEN)
  local ox, oy = GbcLight.shadowOffset(1.1, 0.5, "follow")
  T.check(math.abs(dx - ox) < 1e-9 and math.abs(dy - oy) < 1e-9,
    "and passing it explicitly is the same as omitting it")

  -- every rung is a real number of pixels, and they only ever go up
  local prev = 0
  for _, v in ipairs(Settings.shadowamt.values) do
    local px = (v == "stock") and STOCK_LEN or tonumber(v)
    T.check(type(px) == "number" and px > 0,
      ("SHADOW AMT rung %s is a length"):format(v))
    T.check(px > prev,
      ("SHADOW AMT rungs increase: %s is longer than the one before"):format(v))
    prev = px
  end

  -- the throw is the length asked for, in every direction
  for _, L in ipairs({ 5, 10, 28 }) do
    for _, d in ipairs({ {1.1,0.5}, {-0.1,0.5}, {0.5,1.1}, {0.5,0.5} }) do
      local x, y = GbcLight.shadowOffset(d[1], d[2], "follow", L)
      T.check(math.abs(len(x, y) - L) < 1e-6,
        ("a %dpx throw is %dpx at light (%.1f,%.1f), got %.2f")
          :format(L, L, d[1], d[2], len(x, y)))
    end
  end

  -- a longer throw must still be a SHADOW: same direction as stock, only
  -- further. A row that also rotated it would be a different effect.
  local sx1, sy1 = GbcLight.shadowOffset(0.9, 0.2, "follow", STOCK_LEN)
  local sx2, sy2 = GbcLight.shadowOffset(0.9, 0.2, "follow", 20)
  local cross = sx1 * sy2 - sy1 * sx2
  T.check(math.abs(cross) < 1e-6,
    "a longer throw points exactly where the stock one did")
  T.check(len(sx2, sy2) > len(sx1, sy1),
    "and is genuinely longer")

  -- FIXED does not move, but the row still lengthens it
  local fx, fy = GbcLight.shadowOffset(0.2, 0.9, "fixed", STOCK_LEN)
  T.eq(fx, STOCK, "at NORMAL, FIXED is still the engine's constant X")
  T.eq(fy, STOCK, "and its Y")
  local gx, gy = GbcLight.shadowOffset(0.2, 0.9, "fixed", 20)
  T.check(gx > fx and gy > fy,
    "and a longer rung throws the FIXED shadow further, without moving it")
  local hx, hy = GbcLight.shadowOffset(0.7, 0.1, "fixed", 20)
  T.check(math.abs(hx - gx) < 1e-9 and math.abs(hy - gy) < 1e-9,
    "FIXED stays put wherever the light is, at any length")

  -- the reversal near the pivot must stay sub-pixel at the LONGEST rung,
  -- which is the whole reason the softening is a fraction of the throw
  -- rather than a fixed number of pixels
  local worst = 0
  local px, py = GbcLight.shadowOffset(0.5, 0.5, "follow", 28)
  for i = 1, 400 do
    local ly = 0.5 + i * 0.002
    local qx, qy = GbcLight.shadowOffset(0.5, ly, "follow", 28)
    worst = math.max(worst, len(qx - px, qy - py))
    px, py = qx, qy
  end
  T.check(worst < 1.0,
    ("the worst frame-to-frame jump at the longest throw is %.3f px, "
     .. "under one pixel"):format(worst))
end

-- ------- the glare tint
--
-- The glare is a front-surface reflection, so its colour is the colour of the
-- room. The one thing this row must NOT do is double as a brightness control:
-- GLARE above it owns that, and if a hue arrived dimmer than white the two
-- rows would quietly fight. Hence unit-luma normalisation, asserted here
-- rather than eyeballed, because "BLUE looks a bit weak" is exactly the kind
-- of thing nobody files.
do
  local Overlay = V.require("Overlay")
  T.check(Overlay.SHADER_SRC:find("deckGlareTint", 1, true) ~= nil,
    "the overlay shader takes a glare tint")
  T.check(Overlay.SHADER_SRC:find("col %+= deckGlareTint") ~= nil,
    "and the glare is multiplied by it rather than added as plain white")

  -- every rung resolves to a colour; a missing entry would silently be white
  for _, v in ipairs(Settings.glaretint.values) do
    T.check(GbcLight.GLARETINT[v] ~= nil,
      ("GLARE TINT rung %s has a colour"):format(v))
  end
  T.eq(#Settings.glaretint.values, #Settings.glaretint.labels,
    "every glare tint value has a label")

  local function luma(r, g, b) return 0.299 * r + 0.587 * g + 0.114 * b end

  -- WHITE must be exactly neutral: it is the value everyone already has, and
  -- the default must not shift a single pixel of anyone's picture
  T.eq(Settings.glaretint:schema().default, "white",
    "GLARE TINT defaults to WHITE, which is what the glare always was")
  local was = Settings.glaretint.index
  Settings.glaretint:sync("white")
  local wr, wg, wb = GbcLight.glareTint()
  T.check(math.abs(wr - 1) < 1e-6 and math.abs(wg - 1) < 1e-6
          and math.abs(wb - 1) < 1e-6,
    "WHITE is exactly (1,1,1), so the default adds no colour at all")

  -- and every other rung carries the SAME light, only a different colour
  for _, v in ipairs(Settings.glaretint.values) do
    Settings.glaretint:sync(v)
    local r, g, b = GbcLight.glareTint()
    T.check(math.abs(luma(r, g, b) - 1) < 1e-6,
      ("%s is unit luma (%.4f), so the tint changes hue and not strength")
        :format(v, luma(r, g, b)))
    T.check(r >= 0 and g >= 0 and b >= 0,
      v .. " has no negative channel")
    -- a tint that came out identical to white would be a dead rung
    if v ~= "white" then
      local diff = math.abs(r - g) + math.abs(g - b) + math.abs(r - b)
      T.check(diff > 0.05,
        ("%s is visibly a colour rather than another white"):format(v))
    end
  end
  Settings.glaretint.index = was

  -- the swatch strip must follow the row onto the LIGHT FX page, with the
  -- glare palette rather than the tube's
  local Menu = V.require("GyroMenu")
  local light
  for _, g in ipairs(Settings.groups) do if g.id == "light" then light = g end end
  T.check(light ~= nil, "there is a LIGHT FX group")
  local page = Menu.group(nil, light)
  T.eq(page.swatchRowId, "DECK_TILT:glaretint",
    "the LIGHT FX page publishes swatches for GLARE TINT")
  T.eq(page.swatchPalette, GbcLight.GLARETINT,
    "and does it with the glare palette, not the tube's glow palette")
  T.eq(page.swatchSetting, Settings.glaretint,
    "and reads its values from that setting rather than a hardcoded one")
end

-- ------- ROOM LIGHT, and the two reference variants
--
-- A GBC has no backlight, so PT_BACKING_BRIGHTNESS is not a brightness
-- slider -- it is how much light is in the room, and it is the only reason
-- the same screen is readable outdoors and murky indoors. The reference
-- exposes it across 0.20..0.65; this port had it welded to the shipped 0.48,
-- which meant the dark half of the effect did not exist.
do
  local PixelTrans = V.require("PixelTrans")

  T.eq(Settings.ptlight:schema().default, "normal",
    "ROOM LIGHT defaults to the reference's own value")
  T.check(math.abs(PixelTrans.ROOMLIGHT.normal - PixelTrans.ROOMLIGHT_REF) < 1e-9,
    "and NORMAL is exactly that value, so the default changes nothing")

  -- every rung resolves, and they only go up
  local prev = -1
  for _, v in ipairs(Settings.ptlight.values) do
    local lv = PixelTrans.ROOMLIGHT[v]
    T.check(lv ~= nil, ("ROOM LIGHT rung %s has a level"):format(v))
    T.check(lv > prev, ("ROOM LIGHT rises at %s"):format(v))
    prev = lv
  end
  T.check(PixelTrans.ROOMLIGHT.dim < PixelTrans.ROOMLIGHT_REF,
    "DIM is genuinely darker than the shipped default")
  T.check(PixelTrans.ROOMLIGHT.sunlit > PixelTrans.ROOMLIGHT_REF,
    "and SUNLIT genuinely brighter")

  -- the row changes LEVEL only; BACKING still owns hue. Ratios between the
  -- channels must survive, or the two rows would be fighting.
  local was = Settings.ptlight.index
  local function setLight(v) Settings.ptlight.index = nil; Settings.ptlight:sync(v) end
  setLight("normal")
  local nr, ng, nb = PixelTrans.backingColour("olive")
  setLight("dim")
  local dr, dg, db = PixelTrans.backingColour("olive")
  T.check(dr < nr and dg < ng and db < nb, "DIM darkens every channel")
  T.check(math.abs((dr / dg) - (nr / ng)) < 1e-6
          and math.abs((dg / db) - (ng / nb)) < 1e-6,
    "and keeps the plate's colour, because hue is the BACKING row's question")
  setLight("sunlit")
  local sr = PixelTrans.backingColour("olive")
  T.check(sr > nr, "SUNLIT brightens it")

  -- and it scales every plate, not just the default one
  for _, plate in ipairs(Settings.ptback.values) do
    setLight("dim");    local a = PixelTrans.backingColour(plate)
    setLight("sunlit"); local b = PixelTrans.backingColour(plate)
    T.check(b > a, ("ROOM LIGHT reaches the %s plate too"):format(plate))
  end
  Settings.ptlight.index = was

  -- The reference behaviour comes in two forms: the plain plate (plate,
  -- shadows, no glare or rainbow) and the sunlit one (the same plus the
  -- rainbow). Both must be reachable here, or only one of them exists -- so
  -- RAINBOW must have a genuine OFF rather than merely a low setting.
  T.check(PixelTrans.RAINBOW[Settings.ptrainbow.values[1]] == 0,
    "RAINBOW OFF is exactly zero, which is the plain unlit plate; any rung "
    .. "above it is the sunlit form")
end

-- ------- RESET FX must not touch the tilt setup
--
-- RESET ALL takes the gyro with it -- source axes, gains, signs, centring --
-- and those are what somebody spent real time tuning with the console in
-- their hands. Wanting the effects back to stock is not the same as wanting
-- to do that again.
--
-- The split is asserted from BOTH sides, because a scoped reset is only
-- trustworthy if what it leaves alone is as pinned as what it clears.
do
  local fx = Settings.fxKeys()

  -- the picture passes are in scope
  for _, key in ipairs({ "pt", "ptalpha", "ptback", "ptlight", "screenfx",
                         "dmgxtalk", "dmgshadow", "dmgtrim", "dmgdead",
                         "ghost", "ghostgate", "rf", "rfdots", "beammask",
                         "beamglowcol", "dmgpal" }) do
    T.check(fx[key], key .. " is a picture setting, so RESET FX clears it")
  end

  -- and the gyro is NOT, which is the whole point of the row
  for _, key in ipairs({ "motion", "srcx", "srcy", "signx", "signy",
                         "xrange", "yrange", "smooth", "level", "hotkey" }) do
    T.check(not fx[key],
      key .. " is tilt setup and RESET FX must leave it completely alone")
  end
  -- nor the tilt light, nor the haptics
  for _, key in ipairs({ "overlay", "glare", "glaretint", "shimmer",
                         "shadow", "shadowamt", "rumblepower", "rumbletune" }) do
    T.check(not fx[key], key .. " is not a picture effect")
  end

  -- and it actually resets: drive some rows off their defaults, reset, and
  -- check exactly the right ones moved
  local watch = { "dmgxtalk", "ghost", "rf", "xrange", "srcx", "glare" }
  local saved = {}
  for _, k in ipairs(watch) do saved[k] = Settings[k].index end
  local function force(k, v) Settings[k].index = nil; Settings[k]:sync(v) end
  force("dmgxtalk", "high"); force("ghost", "max"); force("rf", "harsh")
  force("xrange", "subtle"); force("srcx", "twist"); force("glare", "off")

  Settings.resetFx(nil)

  T.eq(Settings.dmgxtalk:get(), Settings.dmgxtalk.default or "off",
    "RESET FX put CROSSTALK back")
  T.eq(Settings.ghost:get(), "off", "and the trail")
  T.eq(Settings.rf:get(), "off", "and TV/RF")
  T.eq(Settings.xrange:get(), "subtle",
    "and left the tilt gain exactly where it was -- this is the assertion the "
    .. "row exists for")
  T.eq(Settings.srcx:get(), "twist", "and the tilt source")
  T.eq(Settings.glare:get(), "off", "and the tilt light's own rows")

  for _, k in ipairs(watch) do Settings[k].index = saved[k] end
end

-- ------- the SCREEN FX master
--
-- One row gates every pass that changes the picture. Two things must hold and
-- the second is the one that nearly shipped wrong: the gate has to live in
-- wanted(), not only in the chain that calls apply(). Gated only in the
-- chain, a pass invoked directly still ran -- which a driver caught here, and
-- which would have become a real fault the first time anything else reached
-- for a pass.
do
  local PASSES = { "PixelTrans", "DmgPanel", "Ghost", "RfTv", "CrtBeam" }

  T.eq(Settings.screenfx:schema().default, "on",
    "SCREEN FX ships ON, so adding the switch changes nothing by itself")

  -- force every pass ON, then prove the master silences all of them
  local saved = {}
  local rows = { "dmgxtalk", "dmgshadow", "dmgtrim", "dmgdead", "ghost",
                 "pt", "rf", "beammask", "screenfx" }
  for _, k in ipairs(rows) do saved[k] = Settings[k].index end
  local function force(k, v) Settings[k].index = nil; Settings[k]:sync(v) end

  force("screenfx", "on")
  force("dmgxtalk", "high"); force("ghost", "strong")
  force("pt", Settings.pt.values[#Settings.pt.values])
  force("rf", Settings.rf.values[#Settings.rf.values])
  force("beammask", Settings.beammask.values[#Settings.beammask.values])

  local anyOn = false
  for _, name in ipairs(PASSES) do
    local ok, M = pcall(V.require, name)
    if ok and M and M.wanted and M.wanted() then anyOn = true end
  end
  T.check(anyOn, "with SCREEN FX on, the passes that were switched on want to run")

  force("screenfx", "off")
  for _, name in ipairs(PASSES) do
    local ok, M = pcall(V.require, name)
    T.check(ok and M and M.wanted, name .. " answers wanted()")
    if ok and M and M.wanted then
      T.check(not M.wanted(),
        name .. " is silenced by the SCREEN FX master, whatever its own rows say")
    end
  end

  -- and it must FORGET NOTHING: the rows are untouched, so switching back on
  -- restores exactly what was configured
  T.eq(Settings.dmgxtalk:get(), "high",
    "the master does not change any pass's own setting")
  T.eq(Settings.ghost:get(), "strong", "nor any other's")
  force("screenfx", "on")
  local backOn = false
  for _, name in ipairs(PASSES) do
    local ok, M = pcall(V.require, name)
    if ok and M and M.wanted and M.wanted() then backOn = true end
  end
  T.check(backOn, "and switching it back on brings them all back")

  for _, k in ipairs(rows) do Settings[k].index = saved[k] end
end

-- ------- the reflector grain, in the bands that read
--
-- The reference measured three bands in the sheet -- about half a dot, one to
-- three dots, and eighteen to thirty-six -- and concluded only the middle one
-- reads as grain at this pixel pitch: the finest is below what the panel
-- resolves and the coarsest is mottling.
--
-- The fbm this replaced ignored that. Its three octaves landed at 128, 256
-- and 512 cycles across 160 dots -- periods of 1.25, 0.63 and 0.31 dots -- so
-- two thirds of its samples were spent below one dot producing aliasing, and
-- the visible coarse band was missing entirely.
do
  local PT = V.require("PixelTrans")
  local DOTS = 160

  local midPeriod    = DOTS / PT.GRAIN_MID_CYCLES
  local coarsePeriod = DOTS / PT.GRAIN_COARSE_CYCLES

  T.check(midPeriod >= 1.0 and midPeriod <= 3.0,
    ("the grain band is %.2f dots per cycle, inside the 1-3 dots the panel "
     .. "can actually resolve"):format(midPeriod))
  T.check(coarsePeriod >= 18.0 and coarsePeriod <= 36.0,
    ("the mottling band is %.1f dots per cycle, inside the reference's "
     .. "18-36"):format(coarsePeriod))
  T.check(midPeriod > 1.0,
    "and nothing is drawn below one dot, where it would alias rather than "
    .. "read as grain")

  -- mean 0.5 by construction, so the grain is CENTRED: it must texture the
  -- plate without making it brighter, which a wrong mean would do silently
  T.eq(PT.GRAIN_MEAN, 0.5, "the grain is mean-centred")
  T.check(PT.GRAIN_COARSE_MIX > 0 and PT.GRAIN_COARSE_MIX < 0.5,
    "the mottling is present but subordinate to the grain")
  T.check(PT.SHADER_SRC:find("reflectorGrain", 1, true) ~= nil,
    "the plate uses the banded grain")
  T.check(PT.SHADER_SRC:find("paperNoise", 1, true) == nil,
    "and the old three-octave fbm is gone from the shader entirely")

  -- the row exists and NORMAL is the reference value untouched
  T.eq(Settings.ptgrain:schema().default, "normal", "SHEET GRAIN defaults to NORMAL")
  T.eq(PT.GRAIN.normal, 1.0, "and NORMAL is exactly the reference's own 0.065")
  T.eq(PT.GRAIN.off, 0, "OFF is a perfectly smooth sheet")
  local prev = -1
  for _, v in ipairs(Settings.ptgrain.values) do
    T.check(PT.GRAIN[v] ~= nil, "SHEET GRAIN rung " .. v .. " has a value")
    T.check(PT.GRAIN[v] > prev, "and the ladder only goes up at " .. v)
    prev = PT.GRAIN[v]
  end
end

-- ------- anything indexed by COLUMN must use PICTURE space
--
-- The canvas is the window; the game picture is letterboxed inside it.
-- Measured on hardware: 800x720 of picture inside a 1024x722 canvas, so 112
-- pixels of dead space each side.
--
-- The dead lines indexed columns across the whole CANVAS, which put them at
-- 0..204 instead of 0..159 -- off the GB dot grid -- and, far worse, the edge
-- bias that concentrates failures at the two ends of the bonded ribbon was
-- concentrating them in the LETTERBOX. Most of every seed's lines were drawn
-- where nothing is visible, leaving a sparse middle few that hardly changed
-- between seeds. Reported as "I'm not sure dead lines are being randomized",
-- which was exactly right: the placement barely moved.
do
  local DmgPanel = V.require("DmgPanel")
  local src = DmgPanel.SHADER_SRC
  T.check(src:find("dmgOrigin", 1, true) ~= nil,
    "the pass is told where the picture sits inside the canvas")
  T.check(src:find("dmgSpan", 1, true) ~= nil, "and how big it is")
  T.check(src:find("vec2 pic = %(uv %- dmgOrigin%)") ~= nil,
    "and converts to picture space before indexing a column")
  T.check(src:find("pic%.x %* 160%.0") ~= nil,
    "the column index is over the 160 GB dots, not over canvas pixels")
  T.check(src:find("abs%(pic%.x %- 0%.5%)") ~= nil,
    "and the edge bias is measured across the PICTURE, so the ribbon's ends "
    .. "are the screen's ends and not the letterbox")
  -- the letterbox must be left alone entirely
  T.check(src:find("pic%.x >= 0%.0 && pic%.x <= 1%.0") ~= nil,
    "nothing is drawn outside the picture")

  -- and the geometry is DERIVED from the canvas, never assumed
  local mod = io.open(MOD_PATH .. "/lib/DmgPanel.lua"):read("*a")
  T.check(mod:find("local offX = %(w %- GB_W %* ps%) %* 0%.5") ~= nil,
    "the origin is derived the same way GbcLight.drawSwatches derives it, "
    .. "rather than assuming the canvas is the picture")
end

-- ------- the dead-line seed
--
-- The pattern must be STABLE for a given seed -- a console has one set of
-- dead lines and they do not wander while you play -- and genuinely
-- DIFFERENT between seeds, or the row is decoration.
do
  local function hash11(p)
    p = (p * 0.1031) % 1
    p = p * (p + 33.33)
    return (p * (p + p)) % 1
  end
  local function pattern(seed)
    local out = {}
    for c = 0, 159 do
      local uvx = c / 160
      local h     = hash11(c * 1.7 + seed)
      local clump = hash11(math.floor(c / 6.0) * 3.3 + seed * 2.0)
      local ends  = math.min(1, math.abs(uvx - 0.5) * 2) ^ 1.5
      local bias  = (0.45 + 1.45 * ends) * (0.35 + 1.65 * clump)
      if h < 0.055 * bias then out[#out + 1] = c end
    end
    return table.concat(out, ",")
  end
  local was = Settings.dmgdeadseed.index
  local seen = {}
  for _, v in ipairs(Settings.dmgdeadseed.values) do
    Settings.dmgdeadseed.index = nil; Settings.dmgdeadseed:sync(v)
    local seed = Settings.deadSeed()
    local a, b = pattern(seed), pattern(seed)
    T.eq(a, b, "seed " .. v .. " always gives the same panel")
    T.check(not seen[a], "seed " .. v .. " gives a DIFFERENT panel from the others")
    seen[a] = true
  end
  Settings.dmgdeadseed.index = was
  T.eq(Settings.dmgdeadseed:schema().default, "1", "LINE SEED defaults to 1")
end

-- ------- the DMG panel pass
--
-- Four properties of a passive-matrix reflective LCD. What matters most here
-- is that it is genuinely INERT by default: it is the most expensive pass in
-- the chain (24 texture reads per pixel for the crosstalk field), so it must
-- cost nothing at all until asked for.
do
  local DmgPanel = V.require("DmgPanel")

  local ROWS = { "dmgxtalk", "dmgshadow", "dmgtrim", "dmgdead" }

  -- SCHEMA defaults, not live values.
  --
  -- Setting:pos resolves through mod.options against whatever is in the
  -- player's options.lua, so asserting the live state makes the suite pass or
  -- fail on how the console was last configured. This file warns about that
  -- at the schema assertions and it has now caught three separate tests out,
  -- this one included: it failed on an install where the rows were switched
  -- ON, which is not a defect, it is somebody using the feature.
  for _, key in ipairs(ROWS) do
    T.eq(Settings[key]:schema().default, Settings[key].values[1],
      key .. " defaults to its first rung, which is OFF")
  end
  T.eq(Settings.dmgtrim:schema().default, "off", "PANEL TRIM defaults to off")

  -- For the behaviour, drive the settings explicitly rather than hoping they
  -- are at their defaults, and put them back afterwards.
  local saved = {}
  for _, key in ipairs(ROWS) do saved[key] = Settings[key].index end
  local function force(key, value)
    Settings[key].index = nil
    Settings[key]:sync(value)
  end
  local function allOff()
    for _, key in ipairs(ROWS) do force(key, Settings[key].values[1]) end
  end

  allOff()
  T.check(not DmgPanel.wanted(),
    "with every row off the pass is skipped entirely -- it is the most "
    .. "expensive one in the chain and must cost nothing until asked for")
  T.eq(DmgPanel.apply(nil, 1), nil, "and applying it is a no-op")
  T.eq(DmgPanel.status(), "OFF", "and it says so")

  -- turning any single row on must arm the pass, or that row would set a
  -- value that never reaches a frame
  for _, key in ipairs(ROWS) do
    allOff()
    force(key, Settings[key].values[#Settings[key].values])
    T.check(DmgPanel.wanted(), key .. " on its own arms the pass")
  end
  allOff()
  T.check(not DmgPanel.wanted(), "and everything is off again afterwards")

  for _, key in ipairs(ROWS) do Settings[key].index = saved[key] end

  -- the measured constants, pinned against the reference
  T.check(math.abs(DmgPanel.XTALK_UP - 0.4) < 1e-9,
    "the upward bleed is 0.4x of the downward one -- the asymmetry IS the "
    .. "effect; symmetric it reads as a second drop shadow")
  T.check(DmgPanel.PENUMBRA_DOTS > DmgPanel.UMBRA_DOTS * 2,
    ("the penumbra (%.2f dots) is far broader than the umbra (%.2f) -- the "
     .. "reference records putting both at one dot and having the shadow "
     .. "fade three times too fast"):format(
       DmgPanel.PENUMBRA_DOTS, DmgPanel.UMBRA_DOTS))
  T.check(math.abs(DmgPanel.UMBRA_DOTS - 1.35) < 1e-9, "umbra is 1.35 dots")
  T.check(math.abs(DmgPanel.PENUMBRA_DOTS - 3.24) < 1e-9, "penumbra is 3.24")
  T.check(DmgPanel.BLACKLIFT > 0,
    "black is lifted: a reflective panel has no black to reach")
  T.check(DmgPanel.SATURATION < 1, "and the panel desaturates")
  T.check(DmgPanel.DEADLINE_LIT < 0.1,
    "dead lines are overwhelmingly LIGHT -- a floating electrode relaxes to "
    .. "the reflector, and only a few settle dark from leakage bias")

  -- ------- dead lines must actually appear
  --
  -- The first version of this produced ZERO lines at every severity: the
  -- threshold needed a risk above 0.94 from a distribution that essentially
  -- never reaches it, and the edge term collapsed to nothing away from one
  -- sliver of screen. It compiled, it ran, and it did nothing -- reported
  -- from hardware as "I do not really see the dead lines".
  --
  -- So the maths is MODELLED here rather than trusted. This mirrors the
  -- shader's arithmetic over all 160 columns and asserts the counts.
  do
    local function hash11(p)
      p = (p * 0.1031) % 1
      p = p * (p + 33.33)
      return (p * (p + p)) % 1
    end
    local function count(sev)
      local hits = {}
      for c = 0, 159 do
        local uvx = c / 160
        local h     = hash11(c * 1.7 + 3.0)
        local clump = hash11(math.floor(c / 6.0) * 3.3 + 6.0)
        local ends  = math.min(1, math.abs(uvx - 0.5) * 2) ^ 1.5
        local bias  = (0.45 + (1.9 - 0.45) * ends) * (0.35 + 1.65 * clump)
        if h < 0.055 * sev * bias then hits[#hits + 1] = c end
      end
      return hits
    end
    local prev = -1
    for _, rung in ipairs({ "few", "some", "many" }) do
      local hits = count(DmgPanel.DEAD[rung])
      T.check(#hits > 0,
        ("%s produces at least one dead line (got %d) -- zero is the bug this "
         .. "test exists for"):format(rung, #hits))
      T.check(#hits > prev,
        ("%s produces more lines than the rung below it (%d)"):format(rung, #hits))
      T.check(#hits < 40,
        ("%s does not eat the screen (%d of 160)"):format(rung, #hits))
      prev = #hits
    end
    -- and they clump rather than scattering evenly: a lap joint peels from
    -- the ends of its overlap, so some must be adjacent or near-adjacent
    local hits = count(DmgPanel.DEAD.many)
    local near = 0
    for i = 2, #hits do
      if hits[i] - hits[i - 1] <= 2 then near = near + 1 end
    end
    T.check(near > 0,
      "dead lines arrive in groups rather than evenly scattered")
  end

  -- the strength row makes a partial failure reachable
  T.eq(Settings.dmgdeadamt:schema().default, "full",
    "LINE STRENGTH defaults to a fully failed line")
  T.check(DmgPanel.DEADAMT.faint < DmgPanel.DEADAMT.full,
    "and FAINT is a line that still passes some drive")
  T.check(DmgPanel.DEADAMT.faint > 0, "but is still visible")
  T.check(DmgPanel.SHADER_SRC:find("dmgDeadAmt", 1, true) ~= nil,
    "and the shader blends by it rather than always replacing the pixel")

  -- the shader must actually use both directions, since the reference's own
  -- hardware port could not and this is the reason a shader can
  T.check(DmgPanel.SHADER_SRC:find("uv %- vec2%(0%.0, dmgTexel%.y") ~= nil,
    "the crosstalk field samples ABOVE")
  T.check(DmgPanel.SHADER_SRC:find("uv %+ vec2%(0%.0, dmgTexel%.y") ~= nil,
    "and BELOW, which the FPGA port could not do")
end

-- ------- the swatch strip must fit on the screen
--
-- The strip is drawn at SWATCH_X and steps by SWATCH_PITCH, and the screen is
-- 160px. GLOW COLOUR grew from seven colours to fifteen and the strip ran 48
-- pixels off the right-hand edge -- invisible in the source, obvious on
-- hardware, and the same class of fault as the SELECT hint that overran once
-- before. Asserted against the LONGEST palette any row carries, so adding
-- colours to any of them fails here rather than on a console.
do
  local GbcLight = V.require("GbcLight")
  local longest, which = 0, "?"
  for _, s in ipairs(Settings.order) do
    if s.key == "beamglowcol" or s.key == "glaretint" then
      if #s.values > longest then longest, which = #s.values, s.key end
    end
  end
  T.check(longest > 0, "at least one row carries a colour strip")
  local X, W, P = GbcLight.SWATCH_X, GbcLight.SWATCH_W, GbcLight.SWATCH_PITCH
  T.check(X and W and P, "the strip publishes its geometry so it can be asserted")
  local right = X + (longest - 1) * P + W + 1
  T.check(right <= 160,
    ("the %d-colour strip on %s ends at x=%d, inside the 160px screen")
      :format(longest, which, right))
  -- and it must start clear of the value text it sits beside
  T.check(X >= 24 + 6 * 8,
    ("the strip starts at x=%d, clear of a six-glyph value at x=24"):format(X))
end

-- ------- the DMG shade override
--
-- This reaches into another module's data, so what is asserted is that it
-- cannot damage anything: the engine's own numbers survive, OFF restores them
-- exactly, and a reshaped engine palette makes it refuse rather than write
-- nonsense.
do
  local DmgPalette = V.require("DmgPalette")
  local PaletteFX = require("src.render.PaletteFX")

  T.check(DmgPalette.install(), "the override finds the engine's palette")
  local orig = DmgPalette.originalColours()
  T.check(orig and #orig == 4, "and copies the engine's own four shades out")

  -- the replacement must be a genuine improvement on the specific fault:
  -- CLASSIC's two lightest shades are nearly identical
  local function spread(t, i, j)
    local d = 0
    for k = 1, 3 do d = d + math.abs(t[i][k] - t[j][k]) end
    return d
  end
  local dmg = DmgPalette.PALETTES.realdmg
  T.check(spread(dmg, 1, 2) > spread(orig, 1, 2),
    ("REAL DMG separates the two lightest shades better than the built-in "
     .. "one (%d vs %d)"):format(spread(dmg, 1, 2), spread(orig, 1, 2)))
  for i = 1, 4 do
    for k = 1, 3 do
      T.check(dmg[i][k] >= 0 and dmg[i][k] <= 255,
        "every channel is a byte")
    end
  end
  -- lightest first, and monotonically darkening, like PaletteFX's own tables
  local prev = 1e9
  for i = 1, 4 do
    local lum = 0.299*dmg[i][1] + 0.587*dmg[i][2] + 0.114*dmg[i][3]
    T.check(lum < prev, ("shade %d is darker than the one before it"):format(i))
    prev = lum
  end

  -- the alias table exists so a renamed id can still resolve; an
  -- unrecognised value falls back to the default and would silently switch
  -- somebody's palette off
  T.check(type(DmgPalette.ALIASES) == "table",
    "there is somewhere to map a renamed id, if one is ever renamed")

  local was = Settings.dmgpal.index
  local function set(v) Settings.dmgpal.index = nil; Settings.dmgpal:sync(v) end

  set("realdmg"); DmgPalette.apply()
  for i = 1, 4 do
    for k = 1, 3 do
      T.eq(PaletteFX.CLASSIC[i][k], dmg[i][k],
        "REAL DMG reaches the engine's live palette")
    end
  end

  -- OFF must restore the engine's own numbers EXACTLY. This is the one that
  -- matters: the built-in setting has to survive being overridden.
  set("off"); DmgPalette.apply()
  for i = 1, 4 do
    for k = 1, 3 do
      T.eq(PaletteFX.CLASSIC[i][k], orig[i][k],
        "OFF hands the engine's own shades straight back, unchanged")
    end
  end

  -- and the table itself is never replaced, only rewritten, so anything
  -- holding a reference to it keeps working
  T.eq(DmgPalette.liveColours(), PaletteFX.CLASSIC,
    "the engine's table is mutated in place, never swapped out")

  Settings.dmgpal.index = was
  DmgPalette.apply()
end

-- ------- rumble: one ladder, one multiplier
--
-- Three strength controls used to live here -- RUMBLE, BOOST, and a RUMBLE
-- AMP row that scaled love.joystick.setVibration. The last one was removed
-- rather than fixed: measured on a Deck, setVibration returns TRUE and reads
-- back 0/0, because the console has no rumble motors and LOVE is talking to
-- Steam Input's emulated pad. A row that scales a path carrying nothing is
-- not a weak control, it is a lie, and two rows that both raised loudness by
-- different mechanisms is what made the page impossible to reason about.
--
-- What is left is a ladder that sets strength and a multiplier that scales
-- it in both directions. These pin that.
do
  local DeckRumble = V.require("DeckRumble")
  local DeckHaptics = V.require("DeckHaptics")

  T.eq(Settings.rumblepower:schema().default, "stock",
    "RUMBLE defaults to STOCK, so installing this changes nothing")
  T.eq(Settings.rumbletune:schema().default, "100",
    "and FINE TUNE defaults to 1X")

  -- the multiplier must go DOWN as well as up: not being able to quieten the
  -- direct route was the specific complaint that produced this rewrite
  local first = tonumber(Settings.rumbletune.values[1])
  local last  = tonumber(Settings.rumbletune.values[#Settings.rumbletune.values])
  T.check(first < 100, "FINE TUNE reaches BELOW 1X, so it can quieten")
  T.check(last > 100, "and above it, so it can strengthen")

  local was, wasT = Settings.rumblepower.index, Settings.rumbletune.index
  local function setPower(v) Settings.rumblepower.index = nil; Settings.rumblepower:sync(v) end
  local function setTune(v)  Settings.rumbletune.index  = nil; Settings.rumbletune:sync(v) end

  -- OFF is silent for every input
  setPower("off"); setTune("400")
  for _, v in ipairs({0.1, 0.5, 1.0}) do
    T.eq(Settings.rumbleShapeValue(v), 0,
      "OFF is silent whatever the multiplier says")
  end

  -- STOCK passes the authored strength through untouched at 1X, so the
  -- bottom rung really is the old behaviour and not an approximation
  setPower("stock"); setTune("100")
  for _, v in ipairs({0.1, 0.35, 0.85, 1.0}) do
    T.check(math.abs(Settings.rumbleShapeValue(v) - v) < 1e-9,
      ("STOCK at 1X drives %.2f unchanged"):format(v))
  end

  -- silence is silent at every combination -- amplifying nothing into
  -- something would make a still screen buzz
  for _, p in ipairs(Settings.rumblepower.values) do
    setPower(p)
    for _, t in ipairs(Settings.rumbletune.values) do
      setTune(t)
      T.eq(Settings.rumbleShapeValue(0), 0,
        ("silence stays silent at %s / %s"):format(p, t))
    end
  end

  -- ONE row, and going up it makes everything stronger -- including the
  -- quiet end, which is what removed the need for a second row
  setTune("100")
  local rungs = { "faint", "light", "soft", "normal", "firm", "strong",
                  "hard", "max" }
  for _, probe in ipairs({0.10, 0.35, 0.85}) do
    local prev = -1
    for _, rung in ipairs(rungs) do
      setPower(rung)
      local got = Settings.rumbleShapeValue(probe)
      T.check(got > prev,
        ("%s is louder than the rung below it at authored %.2f (%.3f)")
          :format(rung, probe, got))
      prev = got
    end
  end

  -- and the quiet end gains MORE than the loud end, which is the whole
  -- reason the curve is folded into the rung
  setPower("faint"); local qLo, lLo = Settings.rumbleShapeValue(0.10), Settings.rumbleShapeValue(0.85)
  setPower("max");   local qHi, lHi = Settings.rumbleShapeValue(0.10), Settings.rumbleShapeValue(0.85)
  T.check((qHi / qLo) > (lHi / lLo),
    ("climbing the ladder lifts a quiet effect more than a loud one "
     .. "(%.1fx vs %.1fx)"):format(qHi/qLo, lHi/lLo))

  -- ordering survives at every rung: a tick must never out-rumble a faint
  for _, rung in ipairs(rungs) do
    setPower(rung)
    T.check(Settings.rumbleShapeValue(0.10) < Settings.rumbleShapeValue(0.85),
      "a quiet effect stays quieter than a loud one at " .. rung)
  end

  -- the multiplier scales in both directions and cannot overflow
  setPower("normal")
  setTune("100"); local mid = Settings.rumbleShapeValue(0.5)
  setTune("50");  local down = Settings.rumbleShapeValue(0.5)
  setTune("200"); local up = Settings.rumbleShapeValue(0.5)
  T.check(math.abs(down - mid * 0.5) < 1e-9, "0.5X halves the output")
  T.check(math.abs(up - mid * 2.0) < 1e-9, "2X doubles it")
  setPower("max"); setTune("400")
  T.check(Settings.rumbleShapeValue(1.0) <= 1.0,
    "and nothing can drive past the motor's limit")

  -- the direct route is only used above STOCK, so STOCK genuinely restores
  -- the old path rather than a quiet version of the new one
  setPower("stock"); T.check(not Settings.rumbleDirect(), "STOCK stays on the old route")
  setPower("off");   T.check(not Settings.ownRumbleOn(), "OFF is off")
  setPower("faint"); T.check(Settings.rumbleDirect(), "FAINT already uses the strong route")

  Settings.rumblepower.index, Settings.rumbletune.index = was, wasT

  -- ------- the haptic drive
  --
  -- There is no amplitude field in Valve's protocol; strength is duty cycle
  -- at the actuator's resonance. These pin the mapping, which is the part
  -- that can be tested without a controller.
  T.check(DeckHaptics.FREQ_HZ > 100 and DeckHaptics.FREQ_HZ < 300,
    "the drive sits in the band an LRA actually responds to")
  T.check(DeckHaptics.DUTY_MAX < 1.0,
    "duty never reaches 100%, which would be DC and silent")
  T.check(DeckHaptics.DUTY_MIN > 0,
    "and never 0, which would also be silent")
  local prevDuty = -1
  for _, s01 in ipairs({0, 0.25, 0.5, 0.75, 1.0}) do
    local hi, lo, count = DeckHaptics.driveFor(s01, 0.5)
    local duty = hi / (hi + lo)
    T.check(duty > prevDuty, ("duty rises with strength (%.2f)"):format(duty))
    T.check(hi >= 1 and lo >= 1, "both halves of the cycle are non-zero")
    T.check(count >= 1 and count <= 0xFFFF, "the repeat count fits the field")
    prevDuty = duty
  end
  local hi, lo = DeckHaptics.driveFor(1.0, 0.5)
  T.check(math.abs((hi + lo) - math.floor(1000000 / DeckHaptics.FREQ_HZ)) <= 2,
    "the cycle length is the drive frequency, whatever the duty")
  T.check(select(4, DeckHaptics.driveFor(1.0, 0.5)),
    "the loudest setting also stacks the kernel path underneath")
  T.check(not select(4, DeckHaptics.driveFor(0.1, 0.5)),
    "and a quiet one does not, so a tick stays a tick")

  -- ------- count must never be zero
  --
  -- On this device count=0 does not mean "play nothing", it means REPEAT
  -- FOREVER. Both the availability probe and stop() were written with zero,
  -- so merely ASKING whether haptics existed started an endless buzz, and the
  -- one function meant to end it started another. Symptom: a Deck vibrating
  -- continuously with no game running and no way to switch it off.
  --
  -- Nothing in the module may produce a zero count, at any duration.
  for _, secs in ipairs({0, 1e-9, 0.0001, 0.001, 0.01, 1, 60}) do
    for _, s01 in ipairs({0.01, 0.5, 1.0}) do
      local _, _, count = DeckHaptics.driveFor(s01, secs)
      T.check(count >= 1,
        ("count is %d for %gs at %.2f -- zero would repeat forever")
          :format(count, secs, s01))
      T.check(count <= 0xFFFF, "and fits the 16-bit field")
    end
  end
  T.check(not DeckHaptics.SHADER_SRC, "(no shader here; this pass is hardware)")

  -- headless: no HID node in this harness, so it must say so and not throw
  T.check(pcall(DeckHaptics.status), "the haptic status is safe with no device")
  T.check(pcall(DeckRumble.status), "and so is the driver's")
  T.check(pcall(DeckRumble.tick), "and a tick with nothing connected")
end

-- ------- and its failure contract

T.eq(select(2, GbcLight.patchSource("void effect() { return; }")), "NO HOOK",
  "a shader with no lightPos statement is refused, not mangled")
T.eq(select(2, GbcLight.patchSource(nil)), "NO SRC",
  "and so is a missing source")

-- ------- settings

local schema = Settings.schema()
local function schemaFor(key)
  for _, row in ipairs(schema) do if row.key == key then return row end end
end
-- A LITERAL count here is the third instance of the same stale-constant trap
-- this file has now had (see the version assertion above, and main.lua's note
-- about it): it fails on every honest addition and tells you nothing about
-- whether the schema is right. What is worth asserting is that the schema and
-- the order agree -- that a setting cannot be added to one and forgotten in
-- the other, which is the failure that actually loses a row from a menu.
T.eq(#schema, #Settings.order,
  "the schema has exactly one entry per ordered setting")
do
  local seen = {}
  for _, row in ipairs(schema) do
    T.check(not seen[row.key], "no setting is defined twice: " .. tostring(row.key))
    seen[row.key] = true
  end
  for _, s in ipairs(Settings.order) do
    T.check(seen[s.key], "every ordered setting reaches the schema: " .. s.key)
  end
end
-- SCREEN FX leads, then MOTION. The two masters, most-global first: SCREEN
-- FX gates every picture pass, MOTION gates the light the mod exists for.
T.eq(schema[1].key, "screenfx", "SCREEN FX leads: it governs the most")
T.eq(schema[2].key, "ptlight",
  "then ROOM LIGHT, which answers to BOTH panels and so belongs above either "
  .. "of their pages rather than inside one of them")
T.eq(schema[3].key, "motion", "and MOTION is next")
-- assert the SCHEMA default, not the live value: the live one resolves
-- through mod.options against whatever the player last saved, so asserting
-- it makes the suite pass or fail on the contents of options.lua

local shadowSchema = schemaFor("shadow")
local vals = {}
for _, c in ipairs(shadowSchema.choices) do vals[c[2]] = true end
T.check(vals.follow and vals.fixed and vals.off,
  "SHADOW offers FOLLOW, FIXED and OFF")
T.eq(shadowSchema.default, "follow", "and defaults to FOLLOW")

T.eq(schema[1].default, "on",
  "SCREEN FX ships ON, so adding this switch changes nothing by itself")
T.eq(schema[2].default, "normal", "ROOM LIGHT ships at the reference level")
T.eq(schema[3].default, "tilt",
  "and MOTION defaults to TILT, so enabling the mod is the opt-in")
for _, row in ipairs(schema) do
  T.check(type(row.label) == "string" and row.label ~= "",
    "setting " .. row.key .. " carries a row label")
  T.check(type(row.help) == "string" and row.help ~= "",
    "setting " .. row.key .. " carries help text")
end

-- ------- the menu tree
--
-- The page was one flat list of thirty-seven rows against a FOUR-row
-- viewport. Splitting it into groups fixes the scrolling and introduces one
-- new way to lose a setting that the flat list could not have: a setting can
-- now exist, persist and do its job while appearing on no page at all, which
-- looks exactly like the feature having been removed.
--
-- `Settings.order` is derived FROM the groups, so everything ordered is
-- grouped by construction. What that cannot catch is the other direction --
-- a Setting.new assigned to Settings.something and never added to a group.
-- It would be absent from the schema, absent from RESET ALL, and invisible.
-- So this walks the module's own fields and insists every setting it finds
-- is reachable.
do
  local Setting = V.require("Setting")
  local ordered = {}
  for _, s in ipairs(Settings.order) do ordered[s] = true end

  local found = 0
  for name, value in pairs(Settings) do
    if type(value) == "table" and getmetatable(value) == Setting then
      found = found + 1
      T.check(ordered[value],
        ("Settings.%s (%s) is on a page: every setting must be reachable")
          :format(name, tostring(value.key)))
    end
  end
  T.check(found == #Settings.order,
    ("the module defines %d settings and orders %d -- they must agree")
      :format(found, #Settings.order))

  -- no setting on two pages: it would show two rows that write one value,
  -- and changing either would silently disagree with the other on screen
  local seen = {}
  for _, g in ipairs(Settings.groups) do
    for _, s in ipairs(g.rows) do
      T.check(not seen[s.key],
        "setting appears on exactly one page: " .. tostring(s.key))
      seen[s.key] = true
    end
  end
  for _, s in ipairs(Settings.top) do
    T.check(not seen[s.key],
      "a top-level setting is not also in a group: " .. tostring(s.key))
  end

  for _, g in ipairs(Settings.groups) do
    T.check(type(g.id) == "string" and g.id ~= "", "every group has an id")
    T.check(type(g.label) == "string" and g.label ~= "",
      "group " .. g.id .. " carries a label")
    T.check(type(g.help) == "string" and g.help ~= "",
      "group " .. g.id .. " carries help text, like every row does")
    T.check(#g.rows > 0, "group " .. g.id .. " is not empty")
    -- The label shares the row's 160px line with the cursor at x=8 and the
    -- text at x=16, same as any other label.
    T.check(16 + #g.label * 8 <= 160,
      ("group label %s fits the screen"):format(g.label))
  end
end

-- The root page: what it opens, and what sits at the top of it.
do
  local Menu = V.require("GyroMenu")
  local root = Menu.new(nil)
  T.check(#root.rows >= 3, "the root page has rows")

  T.eq(root.rows[1].id, "status",
    "SENSOR is the FIRST row -- it was last, which is the wrong end for the "
    .. "row that says why nothing is happening")
  T.eq(root.rows[2].id, "axismap",
    "AXIS MAP is second, ahead of everything it explains")
  T.eq(root.rows[3].id, "DECK_TILT:screenfx",
    "SCREEN FX sits directly under AXIS MAP, where someone looking for "
    .. "\"turn the effects off\" will meet it first")
  T.eq(root.rows[4].id, "DECK_TILT:ptlight",
    "ROOM LIGHT is on the root, not inside a panel's page: it changes both "
    .. "of them, and inside the GBC page it was unreachable from the DMG side")
  T.eq(root.rows[5].id, "DECK_TILT:motion",
    "and the light's own master stays on the root beside them")

  -- every group is reachable from the root, exactly once
  local opens = {}
  for _, row in ipairs(root.rows) do
    local id = tostring(row.id):match("^group:(.+)$")
    if id then
      T.check(not opens[id], "group " .. id .. " is opened by one row")
      opens[id] = true
      T.check(type(row.activate) == "function",
        "group row " .. id .. " opens its page")
    end
  end

  -- ------- a row that OPENS something shows no value
  --
  -- The engine's viewport gives every row a second line, and a category name
  -- has nothing true to put on it. A summary of the page behind it was tried
  -- and removed: under TILT SETUP a second line reading TURN/TIP invites you
  -- to read it as that row's own setting, and it is one arbitrary member of
  -- the nine rows inside. The second line stays empty so the name is the
  -- whole of the row.
  --
  -- Asserted as the ABSENCE of a value function rather than an empty string,
  -- because that is what OptionRows keys on: `row.value and row.value(game)
  -- or ""`. A function returning "" would pass an eyeball test and is the
  -- obvious thing to write next time.
  for _, row in ipairs(root.rows) do
    local isPage = tostring(row.id):match("^group:") or row.id == "axismap"
    if isPage then
      T.check(row.value == nil,
        ("%s opens a page, so it carries no value line"):format(row.label))
      T.check(type(row.activate) == "function",
        ("%s opens something when you press A"):format(row.label))
    end
  end

  -- ...and the rows that are NOT pages still have one, so this did not
  -- quietly strip the readouts and the settings too
  for _, id in ipairs({ "status", "DECK_TILT:motion", "recentre", "reset" }) do
    local found
    for _, row in ipairs(root.rows) do if row.id == id then found = row end end
    T.check(found ~= nil, "the root page still has " .. id)
    T.check(found and found.value ~= nil,
      id .. " is a readout or a setting, so it keeps its value line")
  end
  for _, g in ipairs(Settings.groups) do
    T.check(opens[g.id], "the root page opens " .. g.id)
  end

  -- The whole point of the change: the root must be short enough to be read
  -- without hunting. What protects it is NOT an absolute row count -- that
  -- constant has now been rewritten twice, once per category added, which is
  -- the signature of a test asserting the wrong thing. The page cannot grow
  -- back to thirty-seven rows because it only ever grows by CATEGORY, never
  -- by setting, and a category row is a bare name with no value to read.
  --
  -- So the structural contract is the assertion, and the only real ceiling
  -- is on how many CATEGORIES there may be -- which is the number a player
  -- actually has to hold in their head.
  local OptionRows = require("src.ui.OptionRows")
  -- eight fixed rows: SENSOR, AXIS MAP, SCREEN FX, ROOM LIGHT, MOTION,
  -- RESET FX, RESET ALL, RECENTRE. The contract is that the root grows by
  -- CATEGORY and by nothing else, so this number moves only when a master or
  -- an action row is added.
  T.eq(#root.rows, 8 + #Settings.groups,
    "the root is its eight fixed rows plus one per category, nothing else")
  T.check(#Settings.groups <= 10,
    ("%d categories: past about ten the root stops being a menu and becomes "
     .. "a list again"):format(#Settings.groups))

  -- and no group page may be worse than the root it was extracted from
  for _, g in ipairs(Settings.groups) do
    local page = Menu.group(nil, g)
    T.check(#page.rows > 0, g.id .. " builds a page with rows")
    T.check(#page.rows + 1 <= OptionRows.VISIBLE * 3,
      ("%s is %d rows including BACK, within three screens")
        :format(g.id, #page.rows + 1))
    for _, row in ipairs(page.rows) do
      T.check(type(row.label) == "string" and row.label ~= "",
        g.id .. " row carries a label")
      T.check(16 + #row.label * 8 <= 160,
        ("%s row label %s fits the screen"):format(g.id, row.label))
    end
  end

  -- GLOW COLOUR moved off the root onto CRT TUBE, and the swatch strip is
  -- published by whichever page holds it. If that id stayed on the root the
  -- strip would be drawn beside whatever row scrolled into its slot.
  T.check(root.swatchRowId == nil,
    "the root page claims no swatch row")
  local tube
  for _, g in ipairs(Settings.groups) do if g.id == "tube" then tube = g end end
  T.check(tube ~= nil, "there is a CRT TUBE group")
  T.eq(Menu.group(nil, tube).swatchRowId, "DECK_TILT:beamglowcol",
    "and its page is the one that publishes the colour swatches")
end

-- ------- every character this mod draws must exist in the font
--
-- The failure this exists for is silent by construction. Font.encode
-- substitutes a SPACE for any character the Game Boy charmap lacks and warns
-- ONCE to the log -- so an unmapped character is not a crash, not a garbled
-- glyph and not a test failure. It is a blank, on a console, in a menu nobody
-- re-reads. Three had shipped:
--
--   `>`  the AXIS MAP row's value, and the mark six group rows were going to
--        use, which would have read as six empty rows
--   `+`  "SIDEWAYS +/-" and "UP/DOWN +/-", drawn as "SIDEWAYS  /-"
--   `%`  every rung of CRT COLOUR and CRT CONTRAST, drawn as "125"
--
-- The set below was MEASURED off the running game (Font.split over printable
-- ASCII against Red's real charmap), not guessed from the source. It is
-- hardcoded because this harness loads a fixture charmap with different
-- coverage, so asking the font here would test the fixture rather than the
-- game.
local RENDERABLE = "!\"'(),-./0123456789:;?ABCDEFGHIJKLMNOPQRSTUVWXYZ[]"
  .. "abcdefghijklmnopqrstuvwxyz "
do
  local ok = {}
  for i = 1, #RENDERABLE do ok[RENDERABLE:sub(i, i)] = true end

  local function drawable(text, what)
    for i = 1, #text do
      local c = text:sub(i, i)
      T.check(ok[c],
        ("%s: the font has no glyph for %q, which draws as a blank -- %s")
          :format(what, c, text))
    end
  end

  for _, s in ipairs(Settings.order) do
    drawable(s.label, "setting label " .. s.key)
    for _, l in ipairs(s.labels) do
      drawable(l, "value label of " .. s.key)
    end
  end
  for _, g in ipairs(Settings.groups) do
    drawable(g.label, "group label " .. g.id)
  end

  local Menu = V.require("GyroMenu")
  local pages = { Menu.new(nil) }
  for _, g in ipairs(Settings.groups) do pages[#pages + 1] = Menu.group(nil, g) end
  for _, page in ipairs(pages) do
    for _, row in ipairs(page.rows) do
      drawable(row.label, "row label")
      if row.value then
        local okV, text = pcall(row.value, nil)
        if okV and type(text) == "string" then
          drawable(text, "row value of " .. tostring(row.label))
        end
      end
    end
  end

  drawable(Menu.HINT, "the SELECT hint")
  -- and the marker itself: `>` must not creep back in as the obvious choice
  T.check(not ok[">"],
    "`>` is confirmed absent from the font, which is why no row uses it")
end

-- ------- reach: the light must cover the whole frame
--
-- The first cut of this mod clamped the light to a box around the stock
-- rest point, which put the bottom of the screen out of reach. A smoke test
-- cannot catch that -- the light still moved, just not far enough -- so the
-- reach is asserted here in the units it actually failed in: degrees of
-- tilt.

-- Reach is now expressed as a contract about ROOM, not about a fixed amount
-- of tilt: from wherever centre is, using up the tilt that remains on a side
-- must sweep the light to that edge.  The old form asserted that a specific
-- 0.62 of tangent reached the edge, which quietly assumed centre always sat
-- in the same place -- untrue the moment the anchor calibrates to a player.

Settings.xrange:sync("normal")
Settings.yrange:sync("normal")
Settings.signx:sync("pos")
Settings.signy:sync("pos")

-- Reach, in degrees of tilt.  On NORMAL a thirty degree tilt should carry
-- the light from centre to an edge -- a comfortable wrist movement, and the
-- same amount whatever angle the console is already held at.
local F0 = Motion.FRAME
local _, down30 = Motion.project(0, -30)
local _, up30   = Motion.project(0, 30)
T.check(down30 >= 0.999,
  ("thirty degrees of tilt reaches the bottom (got %.2f)"):format(down30))
T.check(up30 <= 0.001,
  ("and thirty the other way reaches the top (got %.2f)"):format(up30))
local left30  = Motion.project(30, 0)
local right30 = Motion.project(-30, 0)
T.check(left30 <= 0.001 and right30 >= 0.999,
  ("and both sides (got x=%.2f..%.2f)"):format(left30, right30))

T.eq(F0.restY, 0.5, "the light rests at the centre of the frame")

-- the response must not depend on how the console is already held: the same
-- tilt from any starting angle gives the same movement
local moves = {}
-- up to 80, because 80+10 is vertical and there is nothing past it: asin
-- folds over at 90 degrees, so a "tilt" beyond that is the console turning
-- upside down rather than tilting further
for _, base in ipairs({ 0, 20, 45, 70, 80 }) do
  local r0 = math.rad(base)
  local r1 = math.rad(base + 10)
  local _, a0 = Motion.tilt(0, -math.sin(r0), math.cos(r0))
  local _, a1 = Motion.tilt(0, -math.sin(r1), math.cos(r1))
  moves[#moves + 1] = math.abs(select(2, Motion.project(0, a1 - a0)) - 0.5)
end
local lo, hi = moves[1], moves[1]
for _, m in ipairs(moves) do lo = math.min(lo, m); hi = math.max(hi, m) end
T.check(hi - lo < 0.01,
  ("ten degrees of tilt moves the light the same amount at every hold "
   .. "(%.3f..%.3f)"):format(lo, hi))

local function schemaFor2(key)
  for _, row in ipairs(schema) do if row.key == key then return row end end
end

-- ------- axis configuration
--
-- The two gains must be genuinely independent, the swap must actually
-- exchange the axes, and both must compose with the inversions.

Settings.xrange:sync("subtle")
local narrowX = Motion.project(0.3, 0)
Settings.xrange:sync("max")
local wideX = Motion.project(0.3, 0)
T.check(math.abs(wideX - 0.5) > math.abs(narrowX - 0.5),
  "M-X-RANGE MAX moves the light further sideways than SUBTLE")

Settings.xrange:sync("subtle")
local _, yUnchangedA = Motion.project(0, 0.3)
Settings.xrange:sync("max")
local _, yUnchangedB = Motion.project(0, 0.3)
T.eq(yUnchangedA, yUnchangedB,
  "and changing the sideways gain leaves the vertical response alone")
Settings.xrange:sync("wide")

-- every axis the hardware reports must be selectable, and OFF must pin
local srcSchema = schemaFor("srcx")
-- SIDEWAYS ships as TURN, not SIDE: SIDE reads exactly zero until you have
-- recentred in the pose you play in, and a default that does nothing until
-- the player finds a button is a broken default.
T.eq(srcSchema.default, "turn", "SIDEWAYS ships as TURN")
T.eq(schemaFor("srcy").default, "tip", "and UP/DOWN as TIP")
local offered = {}
for _, c in ipairs(srcSchema.choices) do offered[c[2]] = true end
for _, want in ipairs({ "tip", "twist", "turn", "spinx", "spiny", "off" }) do
  T.check(offered[want] == true, "SIDEWAYS offers the " .. want .. " axis")
end

-- The three rotations must stay separate: a rotation about one device axis
-- must not leak into the others.  Coupling here is what made both roll
-- directions slide the light downwards.
local srcs = Motion.sources(11, 0, 0)
T.check(srcs.tip == 11 and srcs.turn == 0 and srcs.twist == 0,
  "a pure tip drives only TIP")
srcs = Motion.sources(0, 0, 7)
T.check(srcs.twist == 7 and srcs.tip == 0 and srcs.turn == 0,
  "raising one side drives only SIDE")
T.eq(srcs.off, 0, "and OFF contributes nothing")

-- signs are per output and must not leak into each other
Settings.signx:sync("neg")
local sx1, sy1 = Motion.signed(0.3, 0.3)
T.check(sx1 == -0.3 and sy1 == 0.3,
  "SIDEWAYS +/- reverses sideways only")
Settings.signx:sync("pos")
Settings.signy:sync("neg")
local sx2, sy2 = Motion.signed(0.3, 0.3)
T.check(sx2 == 0.3 and sy2 == -0.3,
  "UP/DOWN +/- reverses vertical only")
Settings.signy:sync("pos")

-- RECENTRE must move the anchor, and RESET must put it back
Motion.resetCentre()


-- ------- the tilt measure must behave the same at every hold
--
-- This replaces a set of tests that asserted the OPPOSITE: that the mapping
-- accelerated as the screen turned edge-on, which is what a tangent does.
-- That property is exactly why forward-and-back died in the hand -- measured,
-- ten degrees of pitch gave 0.176 of travel held flat, 0.428 at forty-five
-- and 0.000 near vertical, because gx/gz and gy/gz share a denominator that
-- vanishes there and saturates both axes together.

local function gravAt(pitchDeg, rollDeg)
  local p, r = math.rad(pitchDeg), math.rad(rollDeg)
  local gy, gx = -math.sin(p), math.sin(r)
  local gz = math.sqrt(math.max(0, 1 - gy * gy - gx * gx))
  return gx, gy, gz
end

local flatX, flatY = Motion.tilt(gravAt(0, 0))
T.check(math.abs(flatX) < 1e-6 and math.abs(flatY) < 1e-6,
  "flat on its back is zero tilt on both axes")

-- uniform response: the same ten degrees must read as ten degrees whether
-- the console is flat, half-raised or nearly upright
for _, base in ipairs({ 0, 20, 45, 70 }) do
  local _, a0 = Motion.tilt(gravAt(base, 0))
  local _, a1 = Motion.tilt(gravAt(base + 10, 0))
  T.check(math.abs(math.abs(a1 - a0) - 10) < 0.01,
    ("ten degrees of pitch reads as ten degrees at a %d degree hold (got %.2f)")
      :format(base, math.abs(a1 - a0)))
end

-- the axes must be independent, or a diagonal cannot reach a corner
local dx0, dy0 = Motion.tilt(gravAt(0, 0))
local dx1, dy1 = Motion.tilt(gravAt(20, 20))
T.check(math.abs(dx1 - dx0) > 1 and math.abs(dy1 - dy0) > 1,
  "a diagonal tilt moves BOTH axes, so the corners are reachable")
local _, pureRoll = Motion.tilt(gravAt(0, 25))
T.check(math.abs(pureRoll) < 1e-6,
  "and a pure sideways tilt does not disturb the up/down axis")

-- bounded by construction, with no cap to guard
local _, vert = Motion.tilt(gravAt(90, 0))
T.check(math.abs(vert + 90) < 0.01,
  ("upright reads as -90 degrees, needing no clamp (got %.2f)"):format(vert))

-- there is no fixed anchor any more: it is simply wherever the console was
-- when it last centred, which is what makes RECENTRE mean what it says

-- ------- every source must be usable at a NORMAL hold
--
-- FLAT once shipped unanchored: TURN and TIP were measured from the anchor
-- while FLAT was raw, so at any real posture it arrived as ~0.87 and sat
-- clamped against an edge in every posture.  A source that cannot be moved
-- off an edge is not a setting.

local RX, RY, RZ = -0.014, -0.492, 0.870   -- measured on hardware
local rtx, rty = Motion.tilt(RX, RY, RZ)
-- at the anchor, every source reads zero deviation
local rest = Motion.sources(0, 0, 0)

Settings.signx:sync("pos")
Settings.signy:sync("pos")
for _, name in ipairs({ "tip", "twist", "turn", "spinx", "spiny", "off" }) do
  local v = rest[name]
  T.check(v ~= nil, name .. " is a real source")
  local lx = select(1, Motion.project(v, 0))
  local ly = select(2, Motion.project(0, v))
  T.check(lx > Motion.FRAME.xMin and lx < Motion.FRAME.xMax,
    ("%s does not pin the light sideways at a normal hold (x=%.2f)"):format(name, lx))
  T.check(ly > Motion.FRAME.yMin and ly < Motion.FRAME.yMax,
    ("%s does not pin the light vertically at a normal hold (y=%.2f)"):format(name, ly))
end

-- ------- the shadow must not snap as it crosses its pivot
--
-- The direction reverses there; at full length it leapt 6.90px in a single
-- frame -- twice the shadow's own length -- and hand tremor near that line
-- threw it 3.48px every frame.

local worstStep, px2, py2 = 0, nil, nil
for i = 0, 600 do
  local ly = -0.1 + 1.2 * i / 600
  local ox, oy = GbcLight.shadowOffset(0.5, ly, "follow")
  if px2 then
    local d = math.sqrt((ox - px2) ^ 2 + (oy - py2) ^ 2)
    if d > worstStep then worstStep = d end
  end
  px2, py2 = ox, oy
end
T.check(worstStep < 1.0,
  ("the shadow never jumps a visible distance in one frame (worst %.2f px)")
    :format(worstStep))

-- ------- RECENTRE must centre at ANY hold
--
-- Swept in DEGREES OF HOLD.  An earlier version swept a range the code
-- itself defined, so it could only confirm that assumption -- and the
-- assumption excluded holding the console upright, which is how people
-- hold a handheld.

Settings.yrange:sync("normal")
for deg = 0, 90, 5 do
  -- centring means the deviation is zero, whatever the hold
  local mid = select(2, Motion.project(0, 0))
  T.check(math.abs(mid - 0.5) < 1e-9,
    ("RECENTRE centres the light at a %d degree hold"):format(deg))
end

-- and from any hold, a tilt of a given size does the same thing
for deg = 0, 80, 10 do
  local r0, r1 = math.rad(deg), math.rad(deg + 10)
  local _, a0 = Motion.tilt(0, -math.sin(r0), math.cos(r0))
  local _, a1 = Motion.tilt(0, -math.sin(r1), math.cos(r1))
  T.check(math.abs(math.abs(a1 - a0) - 10) < 0.01,
    ("ten degrees reads as ten degrees from a %d degree hold"):format(deg))
end

-- ------- RESET ALL
for _, row in ipairs(schema) do
  local setting
  for _, s2 in ipairs(Settings.order) do
    if s2.key == row.key then setting = s2 end
  end
  if setting and #setting.values > 1 then
    local other = setting:defaultIndex() == 1 and 2 or 1
    setting:setPos(other, nil, true)
  end
end
Settings.resetAll(nil)
for _, row in ipairs(schema) do
  local setting
  for _, s2 in ipairs(Settings.order) do
    if s2.key == row.key then setting = s2 end
  end
  T.eq(setting and setting:get(), row.default,
    row.key .. " is back to its shipped default")
end

-- ------- help text must not print through the footer
-- The SELECT hint on the gyro page must fit the 160px screen.  A screenshot
-- caught the first version starting at x=16 and running 8px past the right
-- edge, so its last glyph was cut in half.  Invisible in source, obvious on
-- screen.
--
-- Measured as #text * 8, not with Font.width: the fixture charmap in this
-- harness has no glyph for several letters, and Font.encode drops what it
-- cannot map.  Font.width would therefore UNDER-report and pass a string
-- that overflows in the game -- the exact shape of test that lies.  Every
-- page of this font is fixed-width at 8, which Font.draw documents.
do
  local Menu = V.require("GyroMenu")
  T.check(not Menu.HINT:find("[^\32-\126]"),
          "the SELECT hint is plain ASCII, so one byte is one glyph")
  local right = Menu.HINT_X + #Menu.HINT * 8
  T.check(right <= 160,
          ("the SELECT hint ends at %d, inside the 160px screen"):format(right))
  T.check(Menu.HINT_X >= 8, "and starts no further left than the row margin")
end

-- Every fixed label on the AXIS MAP page must sit inside the screen with
-- room for its drop shadow.  A screenshot caught the title at y=0 and SIDE
-- ending at exactly x=160: both glyphs were on-screen, but the shadow the
-- mod itself draws was cut off, so they read as clipped.
--
-- 8px per character rather than Font.width, for the reason given above.
do
  local Map = V.require("AxisMap")
  local ROOM = Map.SHADOW_ROOM
  T.check(Map.LABELS ~= nil, "the axis page exposes its label positions")
  for name, L in pairs(Map.LABELS or {}) do
    local text, x, y = L[1], L[2], L[3]
    T.check(x >= 2, ("%s starts at x=%d, clear of the left edge"):format(name, x))
    T.check(y >= 2, ("%s starts at y=%d, clear of the top edge"):format(name, y))
    T.check(x + #text * 8 + ROOM <= 160,
      ("%s ends at x=%d with shadow room, inside 160")
        :format(name, x + #text * 8 + ROOM))
    T.check(y + 8 + ROOM <= 144,
      ("%s ends at y=%d with shadow room, inside 144"):format(name, y + 8 + ROOM))
  end
end


-- ------- the overlay path
--
-- The 3D voxel mod holds GBC FX at zero while installed, so the engine stops
-- calling present() at all.  These assert the two things that path turns on:
-- that we only draw when we mean to, and that we never ask for the option
-- the other mod is pinning.

do
  local GBCFX = require("src.render.GBCFX")
  local Overlay = V.require("Overlay")
  local level0 = function() GBCFX.setLevel(0) end

  T.check(Overlay.SHADER_SRC ~= nil, "the overlay ships its own shader")
  T.check(not Overlay.SHADER_SRC:find("BACK_BRIGHTNESS", 1, true),
    "which has no backing plate -- the part that fights a 3D view")
  T.check(not Overlay.SHADER_SRC:find("BRIGHTEN_LCD", 1, true),
    "and no LCD subpixel grid")
  T.check(Overlay.SHADER_SRC:find("GLARE_INTENSITY", 1, true) ~= nil,
    "but it keeps the glare")
  T.check(Overlay.SHADER_SRC:find("SHIMMER_CHROMA_GAIN", 1, true) ~= nil,
    "and the rainbow shimmer")
  -- the engine's 3.0 assumes a backing-blended frame; this pass has none
  T.check(Overlay.SHADER_SRC:find("SHIMMER_CHROMA_GAIN 1%.0") ~= nil,
    "at a gain that suits an unblended frame, not the engine's 3.0")
  -- FULL is pinned to the engine's own gain, so "as strong as GBC FX" is a
  -- fact about the number rather than a claim in the help text.
  T.eq(Settings.shimmer:get(), "max", "COLOUR defaults to MAX")
  -- Setting has setPos, not setValue: address the rows by their value's
  -- position so a reordering of the list shows up here as a failure.
  local function posOf(setting, want)
    for i, v in ipairs(setting.values) do if v == want then return i end end
  end
  local function shimmerAt(v)
    Settings.shimmer:setPos(posOf(Settings.shimmer, v)); return GbcLight.shimmerAmount()
  end
  local function glareAt(v)
    Settings.glare:setPos(posOf(Settings.glare, v)); return GbcLight.glareAmount()
  end
  T.eq(shimmerAt("off"), 0, "COLOUR OFF removes the colour entirely")
  T.eq(shimmerAt("full"), 3.0, "COLOUR FULL matches the engine's chroma gain")
  T.check(shimmerAt("max") > 3.0, "and MAX goes past what the engine does")
  T.check(shimmerAt("subtle") < 3.0, "while SUBTLE stays under it")
  T.eq(glareAt("off"), 0, "GLARE OFF removes the bright area")
  T.check(glareAt("max") > glareAt("normal"),
    "and MAX is brighter than the engine's own hotspot")
  T.check(glareAt("normal") == 1.0, "with NORMAL pinned to the engine's value")
  shimmerAt("max"); glareAt("high")
  T.check(Overlay.SHADER_SRC:find("deckShadowOff", 1, true) ~= nil,
    "and it takes the drop-shadow offset this mod computes")

  -- OFF must mean off, whatever else is true
  level0()
  Settings.overlay:setPos(3)                       -- OFF
  T.eq(Settings.overlay:get(), "off", "3D LIGHT can be set to OFF")
  T.eq(GbcLight.overlayWanted(), false, "and then the overlay never draws")
  T.eq(GbcLight.status(), "GBCFX OFF",
    "and the status row says the light is gone, because it is")

  -- AUTO draws only when the light is actually missing
  Settings.overlay:setPos(1)                       -- AUTO
  T.eq(Settings.overlay:get(), "auto", "AUTO is the shipped default")
  level0()
  T.eq(GbcLight.overlayWanted(), true,
    "AUTO draws when something else has pinned GBC FX off")
  GBCFX.setLevel(4)
  T.eq(GbcLight.overlayWanted(), false,
    "and stands down the moment the engine has its own light back")

  -- ON is unconditional
  Settings.overlay:setPos(2)
  T.eq(GbcLight.overlayWanted(), true, "ON draws whatever the level is")

  -- MOTION off outranks all three
  local keep = Settings.motion:pos()
  Settings.motion:setPos(3)
  T.eq(Settings.motion:get(), "off", "MOTION can be off")
  T.eq(GbcLight.overlayWanted(), false, "and then nothing draws, ON or not")
  Settings.motion:setPos(keep)
  Settings.overlay:setPos(1)
  GBCFX.setLevel(4)
end


-- GLSL reserved words in the overlay shader.
--
-- This suite cannot compile GLSL: the harness has no GPU and love.graphics is
-- a stub.  So the first version of this shader used `cast` as a variable, and
-- nothing here objected -- it failed at runtime on the device, and the mod
-- fell back to the stock pass and looked exactly like a mod that was working.
-- A silent fallback is the worst failure shape there is.
--
-- Compiling is out of reach; reading is not.  tests/drivers/deck_tilt_glsl.lua
-- does the real compile on hardware.
do
  local Overlay = V.require("Overlay")
  local RESERVED = {
    "cast", "asm", "union", "enum", "typedef", "template", "this", "packed",
    "goto", "switch", "default", "inline", "noinline", "public", "static",
    "extern", "external", "interface", "long", "short", "double", "half",
    "fixed", "unsigned", "input", "output", "hvec2", "hvec3", "hvec4",
    "sampler3D", "namespace", "using",
  }
  local body = Overlay.SHADER_SRC
  for _, word in ipairs(RESERVED) do
    -- as an identifier being DECLARED or ASSIGNED, not inside a comment or a
    -- longer word: "extern number time" is legal and must not trip this
    local bad = body:find("%f[%w_]float%s+" .. word .. "%f[^%w_]")
              or body:find("%f[%w_]vec[234]%s+" .. word .. "%f[^%w_]")
              or body:find("%f[%w_]" .. word .. "%s*=[^=]")
    T.check(not bad, ("the overlay shader does not use %q as an identifier"):format(word))
  end
end


-- ------- the centre must follow a changed hold
--
-- With the anchor fixed, 15 degrees of posture drift over 90 seconds leaves
-- the resting light at 0.09 -- hard against the top edge, with no room to
-- tilt further that way. That is the fault this row exists for, and it is
-- asserted here as a NUMBER so it cannot come back quietly.
--
-- Imu.poll is stubbed rather than Imu.x/y/z being set: light() takes its
-- reading from poll's return value, so setting the fields alone drives
-- nothing at all and every mode scores identically. The first version of
-- this simulation did exactly that and reported a clean pass for a broken
-- build.
do
  local function posOf(st, want)
    for i, v in ipairs(st.values) do if v == want then return i end end
  end
  local function grav(phi)
    local r = math.rad(phi)
    return 0, -math.sin(r), math.cos(r)
  end
  local realPoll = Imu.poll
  local phi = 30
  Imu.poll = function()
    Imu.rx, Imu.ry, Imu.rz = 0, 0, 0
    Imu.trust = 1
    local x, y, z = grav(phi)
    Imu.x, Imu.y, Imu.z = x, y, z
    return x, y, z
  end
  local realStatus = Imu.status
  Imu.status = "LIVE"

  local function restAfterDrift(mode, driftDeg, driftSecs)
    Settings.level:setPos(posOf(Settings.level, mode))
    Motion.reset(); Motion.resetCentre()
    phi = 30
    for _ = 1, 120 do Motion.light(1/60) end
    Motion.recentre()
    for i = 1, driftSecs * 60 do
      phi = 30 + driftDeg * i / (driftSecs * 60)
      Motion.light(1/60)
    end
    return select(2, Motion.light(1/60))
  end

  local off = restAfterDrift("off", 15, 90)
  T.check(off < 0.2,
    ("with AUTO LEVEL OFF a changed hold does strand the light (ly=%.3f)")
      :format(off))

  local normal = restAfterDrift("normal", 15, 90)
  T.check(math.abs(normal - 0.5) < 0.15,
    ("and NORMAL brings the centre back to the middle (ly=%.3f)"):format(normal))
  T.check(normal > off + 0.2, "which is a real improvement, not a rounding")

  -- and it must not eat an aiming tilt: hold 15 degrees for two seconds
  Settings.level:setPos(posOf(Settings.level, "normal"))
  Motion.reset(); Motion.resetCentre()
  phi = 30
  for _ = 1, 120 do Motion.light(1/60) end
  Motion.recentre()
  phi = 45
  local held
  for _ = 1, 120 do held = select(2, Motion.light(1/60)) end
  T.check(held < 0.30,
    ("a 15 deg tilt held 2s still reaches the upper area (ly=%.3f)"):format(held))

  Imu.poll, Imu.status = realPoll, realStatus
  Settings.level:setPos(posOf(Settings.level, "normal"))
  Motion.reset(); Motion.resetCentre()
end

local Help = V.require("HelpScreen")
local HM = Help.METRICS
T.check(HM ~= nil, "the help page exposes its layout for checking")
if HM then
  local lastBottom = HM.top + (HM.visible - 1) * HM.line + HM.glyphH - 1
  T.check(lastBottom < HM.footerY,
    ("the last body line ends at %d, clear of the footer at %d")
      :format(lastBottom, HM.footerY))
  T.check(HM.visible >= 6,
    ("and there is still a usable page of text (%d lines)"):format(HM.visible))
end
local hs = Help.new({ input = {} }, "T", "")
hs.lines = {}
for i = 1, HM.visible + 12 do hs.lines[i] = "LINE " .. i end
T.eq(hs:maxScroll(), 12, "a long description can scroll as far as it overruns")

-- ------- the complementary filter
--
-- Tested through Motion.fuse rather than through light(), because light()
-- needs a sensor and skips the fusion entirely without one.  That is not a
-- detail: the fusion was inline and therefore untestable headless, and a
-- sign error in the roll constant reached a player because of it.

-- Read from the module, never copied.  These were duplicated here before,
-- and that is exactly how a gyro constant that was 4.9x too small with the
-- wrong sign passed every run: the test asserted the same wrong number the
-- code used, so the two agreed all the way to the hardware.
local FDT = 1/60
local FTAU = Motion.FUSE_TAU
local FK = { Motion.GYRO_K.x, Motion.GYRO_K.y, Motion.GYRO_K.z }

-- a brisk tilt must reach the output on the FIRST frame; that immediacy is
-- the whole reason the gyro is in here
local f1 = select(1, Motion.fuse(0, 0, 0, 0, 0, 0, 3000, 0, 0, FDT))
T.check(math.abs(f1) > 0.1,
  ("the gyro moves the estimate on the first frame (%.3f deg)"):format(f1))

-- the measured bias must stay invisible
local bt, bu, bs = nil, nil, nil
for _ = 1, 60 * 60 do
  bt, bu, bs = Motion.fuse(bt, bu, bs, 0, 0, 0, 4, 1.4, -0.7, FDT)
end
T.check(math.abs(bt) < 0.5,
  ("a minute at the measured gyro bias drifts %.3f deg"):format(bt))

-- axes must stay separate
local la, lb, lc = Motion.fuse(0, 0, 0, 0, 0, 0, 3000, 0, 0, FDT)
T.check(math.abs(lb) < 1e-9 and math.abs(lc) < 1e-9,
  "the X gyro does not leak into the other axes")
la, lb, lc = Motion.fuse(0, 0, 0, 0, 0, 0, 0, 0, 3000, FDT)
T.check(math.abs(la) < 1e-9 and math.abs(lb) < 1e-9,
  "and neither does the Z gyro")

-- each axis must settle where the theory says.  A wrong SIGN shows up here
-- as the estimate settling on the far side of the accelerometer's value.
for i, nm in ipairs({ "x", "y", "z" }) do
  local rate, A = 200, 15
  local g = { 0, 0, 0 }; g[i] = rate
  local p, q, r
  for _ = 1, 60 * 20 do
    p, q, r = Motion.fuse(p, q, r,
      i == 1 and A or 0, i == 2 and A or 0, i == 3 and A or 0,
      g[1], g[2], g[3], FDT)
  end
  local got = ({ p, q, r })[i]
  local want = A + rate * FK[i] * FTAU
  T.check(math.abs(got - want) < 0.6,
    ("axis %s settles at %.2f, theory %.2f"):format(nm, got, want))
  -- An axis with a zero constant must land exactly on the accelerometer,
  -- which is the whole point of zeroing an unmeasured one.
  if FK[i] == 0 then
    T.check(math.abs(got - A) < 1e-6,
      ("axis %s has no measured gyro constant, so it follows the accelerometer alone"):format(nm))
  end
end

-- ------- graceful degradation on a host with no sensor
--
-- This harness has no FFI-visible HID device, so the mod must decline
-- rather than error -- the same path a non-Deck desktop takes.

T.eq(Imu.poll(0.016), nil, "polling a machine with no Deck IMU yields nothing")
T.check(Imu.isLive() == false, "and does not claim to be live")

T.eq(Motion.light(0.016), nil,
  "so the light mapping declines, and rendering falls through to stock")

Settings.motion:sync("off")
T.eq(Motion.light(0.016), nil,
  "MOTION off declines, so the engine draws its OWN animated light rather "
  .. "than this mod imitating it")
T.eq(GbcLight.status(), "OFF", "and says so on its status row")

-- DEMO must produce a light even with no sensor present -- that is the whole
-- point of it, and it is what makes the effect testable on any machine
Settings.motion:sync("demo")
local dx, dy = Motion.light(0.016)
T.check(dx ~= nil and dy ~= nil,
  "MOTION demo drives the light with no IMU at all")
T.check(dx >= Motion.FRAME.xMin and dx <= Motion.FRAME.xMax
        and dy >= Motion.FRAME.yMin and dy <= Motion.FRAME.yMax,
  ("and keeps it inside the frame (%.2f, %.2f)"):format(dx or -9, dy or -9))
Settings.motion:sync("tilt")

-- ------- install.sh must ship every module
--
-- A lib/ module missing from install.sh's FILES list produces an install that
-- LOADS and then dies the moment something first needs it, with V.require
-- raising "<name> is missing -- reinstall the mod" on the player's machine
-- rather than here. RfTv.lua was nearly shipped exactly that way -- the list
-- is hand-maintained and adding a module does not remind you to touch it.
--
-- Read from disk rather than from a second list in this file, because a
-- second list is the same bug one level up.
do
  local dir = MOD_PATH .. "/lib"
  local listed = {}
  local sh = io.open(MOD_PATH .. "/install.sh", "r")
  if sh then
    local body = sh:read("*a"); sh:close()
    for name in body:gmatch("lib/([%w_]+%.lua)") do listed[name] = true end
  end
  -- popen rather than lfs: this harness has no filesystem library, and the
  -- suite already runs from a shell that has ls.
  local pipe = io.popen("ls " .. dir .. " 2>/dev/null")
  local found = 0
  if pipe then
    for name in pipe:lines() do
      if name:match("%.lua$") then
        found = found + 1
        T.check(listed[name], "install.sh ships lib/" .. name)
      end
    end
    pipe:close()
  end
  T.check(found > 0, "the lib directory was actually read")
end

-- ------- the TV/RF pass
--
-- Like the rest of this mod the shader itself cannot run here -- no GPU, no
-- canvas. What CAN be checked is the contract that keeps it from breaking a
-- frame, and the arithmetic that decides what the artefacts look like, which
-- is the part a reader has to take on trust otherwise.
do
  local RfTv = V.require("RfTv")

  -- OFF by default: this must not change what anyone already has.
  T.eq(Settings.rf:get(), "off", "TV/RF ships OFF")
  T.check(not RfTv.wanted(), "so the pass does not want to draw")

  -- apply() must hand back something drawable on EVERY path. In this harness
  -- there is no love.graphics at all, which is the harshest version of the
  -- failure it has to survive: the contract is that a caller can write
  -- `canvas = RfTv.apply(canvas, ps)` unconditionally and never get nil.
  local fake = {}
  T.eq(RfTv.apply(fake, 5), fake,
    "apply hands the canvas straight back while the pass is off")
  Settings.rf:sync("normal")
  T.check(RfTv.wanted(), "TV/RF NORMAL wants to draw")
  T.eq(RfTv.apply(fake, 5), fake,
    "and still hands the original back when there is no GPU to draw with, "
    .. "rather than returning nil and taking the frame with it")
  T.eq(RfTv.apply(nil, 5), nil, "a nil canvas in is a nil canvas out")

  -- The rungs have to be ordered and bounded, or a row can select a value
  -- that is stronger than the one above it.
  for _, pair in ipairs({
    { RfTv.STRENGTH, { "off", "soft", "normal", "harsh" } },
    { RfTv.DOTS,     { "off", "low", "normal", "high" } },
    { RfTv.COLOUR,   { "off", "low", "normal", "high" } },
    { RfTv.CURVE,    { "off", "low", "normal", "high" } },
    { RfTv.NOISE,    { "off", "low", "normal", "high" } },
  }) do
    local map, order = pair[1], pair[2]
    T.eq(map[order[1]], 0, "the OFF rung is exactly zero, not merely small")
    for i = 2, #order do
      T.check(map[order[i]] >= map[order[i - 1]],
        ("%s is at least %s"):format(order[i], order[i - 1]))
    end
  end
  T.check(RfTv.STRENGTH.harsh <= 1.0,
    "the master mix never exceeds a full wet signal")

  -- The one derived constant, checked against the two reference constants it
  -- comes from rather than against itself. If someone edits CYCLES_PER_PX to
  -- taste, this says so -- it is the number every artefact's scale hangs off,
  -- and a silent edit to it is the difference between dots and stripes.
  local kFsc = 315e6 / 88.0            -- ntsc_decoder.hpp
  local activeLine = 52.6e-6           -- ntsc_decoder.cpp full_span
  local expect = kFsc * activeLine / 160.0
  local got = tonumber(RfTv.SHADER_SRC:match("#define CYCLES_PER_PX ([%d%.]+)"))
  T.check(got ~= nil, "the shader states its cycles-per-pixel as a constant")
  T.check(math.abs(got - expect) < 0.001,
    ("CYCLES_PER_PX %.4f is 52.6us x 3.579545MHz / 160 = %.4f"):format(
      got or -1, expect))

  -- Constants lifted verbatim from the reference's CRT pass. Asserted because
  -- they are the difference between reproducing measured hardware and
  -- reproducing someone's taste, and nothing else would notice a drift.
  T.check(RfTv.SHADER_SRC:find("#define BARREL_K1 0.055", 1, true) ~= nil,
    "barrel k1 is the reference's 0.055")
  T.check(RfTv.SHADER_SRC:find("#define SCAN_FLOOR 0.72", 1, true) ~= nil,
    "the scanline floor is the reference's 0.72")
  T.check(RfTv.SHADER_SRC:find("#define VIGNETTE 0.18", 1, true) ~= nil,
    "the vignette coefficient is the reference's 0.18")

  -- The decode matrix must be the inverse of the encode one, or the pass
  -- changes the colour of a frame it is supposed to leave alone at OFF.
  T.check(RfTv.SHADER_SRC:find("1.140", 1, true)
          and RfTv.SHADER_SRC:find("2.032", 1, true)
          and RfTv.SHADER_SRC:find("0.395", 1, true)
          and RfTv.SHADER_SRC:find("0.581", 1, true),
    "YUV->RGB uses the reference's own coefficients")

  Settings.rf:sync("off")
end

-- ------- every declared uniform must actually be used
--
-- A GLSL compiler removes a uniform nothing references, and LOVE's send()
-- then throws on a name the linked program does not have. In these passes
-- that failure is caught and turns the whole pass off -- so the symptom is
-- an effect that silently does nothing, which is indistinguishable from the
-- row being set to OFF. CrtBeam shipped with an unused `time` and was dead on
-- the GPU while compiling cleanly and passing every other check here.
--
-- This is checked by reading the source rather than by running it, because
-- the harness has no GPU and would not have caught it either.
do
  for _, name in ipairs({ "RfTv", "CrtBeam", "Overlay", "PixelTrans" }) do
    local mod = V.require(name)
    local src = mod.SHADER_SRC
    T.check(type(src) == "string", name .. " exposes its shader source")
    -- the body is everything after the last extern declaration
    local lastExtern = 0
    for s, e in src:gmatch("()extern%s+[%w_]+%s+[%w_]+%s*;()") do
      lastExtern = e
    end
    local body = src:sub(lastExtern)
    local declared = {}
    for uniform in src:gmatch("extern%s+[%w_]+%s+([%w_]+)%s*;") do
      declared[uniform] = true
      T.check(body:find(uniform, 1, true) ~= nil,
        ("%s: uniform '%s' is declared and used"):format(name, uniform))
    end

    -- ...and the other direction, which is the one that actually bit. The
    -- `time` uniform was deleted from CrtBeam's shader and its send() was
    -- left behind, so every frame threw on an unknown name and the pass
    -- turned itself off -- while compiling cleanly, reporting no error, and
    -- passing the declared-and-used check above. Reading the source is the
    -- only way to catch it here; the GPU is where it shows up otherwise.
    -- Scan the module itself AND GbcLight, because a shader's uniforms are
    -- not always sent from the file that declares them: Overlay owns its
    -- source but every one of its sends lives in GbcLight.presentOverlay, so
    -- checking only the owning file leaves exactly that pass unguarded.
    local files = { MOD_PATH .. "/lib/" .. name .. ".lua" }
    if name == "Overlay" then
      files[#files + 1] = MOD_PATH .. "/lib/GbcLight.lua"
    end
    for _, path in ipairs(files) do
      local lua = nil
      local fh = io.open(path, "r")
      if fh then lua = fh:read("*a"); fh:close() end
      T.check(lua ~= nil, path .. " is readable")
      if lua then
        for sent in lua:gmatch('send%s*%(%s*"([%w_]+)"') do
          -- GbcLight also drives the ENGINE's shader (level, time,
          -- pixelScale), so only judge the names this module owns.
          if sent:sub(1, 4) == "deck" or declared[sent] then
            T.check(declared[sent],
              ("%s: send(\"%s\") has a matching extern"):format(name, sent))
          end
        end
      end
    end
  end
end

-- ------- the electron-beam pass
do
  local CrtBeam = V.require("CrtBeam")

  -- Every row OFF by default, and each one independently switchable, which is
  -- the point of having four rather than one dial.
  for _, s in ipairs({ Settings.beammask, Settings.beamscan,
                       Settings.beamglow, Settings.beamedge,
                       Settings.beamroll }) do
    T.eq(s:get(), "off", s.label .. " ships OFF")
    T.eq(s.values[1], "off", "and OFF is the first rung, so LEFT reaches it")
  end
  T.check(not CrtBeam.wanted(), "so the pass does not want to draw")

  -- Turning any ONE row on must be enough to make the pass run, and turning
  -- it back off must be enough to stop it. A pass that only answers to a
  -- master row would strand the other three.
  for _, pair in ipairs({
    { Settings.beammask, "grille" }, { Settings.beamscan, "normal" },
    { Settings.beamglow, "normal" }, { Settings.beamedge, "normal" },
    { Settings.beamroll, "60hz" },
  }) do
    pair[1]:sync(pair[2])
    T.check(CrtBeam.wanted(), pair[1].label .. " alone turns the pass on")
    pair[1]:sync("off")
    T.check(not CrtBeam.wanted(), "and OFF alone turns it back off")
  end

  -- Same no-nil contract as RfTv: chained without a branch, so neither may
  -- ever hand back something a caller cannot draw.
  local fake = {}
  T.eq(CrtBeam.apply(fake, 5), fake, "apply hands the canvas back while off")
  Settings.beammask:sync("shadow")
  T.eq(CrtBeam.apply(fake, 5), fake,
    "and still does with no GPU, rather than returning nil")
  T.eq(CrtBeam.apply(nil, 5), nil, "a nil canvas in is a nil canvas out")
  Settings.beammask:sync("off")

  -- crt-royale's published defaults. Asserted because they are the difference
  -- between reproducing a shader people have looked at for a decade and
  -- reproducing a guess, and nothing else here would notice a drift.
  local src = CrtBeam.SHADER_SRC
  for _, want in ipairs({
    "#define BEAM_MIN_SIGMA 0.02", "#define BEAM_MAX_SIGMA 0.30",
    "#define BEAM_SPOT_POWER 0.33", "#define BEAM_MIN_SHAPE 2.0",
    "#define BEAM_MAX_SHAPE 4.0", "#define BEAM_SHAPE_POWER 0.25",
    "#define DIFFUSION_WEIGHT 0.075",
  }) do
    T.check(src:find(want, 1, true) ~= nil, "royale default kept: " .. want)
  end
  -- Blur Busters' own two
  T.check(src:find("#define GAIN_VS_BLUR 0.7", 1, true) ~= nil,
    "the beam simulator's brightness/blur tradeoff is its own 0.7")
  T.check(src:find("#define BEAM_GAMMA 2.4", 1, true) ~= nil,
    "and its gamma is 2.4 -- the arithmetic is done in linear light, which is "
    .. "what stops the rolling scan banding")

  -- The mask must not be a brightness cut. megatron's whole point is that the
  -- gun runs harder to pay for it, so the gain has to exceed unity.
  local gain = tonumber(src:match("#define MASK_GAIN ([%d%.]+)"))
  T.check(gain and gain > 1.0,
    ("the mask is paid for by gain (%s), not taken out of the picture"):format(
      tostring(gain)))

  -- Rung ladders ordered and OFF exactly zero.
  for _, map in ipairs({ CrtBeam.SCAN, CrtBeam.GLOW, CrtBeam.EDGE,
                         CrtBeam.ROLL, CrtBeam.MASK }) do
    T.eq(map.off, 0, "the OFF rung is exactly zero")
  end

  -- The rolling scan's ratio in particular must be switchable off, and OFF
  -- must reach the SHADER as a zero rather than merely stopping the row from
  -- reading well: the shader branches on beamRoll, so a non-zero there with
  -- the row OFF would keep modulating brightness invisibly.
  Settings.beamroll:sync("off")
  T.eq(CrtBeam.rollRatio(), 0,
    "CRT ROLL OFF derives a zero ratio, so the shader's roll branch is dead")
  T.eq(CrtBeam.rollStatus(), nil, "and the row shows no reading")
  Settings.beamroll:sync("60hz")
  T.check(CrtBeam.rollRatio() >= 0 , "and a tube rung derives a real ratio")
  Settings.beamroll:sync("off")
  -- The rungs name TUBE RATES, so they descend: a slower tube buys more blur
  -- reduction and costs more flicker.
  T.check(CrtBeam.ROLL["60hz"] > CrtBeam.ROLL["50hz"]
          and CrtBeam.ROLL["50hz"] > CrtBeam.ROLL["40hz"],
    "the tube rates descend")

  -- Blur reduction is 1 - 1/N, which must reproduce Blur Busters' own
  -- published figures or the ratio means something different from what they
  -- measured. These three are quoted in their README.
  local function pct(n) return math.floor(CrtBeam.blurReduction(n)*100 + 0.5) end
  T.eq(pct(2), 50, "120Hz for 60fps content is N=2 and 50%, as published")
  T.eq(pct(4), 75, "240Hz is N=4 and 75%")
  T.eq(pct(8), 88, "480Hz is N=8 and 87.5%")
  T.eq(pct(1), 0, "N=1 is no subframes and therefore no reduction")
  T.eq(pct(1.5), 33,
    "and the Deck's 90Hz with a 60Hz tube is N=1.5 and 33% -- real, and not "
    .. "the nothing an earlier version of this row called it")

  -- The ROLL readout must say nothing while the row is OFF, so it cannot put
  -- a refresh rate on a row that is doing nothing.
  T.eq(CrtBeam.rollStatus(), nil, "no readout while CRT ROLL is OFF")
end

-- ------- the GBC panel pass
--
-- The GBC panel pass (see lib/PixelTrans): light pixels
-- are windows onto the plate behind an unlit LCD, and sunlight leaks through
-- the quarter-wave film as an angle-dependent rainbow. The shader cannot run
-- here, so the model lives twice -- once in GLSL, once as pure Lua the
-- shader is held to -- and these tests exercise the Lua and then diff the
-- GLSL's literals against it, which is the same two-copy trap the gyro
-- constants fell into and the same cure: the copies are COMPARED every run
-- instead of trusted to agree.
do
  local Pt = V.require("PixelTrans")

  -- OFF by default: installing this must not change anyone's picture.
  T.eq(Settings.pt:schema().default, "off", "GBC SCREEN ships OFF")
  T.eq(Settings.pt.values[1], "off", "and OFF is the first rung")
  Settings.pt:sync("off")
  T.check(not Pt.wanted(), "so the pass does not want to draw")

  -- Same no-nil contract as RfTv and CrtBeam: chained without a branch.
  local fake = {}
  T.eq(Pt.apply(fake, 5), fake, "apply hands the canvas back while off")
  Settings.pt:sync("bright")
  T.check(Pt.wanted(), "GBC SCREEN BRIGHT wants to draw")
  T.eq(Pt.apply(fake, 5, 0.5, 0.5), fake,
    "and still hands the original back with no GPU, rather than nil")
  T.eq(Pt.apply(nil, 5), nil, "a nil canvas in is a nil canvas out")
  Settings.pt:sync("off")

  -- Every master rung maps onto one of the reference's PT_PIXEL_MODEs, and
  -- the rungs above OFF are the reference's own 0/1/2 -- a rung without a
  -- mode would silently draw as BRIGHT via the fallback.
  for _, v in ipairs(Settings.pt.values) do
    if v == "off" then
      T.eq(Pt.MODE[v], nil, "OFF has no mode: it means the pass does not run")
    else
      T.check(Pt.MODE[v] ~= nil, ("rung %s has a pixel mode"):format(v))
    end
  end

  -- Ladders ordered, OFF exactly zero, NORMAL the reference's own default --
  -- so NORMAL means "as the original effect" as a fact, not as a claim.
  T.eq(Pt.ALPHA.normal, 0.20, "SEE-THROUGH NORMAL is the reference's 0.20")
  T.eq(Pt.SHADOW.normal, 0.50, "LCD SHADOW NORMAL is the reference's 0.50")
  T.eq(Pt.RAINBOW.normal, 0.15, "RAINBOW NORMAL is the reference's 0.15")
  T.eq(Pt.SPREAD.normal, 1.8, "RAINBOW BANDS NORMAL is the reference's 1.8")
  T.eq(Pt.SPLOTCH.normal, 0.5, "FILM MARKS NORMAL is the reference's 0.5")
  for _, pair in ipairs({
    { Pt.ALPHA,   { "low", "normal", "high", "max" } },
    { Pt.SHADOW,  { "off", "soft", "normal", "deep" } },
    { Pt.RAINBOW, { "off", "subtle", "normal", "strong", "max" } },
    { Pt.SPREAD,  { "wide", "normal", "fine", "finest" } },
    { Pt.SPLOTCH, { "off", "low", "normal", "high" } },
  }) do
    local map, order = pair[1], pair[2]
    if map[order[1]] ~= nil and order[1] == "off" then
      T.eq(map.off, 0, "the OFF rung is exactly zero, not merely small")
    end
    for i = 2, #order do
      T.check(map[order[i]] > map[order[i - 1]],
        ("panel rung %s is above %s"):format(order[i], order[i - 1]))
    end
  end

  -- ---- white detection ----
  -- Both terms of the reference's test matter: a bright luma AND no dark
  -- channel. Luma alone passes saturated yellow, which is not a window.
  T.check(Pt.isWhite(1, 1, 1), "pure white is a window")
  T.check(Pt.isWhite(0.95, 0.95, 0.93), "and so is near-white")
  T.check(not Pt.isWhite(1, 1, 0.5),
    "a bright yellow is NOT: its blue channel gives it away")
  T.check(not Pt.isWhite(0.6, 0.6, 0.6), "and neither is a mid grey")
  T.check(not Pt.isWhite(0.92, 0.92, 0.7),
    "nor a pale cream whose lowest channel is under 90% of the threshold")

  -- BT.709 luma, the same weighting the engine's GBC FX uses.
  T.check(math.abs(Pt.luma(1, 1, 1) - 1) < 1e-9, "the luma weights sum to one")
  T.check(Pt.luma(0, 1, 0) > Pt.luma(1, 0, 0)
          and Pt.luma(1, 0, 0) > Pt.luma(0, 0, 1),
    "and green outweighs red outweighs blue, as 709 does")

  -- ---- the compositing arithmetic ----
  T.eq(Pt.alphaFor(0, 0.6, 0.2, false), 0,
    "WHITES leaves a non-white pixel entirely alone")
  T.check(Pt.alphaFor(0, 1.0, 0.2, true) > 0.5,
    "and makes a detected white a clear window")
  T.check(Pt.alphaFor(1, 0.8, 0.2, false) > Pt.alphaFor(1, 0.3, 0.2, false),
    "BRIGHT is graded: a brighter pixel is a clearer window")
  T.check(math.abs(Pt.alphaFor(1, 0.5, 0.2, false)
                   - 0.2 * 0.5 * Pt.BRIGHT_GAIN) < 1e-9,
    "at the reference's own gain of 2.665")
  T.eq(Pt.alphaFor(1, 1.0, 0.55, false), 1,
    "and is clamped at fully clear rather than overshooting the mix")
  T.check(math.abs(Pt.alphaFor(2, 0, 0.2, false) - 0.2) < 1e-9,
    "ALL gives even a black pixel the base transparency")

  -- ---- the spectral model ----
  -- The 7-wavelength table: every phase factor must be 4*pi over its own
  -- wavelength, which is the physics (cos^2 of the retardance phase), and
  -- the wavelengths must span the visible band the reference samples.
  --
  -- Within a NANOMETRE, not 1e-6: the reference's own literals disagree
  -- with the wavelengths its comments claim by up to 0.8nm (its k3 is
  -- exactly 1/42, which 4pi/528.571 is not). The literals are kept verbatim
  -- anyway, because they are what every screenshot of the reference was
  -- rendered with -- "the same rainbow" is a fact about the numbers that
  -- ran, not about the comment beside them. This check pins them to the
  -- physics closely enough that a typo in either copy still fails.
  T.eq(#Pt.SPECTRUM, 7, "seven wavelengths, as the reference integrates")
  for i, w in ipairs(Pt.SPECTRUM) do
    T.check(math.abs(4 * math.pi / w.k - w.nm) < 1.0,
      ("wavelength %d: k is 4pi over %.0fnm, within the reference's own "
       .. "rounding"):format(i, w.nm))
    if i > 1 then
      T.check(w.nm > Pt.SPECTRUM[i - 1].nm, "and the table ascends in nm")
    end
  end
  T.check(math.abs(Pt.SPECTRUM[1].nm - 400) < 0.01
          and math.abs(Pt.SPECTRUM[7].nm - 657.143) < 0.01,
    "spanning violet to red in equal steps")

  -- The GLSL carries the same table as literals (it cannot read a uniform
  -- array in GLSL 1.20), which is a second copy, which is the trap. Diffed
  -- here term by term so an edit to either side fails a test instead of
  -- quietly shifting the rainbow.
  local terms = {}
  for k, r, g, b in Pt.SHADER_SRC:gmatch(
      "cos%(([%d%.]+) %* g%); tint %+= vec3%(([%d%.]+), ([%d%.]+), ([%d%.]+)%)") do
    terms[#terms + 1] = { k = tonumber(k), s = { tonumber(r), tonumber(g),
                                                 tonumber(b) } }
  end
  T.eq(#terms, 7, "the shader integrates the same seven wavelengths")
  for i, t in ipairs(terms) do
    local w = Pt.SPECTRUM[i]
    T.check(w and math.abs(t.k - w.k) < 1e-9,
      ("shader wavelength %d carries the table's phase factor"):format(i))
    for c = 1, 3 do
      T.check(math.abs(t.s[c] - w.s[c]) < 1e-9,
        ("and its spectral colour, channel %d"):format(c))
    end
  end

  -- The tint itself: peak-normalised, bounded, and genuinely angle-dependent
  -- -- the same film seen at two angles gives two different hues, which is
  -- the entire effect.
  for _, g in ipairs({ 100, 207, 247, 275, 350, 500 }) do
    local r, gg, b = Pt.qwpTint(g)
    local peak = math.max(r, math.max(gg, b))
    T.check(math.abs(peak - 1) < 1e-9,
      ("tint at gamma %d is peak-normalised"):format(g))
    T.check(r >= 0 and gg >= 0 and b >= 0 and r <= 1 and gg <= 1 and b <= 1,
      ("and stays inside the gamut"):format(g))
  end
  local r1, g1, b1 = Pt.qwpTint(275)   -- head on: the film's design point
  local r2, g2, b2 = Pt.qwpTint(220)   -- tilted well over
  T.check(math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0.5,
    "head-on and tilted are visibly different colours, so tilting cycles hue")

  -- The geometry half: gamma is the full 275 dead under the light and FALLS
  -- with distance (Snell shortens the effective retardance), and the angle
  -- clamp bounds it away from zero -- the rainbow runs out of new colours at
  -- the edge of the screen rather than cycling forever.
  T.check(math.abs(Pt.gammaEff(0, 1.8) - 275) < 1e-9,
    "directly under the light the retardance is the full double-pass 275nm")
  T.check(Pt.gammaEff(0.2, 1.8) < Pt.gammaEff(0.1, 1.8)
          and Pt.gammaEff(0.4, 1.8) < Pt.gammaEff(0.2, 1.8),
    "and it falls monotonically with distance from the light")
  T.check(Pt.gammaEff(99, 1.8) > 207 and Pt.gammaEff(99, 1.8) < 208,
    "with the reference's 1.4rad clamp bounding it at ~207nm")
  T.check(Pt.gammaEff(0.3, 3.4) < Pt.gammaEff(0.3, 1.8),
    "a denser band setting reaches a given hue nearer the light")

  -- ---- the noise ----
  -- Deterministic and static: the plate is a physical object, so it must
  -- not crawl. Same input, same value, every call.
  T.eq(Pt.hash(12.3, 45.6), Pt.hash(12.3, 45.6), "the hash is deterministic")
  T.check(Pt.hash(12.3, 45.6) ~= Pt.hash(12.4, 45.6),
    "but not constant across positions")
  T.eq(Pt.paperNoise(0.3, 0.7, 0.25), Pt.paperNoise(0.3, 0.7, 0.25),
    "and so is the paper grain")

  -- The fbm's expected value is 0.4375 (three octaves of a 0..1 hash at
  -- amplitudes 1/2+1/4+1/8, halved), which is the NOISE_MEAN the shader
  -- subtracts -- so the grain TEXTURES the plate without brightening it.
  -- Measured over a lattice rather than trusted: 6400 samples land at 0.442.
  local sum, n = 0, 0
  local lo, hi = math.huge, -math.huge
  for i = 0, 79 do
    for j = 0, 79 do
      local v = Pt.paperNoise(i / 80, j / 80, 0.25)
      lo, hi = math.min(lo, v), math.max(hi, v)
      sum = sum + v
      n = n + 1
    end
  end
  T.check(lo >= 0 and hi < 1,
    ("paper grain stays in range over 6400 samples (%.3f..%.3f)")
      :format(lo, hi))
  T.check(math.abs(sum / n - 0.4375) < 0.02,
    ("the grain's mean is the shader's NOISE_MEAN 0.4375 (got %.4f), so the "
     .. "plate keeps its brightness"):format(sum / n))
  T.check(Pt.SHADER_SRC:find("#define NOISE_MEAN 0.4375", 1, true) ~= nil,
    "and the shader states that constant rather than a taste")

  -- The film noise is the SMOOTH one -- interpolated, so neighbouring
  -- pixels agree and the splotches are broad patches, not speckle. A step
  -- of 1/600th of the screen moves it by ~0.011; raw hash would jump the
  -- whole range.
  local worstStep = 0
  for i = 0, 599 do
    local a = Pt.filmNoise(i / 600 * 1.6, 0.37, 0.6)
    local b = Pt.filmNoise((i + 1) / 600 * 1.6, 0.37, 0.6)
    worstStep = math.max(worstStep, math.abs(a - b))
  end
  T.check(worstStep < 0.05,
    ("the film noise is smooth across neighbouring pixels (worst step %.4f)")
      :format(worstStep))
  T.check(math.abs(Pt.filmNoise(0.1, 0.1, 0.6) - Pt.filmNoise(1.3, 0.8, 0.6))
          > 0.01,
    "while still varying across the screen")

  -- ---- the plate colours ----
  -- Every rung resolves, PLAIN is genuinely colourless, OLIVE is the
  -- reference's Warm1 exactly, and the shader copy is brightness-normalised
  -- to the reference's 0.675 peak -- so the BACKING row changes only the
  -- colour and SEE-THROUGH stays the only row that changes how much plate
  -- there is.
  for _, v in ipairs(Settings.ptback.values) do
    T.check(Pt.BACKING[v] ~= nil, ("BACKING rung %s has a colour"):format(v))
    local r, g, b = Pt.backingColour(v)
    T.check(math.abs(math.max(r, math.max(g, b)) - Pt.BACKING_PEAK) < 1e-9,
      ("and %s is normalised to the reference's %.3f peak"):format(
        v, Pt.BACKING_PEAK))
  end
  local pr, pg, pb = Pt.backingColour("plain")
  T.check(pr == pg and pg == pb, "PLAIN is exactly colourless")
  local o = Pt.BACKING.olive
  T.check(o[1] == 0.651 and o[2] == 0.675 and o[3] == 0.518,
    "OLIVE is the reference's Warm1 -- the real console's plate, unretuned")
  T.eq(Settings.ptback:schema().default, "olive",
    "and it is the default, because it is what the effect is named for")

  -- The swatch strip follows the row onto the GBC SCREEN page with its own
  -- palette, exactly as GLARE TINT and GLOW COLOUR do on theirs.
  local Menu = V.require("GyroMenu")
  local gbc
  for _, g in ipairs(Settings.groups) do if g.id == "gbc" then gbc = g end end
  T.check(gbc ~= nil, "there is a GBC SCREEN group")
  local page = Menu.group(nil, gbc)
  T.eq(page.swatchRowId, "DECK_TILT:ptback",
    "its page publishes swatches for BACKING")
  T.eq(page.swatchPalette, Pt.BACKING,
    "with the plate palette, not another row's")
  T.eq(page.swatchSetting, Settings.ptback,
    "read from the setting itself rather than a copy")

  -- ---- the shadow is driven by the mod's light, not by a second sensor ----
  -- The offset comes from the same shadowOffset every other shadow here
  -- uses, so all of them agree about which way "away from the light" is.
  Settings.ptshadow:sync("normal")
  local ox, oy, op = Pt.shadowFor(1.1, 0.5)
  local gx, gy = GbcLight.shadowOffset(1.1, 0.5, "follow")
  T.check(math.abs(ox - gx) < 1e-9 and math.abs(oy - gy) < 1e-9,
    "with a light the panel shadow is GbcLight's own follow offset")
  T.check(ox < 0,
    "so a light on the right throws the plate shadow left, like the others")
  T.eq(op, Pt.SHADOW.normal, "at the LCD SHADOW row's opacity")

  -- With no light -- MOTION off, or no sensor -- the shadow must not vanish
  -- and must not guess: it takes the engine's own fixed down-right, which is
  -- also what the reference does with its sensor path disabled.
  local fx2, fy2 = Pt.shadowFor(nil, nil)
  local sx3, sy3 = GbcLight.shadowOffset(nil, nil, "fixed")
  T.check(math.abs(fx2 - sx3) < 1e-9 and math.abs(fy2 - sy3) < 1e-9,
    "with no light the panel shadow is the fixed stock offset")

  Settings.ptshadow:sync("off")
  local _, _, op2 = Pt.shadowFor(0.5, 0.5)
  T.eq(op2, 0, "LCD SHADOW OFF sends a zero opacity, so off means off")
  Settings.ptshadow:sync("normal")

  -- ---- the shader states the reference's constants ----
  -- Asserted for the same reason RfTv's and CrtBeam's are: they are the
  -- difference between porting a calibrated effect and porting a taste.
  for _, want in ipairs({
    "#define PT_THRESHOLD 0.90", "#define BACKING_BRIGHTNESS 0.48",
    "#define GRAIN_INTENSITY 0.065", "#define GAMMA_BASE 275.0",
    "#define N_FILM 1.5", "#define BRIGHT_GAIN 2.665",
    "#define REFLECT_FLOOR 0.03",
  }) do
    T.check(Pt.SHADER_SRC:find(want, 1, true) ~= nil,
      "reference constant kept: " .. want)
  end
  T.check(Pt.SHADER_SRC:find("0.94, 1.0, 0.865", 1, true) ~= nil,
    "and the double-pass polarizer tint, squared from single-pass")

  -- The reference's sensor path must be GONE, not carried: this mod already
  -- owns the tilt question, and a second accelerometer read inside a shader
  -- would be two filters fighting over one light.
  T.check(not Pt.SHADER_SRC:find("Accelerometer", 1, true)
          and not Pt.SHADER_SRC:find("getOrientedTilt", 1, true),
    "the upstream accelerometer path was deleted, not ported")
  T.check(Pt.SHADER_SRC:find("extern vec2 ptLight;", 1, true) ~= nil,
    "the shader takes ONE light position, the same one Motion computes")
  -- ...and no clock: the plate and its film are physical objects, and a
  -- `time` uniform is also the exact bug that silently killed CrtBeam once.
  T.check(not Pt.SHADER_SRC:find("extern number time", 1, true),
    "and no clock -- nothing about a plate should crawl")

  -- ---- where it sits in the chain ----
  -- The pass must run BEFORE the RF and CRT passes, so the barrel curve,
  -- the mask and the scanlines all happen TO the plate -- a panel drawn
  -- after the curve is a flat sticker on bowed glass, which is the failure
  -- mode this order exists to avoid.
  local src = nil
  local f = io.open(MOD_PATH .. "/lib/GbcLight.lua", "r")
  if f then src = f:read("*a"); f:close() end
  T.check(src ~= nil, "GbcLight.lua is readable")
  local pt = src:find("PixelTrans\"%)%.apply")
  local rf = src:find("RfTv\"%)%.apply")
  T.check(pt and rf and pt < rf,
    "the panel pass runs before RF, so the curve bends the plate too")
  -- and the light is computed once, above the panel pass, so the filters
  -- are never advanced twice in one frame
  local lightCall = src:find("Motion%.light%(dt%)")
  T.check(lightCall and lightCall < pt,
    "present computes the light once, before the panel pass reads it")

  -- ---- the engine must actually call present for it ----
  -- GBCFX.active() gates present(); at level 0 it answers false unless a
  -- pass of ours asks. Without this the GBC SCREEN rows would set values
  -- that never reach a frame while the 3D mod holds GBC FX off -- which is
  -- exactly the situation the pass is most useful in.
  do
    local GBCFX2 = require("src.render.GBCFX")
    local keepLevel = GBCFX2.level
    GBCFX2.setLevel(0)
    local keepOverlay = Settings.overlay.index
    Settings.overlay:sync("off")
    Settings.pt:sync("off")
    local before = GBCFX2.active()
    Settings.pt:sync("whites")
    T.eq(GBCFX2.active(), true,
      "GBC SCREEN alone makes the engine call present at level 0")
    Settings.pt:sync("off")
    T.eq(GBCFX2.active(), before,
      "and turning it off gives the engine's own answer back")
    Settings.overlay.index = keepOverlay
    GBCFX2.setLevel(keepLevel)
  end
end

-- ------- the glass: what the curve does to the shadow and the light
--
-- Two planes at different depths under one curved sheet is the whole content
-- of this. Warping BOTH by the same amount was the bug: everything bows, the
-- shadow never moves relative to its sprite, and it reads exactly as it did
-- before the curve was applied at all.
do
  local Overlay = V.require("Overlay")
  local src = Overlay.SHADER_SRC
  local function const(name)
    return tonumber(src:match("#define " .. name .. " ([%d%.]+)"))
  end

  local parallax = const("GLASS_PARALLAX")
  T.check(parallax and parallax > 0,
    "the shadow's plane is DEEPER than the picture's, or it cannot slide")
  local bow = const("REFLECT_BOW")
  T.check(bow and bow > 0 and bow < 1,
    "the front-surface reflection bows, but by less than the picture behind it")
  local slideMax = const("GLASS_SLIDE_MAX")
  T.check(slideMax and slideMax > 0,
    "the slide is capped as a fraction of the throw")
  -- The one that matters: the gyro must out-move the glass, or the shadow
  -- sits at a static curve-driven offset and the tilt is a wobble on top --
  -- which reads as the shadow not following the gyro at all. Reported from
  -- hardware after the cap was set to 3.0.
  T.check(slideMax < 1.0,
    ("the glass never displaces the shadow further than the gyro does "
     .. "(cap %s must stay under 1.0 x the throw)"):format(tostring(slideMax)))

  -- The behaviour that matters, checked as arithmetic rather than by eye:
  -- zero at the centre, growing outwards, then held.
  local function slide(x, k, throwPx, widthPx)
    local n = (x - 0.5) * 2
    local c = 0.5 + n * (1 + k * n * n) * 0.5
    local g = math.abs(c - x) * widthPx * parallax
    return math.min(g, throwPx * slideMax)
  end
  local K, THROW, W = 0.088, 1.45, 1024      -- RF CURVE HIGH, measured
  T.eq(slide(0.5, K, THROW, W), 0,
    "dead centre the glass deflects nothing, so the shadow does not slide")
  T.check(slide(0.8, K, THROW, W) > slide(0.65, K, THROW, W),
    "and the slide grows outwards, as the deflection does")
  T.check(slide(0.95, K, THROW, W) <= THROW * slideMax + 1e-9,
    "but never past the cap, so the shadow cannot detach from its sprite")
  T.eq(slide(0.5, 0, THROW, W), 0, "with no curve there is no slide at all")

  -- The curve's main contribution is a SWING, not a slide: rotation composes
  -- with the gyro instead of competing with it, so it can be large and still
  -- leave the tilt clearly dominant. Translation could not -- see the note on
  -- GLASS_SLIDE_MAX.
  local swing = const("GLASS_SWING")
  T.check(swing and swing > 0, "the glass swings the shadow's direction")
  local function lean(x, k)
    local n = (x - 0.5) * 2
    local c = 0.5 + n * (1 + k * n * n) * 0.5
    return math.abs((c - x) * swing)
  end
  T.eq(lean(0.5, K), 0, "dead centre you look straight through: no lean")
  T.check(lean(0.95, K) > lean(0.8, K) and lean(0.8, K) > lean(0.65, K),
    "and the lean grows towards the edges, as the viewing angle does")
  T.check(lean(0.95, K) > 0.3,
    ("the edge lean is worth seeing (%.2f rad at RF CURVE HIGH)"):format(
      lean(0.95, K)))
  T.eq(lean(0.95, 0), 0, "with no curve there is no lean at all")
end

-- ------- the pass chain, and what must stay on top
--
-- The user-facing promise is that the light is ALWAYS over the CRT passes.
-- That is a property of the order of three calls in one function, so read the
-- function and check the order rather than trusting a comment about it.
do
  local src = nil
  local f = io.open(MOD_PATH .. "/lib/GbcLight.lua", "r")
  if f then src = f:read("*a"); f:close() end
  T.check(src ~= nil, "GbcLight.lua is readable")
  local rf = src:find("RfTv\"%)%.apply")
  local beam = src:find("CrtBeam\"%)%.apply")
  local light = src:find("presentOverlay%(canvas")
  T.check(rf and beam and light, "all three stages are present in present()")
  T.check(rf < beam, "RF (the signal) runs before the tube")
  T.check(beam < light,
    "and both run before the light, which is the reflection off the front of "
    .. "the panel and must stay on top of everything")
end

-- ------- the SD-GYRO row must be findable, not merely present
--
-- The row was APPENDED for the whole of 0.1.x and 0.2.0, which was correct
-- while this was the only mod installed and wrong at ten: measured on a real
-- install it came out row 38 of 38, below `mods` and `controls`. OptionRows
-- draws FOUR rows at a time, so it sat nine pages down on both the title menu
-- and the in-game START -> OPTION menu, and was reported as missing from the
-- second. It was in both. Nobody could reach it in either.
--
-- Present-and-unreachable is the failure this asserts against, so "is the row
-- there" is not enough -- these check WHERE.
do
  local hooks = run.loader.hooks

  -- vanilla stands in for the engine's own buildRows: ids only, in the order
  -- OptionsMenu emits them, with the anchors this mod looks for.
  local function vanilla(_, rows) return rows end
  local function indexOf(rows, id)
    for i, r in ipairs(rows) do if r.id == id then return i end end
    return nil
  end
  local function callWith(list)
    local rows = {}
    for i, id in ipairs(list) do rows[i] = { id = id } end
    return hooks:call("ui.options.rows", vanilla, nil, rows)
  end

  -- 1. the engine's full display group. The row goes FIRST from 0.6.0 on:
  --    it is the front door to every setting the mod has and to the SENSOR
  --    readout, which is the one thing on this menu a player needs when
  --    nothing is happening.
  local out = callWith({ "colors", "gbcfx", "tilt", "zoom", "mods", "controls" })
  T.eq(indexOf(out, "DECK_TILT:gyro"), 1,
    "SD-GYRO is the first row on the OPTIONS menu")

  -- 2. DRAMATIC_SHAPE installed, which removes BOTH gbcfx and tilt. This is
  --    the arrangement on the author's own machine, so it is the case that
  --    actually ships. Nothing it removes can move the row now, which is the
  --    point of having dropped the anchors.
  out = callWith({ "textSpeed", "colors", "zoom", "videoMode", "mods", "controls" })
  T.eq(indexOf(out, "DECK_TILT:gyro"), 1,
    "still first with GBC FX and TILT gone -- no anchor left to lose")
  T.check(indexOf(out, "DECK_TILT:gyro") < indexOf(out, "mods"),
    "and above MODS/CONTROLS rather than below them, where it cannot be found")

  -- 3. a menu sharing not one id with the engine's -- a future engine
  --    renaming everything. The old version needed an anchor here and fell
  --    back to appending at the bottom; there is nothing left to find, so
  --    there is nothing left to fail.
  out = callWith({ "aaa", "bbb" })
  T.eq(indexOf(out, "DECK_TILT:gyro"), 1,
    "first even on a menu it recognises nothing in")

  -- 4. nothing else may be disturbed. The splice is an insert, so every row
  --    the engine and every other mod supplied must survive it, in order.
  local before = { "colors", "gbcfx", "zoom", "OTHER_MOD:row", "mods" }
  out = callWith(before)
  T.eq(#out, #before + 1, "exactly one row is added")
  local kept = {}
  for _, r in ipairs(out) do
    if r.id ~= "DECK_TILT:gyro" then kept[#kept + 1] = r.id end
  end
  T.eq(table.concat(kept, ","), table.concat(before, ","),
    "and every other row survives in its original order -- including another "
    .. "mod's")
end

-- ------- the tilting icon beside the row's name
--
-- It is the AXIS MAP's console at a reduced scale, not a second drawing of
-- one -- so what is worth asserting is that it stays THAT console, that it
-- still fits the strip the row leaves for it, and that the rock is even.
do
  local DeckIcon = V.require("DeckIcon")
  local DeckSprite = V.require("DeckSprite")

  local w, h = DeckIcon.size()
  T.check(w > 0 and h > 0, "the icon has a size derived from the sprite")
  -- 160px screen, and OptionRows draws its box to the full width. The icon
  -- starts after the label and must not run off the right-hand edge.
  T.check(DeckIcon.X + w <= 160,
    ("the icon fits the strip right of the label (ends at %.1f)"):format(
      DeckIcon.X + w))
  -- ...and must not collide with the label itself: `SD-GYRO` is 7 glyphs of
  -- 8px from x=16, so it ends at 72.
  T.check(DeckIcon.X >= 72, "and starts clear of the SD-GYRO label")
  -- ...and must keep a clear GAP on every side at its most tilted.
  --
  -- The bound is the rotated bounding box, not the diagonal: the diagonal is
  -- what a 90-degree turn would need, and this turns about 7 degrees, so
  -- using it rejects sizes that fit perfectly well. Measured against the
  -- same centre arithmetic the frame uses, not a restatement of it.
  local ca = math.abs(math.cos(DeckIcon.ANGLE))
  local sa = math.abs(math.sin(DeckIcon.ANGLE))
  local tiltH = h * ca + w * sa
  local tiltW = w * ca + h * sa
  local gap = DeckIcon.GAP

  -- slot 1: the box spans y = 0..32
  local cx, cy = DeckIcon.centreFor(1)
  T.check(cy - tiltH * 0.5 >= gap,
    ("a gap of at least %d above the tilted icon (%.2f)"):format(
      gap, cy - tiltH * 0.5))
  T.check(32 - (cy + tiltH * 0.5) >= gap,
    ("and below it (%.2f)"):format(32 - (cy + tiltH * 0.5)))
  -- `SD-GYRO` is 7 glyphs of 8px from x=16, so the label ends at 72
  T.check(cx - tiltW * 0.5 - 72 >= gap,
    ("and between it and the SD-GYRO label (%.2f)"):format(
      cx - tiltW * 0.5 - 72))
  T.check(160 - (cx + tiltW * 0.5) >= gap,
    ("and between it and the right edge of the screen (%.2f)"):format(
      160 - (cx + tiltW * 0.5)))

  -- The row is only marked when it is actually on screen -- a stale slot
  -- would draw the badge against whatever scrolled into that box next.
  DeckIcon.mark({ { id = "other" }, { id = "DECK_TILT:gyro" } }, 0)
  T.eq(DeckIcon.slot, 2, "the icon marks the slot its row is in")
  DeckIcon.mark({ { id = "other" } }, 0)
  T.eq(DeckIcon.slot, nil, "and marks nothing when the row is not visible")
  DeckIcon.mark(nil, 0)
  T.eq(DeckIcon.slot, nil, "and survives being handed no rows at all")

  -- It must be the SAME art as the AXIS MAP page, scaled -- not a copy that
  -- can drift. If DeckSprite's dimensions change, the icon's must follow.
  T.eq(w, DeckSprite.W * DeckIcon.SCALE,
    "the icon is DeckSprite's own width, scaled")
  T.eq(h, DeckSprite.H * DeckIcon.SCALE,
    "and its height -- one console in this mod, drawn at two sizes")
  -- Half scale loses the buttons to nearest sampling, which is the whole
  -- reason the console is recognisable. This is the floor that was measured.
  T.check(DeckIcon.SCALE > 0.5,
    "and is scaled above the point where nearest sampling eats the buttons")

  -- The rock passes THROUGH level rather than snapping between extremes.
  T.eq(#DeckIcon.CYCLE, 4, "the cycle is four steps")
  T.eq(DeckIcon.CYCLE[2], 0, "step 2 is level")
  T.eq(DeckIcon.CYCLE[4], 0, "and so is step 4 -- it rocks through the middle")
  T.eq(DeckIcon.CYCLE[1] + DeckIcon.CYCLE[3], 0,
    "and the two extremes are equal and opposite, so the tilt is even")

  -- Driven by the wall clock, because this is drawn from a DRAW hook and
  -- nothing guarantees it runs once per logic step.
  T.eq(DeckIcon.frameAt(0), 1, "the cycle starts on the first step")
  T.eq(DeckIcon.frameAt(DeckIcon.FRAME_TIME * 2.5), 3, "and advances with time")
  T.eq(DeckIcon.frameAt(DeckIcon.FRAME_TIME * 4), 1, "and wraps after four")
  T.eq(DeckIcon.frameAt(nil), 1, "a missing clock does not throw")
  T.eq(DeckIcon.angleAt(0), -DeckIcon.ANGLE, "step 1 tips one way")
  T.eq(DeckIcon.angleAt(DeckIcon.FRAME_TIME * 2), DeckIcon.ANGLE,
    "and step 3 tips the other")
end

run.release()

T.finish("DECK_TILT")
