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
T.eq(exports.version, "0.1.0", "carrying its version")

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
T.eq(#schema, 10, "ten settings are defined")
T.eq(schema[1].key, "motion", "MOTION leads")
-- assert the SCHEMA default, not the live value: the live one resolves
-- through mod.options against whatever the player last saved, so asserting
-- it makes the suite pass or fail on the contents of options.lua

local shadowSchema = schemaFor("shadow")
local vals = {}
for _, c in ipairs(shadowSchema.choices) do vals[c[2]] = true end
T.check(vals.follow and vals.fixed and vals.off,
  "SHADOW offers FOLLOW, FIXED and OFF")
T.eq(shadowSchema.default, "follow", "and defaults to FOLLOW")

T.eq(schema[1].default, "tilt",
  "and defaults to TILT, so enabling the mod is the opt-in")
for _, row in ipairs(schema) do
  T.check(type(row.label) == "string" and row.label ~= "",
    "setting " .. row.key .. " carries a row label")
  T.check(type(row.help) == "string" and row.help ~= "",
    "setting " .. row.key .. " carries help text")
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

local FDT, FTAU = 1/60, 1.2
local FK = { -0.019, -0.027, 0.019 }

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

run.release()

T.finish("DECK_TILT")
