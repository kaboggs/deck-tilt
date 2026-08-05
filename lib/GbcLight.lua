-- Taking over the GBC FX light, without touching an engine file.
--
-- src/render/GBCFX.lua computes its light position inside the shader, from
-- the `time` uniform:
--
--     vec2 lightPos = vec2(0.5 + 0.35 * sin(time * 0.13),
--                          0.3  + 0.2  * sin(time * 0.07));
--
-- There is no uniform to aim at, so there is nothing to send.  What there
-- is, is GBCFX.SHADER_SRC -- the module exports its own GLSL, for the
-- standalone compile check.  So: read the engine's source, rewrite that one
-- statement into a uniform read, compile the result as OUR shader, and
-- replace GBCFX.present with a version that sends it.  The engine's files
-- are never written to, which is the whole point: update.sh rsyncs --delete
-- over game/ and would revert an edit, but it excludes /mods/ and only ever
-- rewrites the mod directory it owns.  A sibling mod survives both.
--
-- The rewrite is one substitution, anchored on the statement rather than
-- its text, and everything downstream of it is guarded: if a future engine
-- spells that line differently the substitution simply misses, the mod
-- reports why on its status row, and rendering falls through to the stock
-- present untouched.  The failure mode is losing the feature, never the
-- frame.
--
-- GBCFX.shader() is deliberately NOT overridden.  GBCFX.active() calls it
-- and the renderer gates on that, so leaving it alone keeps the engine's
-- own accounting exactly as it was; the cost is one unused compiled shader.

local V = ...
local Motion = V.require("Motion")
local Settings = V.require("Settings")

local GbcLight = {}

local GBCFX = require("src.render.GBCFX")
local stockPresent = GBCFX.present

local shader          -- our patched shader; false once we have given up
local hasShadow = false -- whether the optional shadow-offset rewrite landed
local hasAmount = false -- whether the optional shadow-strength rewrite landed
local failure         -- why, for the status row
local installed = false

-- The rewrite itself, kept pure and separate from the compile so a headless
-- test can hold it against the engine's real shader source.  That test is
-- the tripwire for the mod's one genuine assumption about engine internals:
-- if an update rephrases the lightPos statement, this stops matching, and a
-- failing test is a much better way to find that out than a Deck that
-- quietly stopped tilting.
--
-- Returns the patched source, or nil plus a short reason.
-- The shadow offset, rewritten so the drop shadow falls away from wherever
-- the light actually is.
--
-- Stock, the offset is a constant (3,3) at level 3, and at level 4 it picks
-- up a +-3 pixel drift around that constant.  Because the drift is smaller
-- than the base it never changes sign: the shadow under text and sprites
-- always falls down and to the right, whatever the light is doing.  Against
-- a canned drift that is invisible.  Against a tilt-driven light it is
-- plainly wrong -- you can put the light below the text and watch the
-- shadow keep falling downwards, which reads as two light sources.
--
-- The offset is computed in Lua and arrives as a uniform, so the GLSL side is
-- a plain read and the geometry can be unit-tested.  Two earlier attempts
-- lived in the shader and both failed in ways a test would have caught:
--
--   1. stock base PLUS a light-driven term.  That keeps the engine's +3
--      down-right bias, so the offset ran +7.5 px one way and -1.5 px the
--      other.  It inverted on paper; on screen the left-hand shadow never
--      cleared the sprite it belonged to, so it was simply never seen.
--
--   2. a symmetric LINEAR swing.  Equal both ways, but it scaled with
--      distance from centre and peaked at +-5.4 px -- nearly double the
--      engine's constant -- so shadows ballooned under text.  Worse, being
--      linear it passes through ZERO at centre, which is exactly where the
--      light rests, so the shadow faded out during normal play.
--
-- What the shadow actually needs is CONSTANT LENGTH and a rotating
-- direction: always far enough to clear the sprite, never longer than the
-- engine's own, and the same distance left as right.
local SHADOW_EXPR = "vec2 shOff = deckShadowOff;"

-- A second, independent rewrite for the shadow's STRENGTH.
--
-- Separate from the offset because the offset cannot express absence: an
-- offset of zero still darkens the backing under the sprite, so a row
-- labelled OFF that only zeroed the offset left a visible shadow -- which is
-- exactly what it did, and exactly what a player noticed.  Scaling the term
-- the shader already computes is the only way OFF can mean off.
--
-- Optional in the same way the offset rewrite is: if it misses, the strength
-- stays the engine's and the row falls back to FOLLOW/FIXED, which is a
-- smaller loss than the whole mod.
local AMOUNT_EXPR =
  "float shadow = dark * smoothstep(0.08, 0.30, dark) * SHADOW_OPACITY * deckShadowAmt;"

-- Returns patched source, or nil plus a short reason.  Third return says
-- whether the optional shadow rewrite also landed -- the light is the point
-- of this mod and must not be lost just because the shadow moved.
function GbcLight.patchSource(src)
  if type(src) ~= "string" then return nil, "NO SRC" end
  -- [^;]* cannot overrun: the statement ends at the first semicolon, and
  -- the expression it replaces contains none.  Matching the statement, not
  -- the literal text, means reformatting upstream does not break this.
  local patched, hits =
    src:gsub("vec2%s+lightPos%s*=[^;]*;", "vec2 lightPos = deckLight;", 1)
  if hits ~= 1 then return nil, "NO HOOK" end

  local withShadow, shadowHits =
    patched:gsub("vec2%s+shOff%s*=[^;]*;", SHADOW_EXPR, 1)
  local hasShadow = shadowHits == 1
  if hasShadow then patched = withShadow end

  local withAmt, amtHits =
    patched:gsub("float%s+shadow%s*=[^;]*;", AMOUNT_EXPR, 1)
  local hasAmount = amtHits == 1
  if hasAmount then patched = withAmt end

  local header = "extern vec2 deckLight;\n"
  if hasShadow then header = header .. "extern vec2 deckShadowOff;\n" end
  if hasAmount then header = header .. "extern float deckShadowAmt;\n" end
  return header .. patched, nil, hasShadow, hasAmount
end

-- The engine's own SHADOW_OFFSET #define, mirrored so this stays in the units
-- the rest of that shader was tuned in.
local SHADOW_BASE = 3.0

-- Length of the throw, held CONSTANT in every direction.  Only a shade longer
-- than the engine's own 3 px: the point is that the shadow clears the sprite
-- on the left exactly as far as it already did on the right, not that it
-- becomes more prominent.
local SHADOW_LEN = SHADOW_BASE * 1.15

-- A small downward lean, applied to the DIRECTION before it is normalised
-- rather than added to the result.  Added afterwards it would bias the length
-- and reintroduce the left/right asymmetry; folded into the direction it only
-- decides which way the shadow points when the light is near the middle
-- (straight down, as the engine does), and costs nothing at the extremes.
-- Also decides where the direction PIVOTS: at 0.5 + this.  It has to sit
-- clear of the light's rest point, or the softening below eats the shadow
-- exactly where the light spends most of its time -- at 0.15 the shadow was
-- only 2.35px of its 3.45 at rest.  0.25 puts the pivot at y=0.75, which is
-- still inside the light's travel so the shadow can invert, but far enough
-- from rest to keep full length there.
local DOWN_LEAN = 0.25

-- How close to the pivot the throw starts shrinking.
--
-- Without this the direction flips 180 degrees the instant the light crosses
-- the pivot, at full length -- simulated at a 6.90px jump in a single frame,
-- which is twice the shadow's own length, so it teleports across itself.
-- Worse, a light resting near that line jitters: hand tremor of +-0.01 threw
-- the shadow 3.48px back and forth every frame.
--
-- Fading the length to nothing across the pivot makes the flip happen while
-- there is nothing to see.  Simulated at 0.22 the worst frame-to-frame jump
-- is 0.01px and tremor spread is 0.17px -- both below one pixel, so neither
-- is visible.  Larger values keep shrinking the numbers but widen the patch
-- of screen where the shadow is short, and past ~0.3 the gain is negligible.
local SOFT = 0.22

-- Screen-space light position -> drop-shadow offset, in GB pixels.
-- `enabled` false returns the engine's own constant, so the row genuinely
-- restores stock rather than approximating it.
-- mode is "follow" | "fixed" | "off"
function GbcLight.shadowOffset(lx, ly, mode)
  if mode ~= "follow" then return SHADOW_BASE, SHADOW_BASE end
  local dx = 0.5 - (lx or 0.5)
  local dy = 0.5 - (ly or 0.5) + DOWN_LEAN
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return 0, 0 end
  -- full length everywhere except close to the pivot, where it eases to
  -- nothing so the direction reversal is not visible
  local scale = SHADOW_LEN * math.min(1, len / SOFT)
  return dx / len * scale, dy / len * scale
end

local function build()
  if shader ~= nil then return shader end

  if not (love and love.graphics and love.graphics.newShader) then
    return nil -- headless: try again later rather than failing for good
  end

  local patched, why, gotShadow, gotAmount = GbcLight.patchSource(GBCFX.SHADER_SRC)
  if not patched then
    shader, failure = false, why
    return false
  end
  hasShadow, hasAmount = gotShadow, gotAmount

  local ok, result = pcall(love.graphics.newShader, patched)
  if not ok or not result then
    shader, failure = false, "COMPILE"
    return false
  end
  shader = result
  return shader
end

-- The replacement present.  Mirrors GBCFX.present's uniform sends exactly,
-- plus the light, and hands straight back to the original whenever we are
-- not driving -- so with MOTION off, GBC FX off, or no IMU, what gets drawn
-- is the engine's own output, not an imitation of it.
local function present(canvas, pixelScale)
  -- ---- the TV/RF pass goes UNDER everything below ----
  --
  -- Physical order, and it is the reason this line is first rather than last:
  -- the RF artefacts are in the SIGNAL, the panel displays that signal, and
  -- the glare is a reflection off the front of the panel. So RF runs into its
  -- own buffer here and every path below -- ours and the engine's own -- then
  -- draws over the result.
  --
  -- Unconditional because RfTv.apply hands back the canvas it was given
  -- whenever the pass is off or anything failed, so there is no branch to get
  -- wrong and stockPresent below receives a drawable canvas either way.
  -- The chain, outermost last: SIGNAL -> TUBE -> the panel you look at.
  -- RF is what arrives at the set, CrtBeam is the glass it is painted onto,
  -- and this mod's own glare, shimmer and drop shadow are the reflection off
  -- the front -- so they stay on top of both, always. Adding a pass means
  -- adding a line here and nowhere else.
  local source = canvas
  canvas = V.require("RfTv").apply(canvas, pixelScale) or canvas
  canvas = V.require("CrtBeam").apply(canvas, pixelScale) or canvas
  local rfDrew = (canvas ~= source)

  -- GBC FX off, but the overlay wants the frame: draw the light on our own
  -- pass instead of handing back.  Checked BEFORE build(), because build()
  -- patches the ENGINE's shader and that is not the shader this path uses.
  if (GBCFX.level or 0) <= 0 then
    if GbcLight.overlayWanted() then
      -- `source` is the frame before RF and CRT touched it. The overlay casts
      -- its drop shadow from that rather than from the processed picture, so
      -- the shadow keeps following the GYRO instead of following the
      -- scanlines. See the shadow block in Overlay.lua.
      return GbcLight.presentOverlay(canvas, pixelScale, source)
    end
    -- TV/RF on, with no light wanted over it.  We cannot hand this to
    -- stockPresent: the engine's present is written for a level it does not
    -- have here, and active() is only answering true because WE asked it to
    -- for this pass.  So draw the buffer plainly -- the RF pass has already
    -- done all the work, and this is just getting it to the screen.
    if rfDrew then
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.draw(canvas, 0, 0)
      return
    end
    return stockPresent(canvas, pixelScale)
  end
  local sh = build()
  if not sh then
    return stockPresent(canvas, pixelScale)
  end

  local dt = (love.timer and love.timer.getDelta and love.timer.getDelta()) or 0
  local lx, ly = Motion.light(dt)
  if not lx then return stockPresent(canvas, pixelScale) end

  local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  sh:send("level", GBCFX.level)
  sh:send("time", t)
  sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
  -- The one send that can fail: a driver that optimised the uniform away
  -- would throw here.  One strike and we are stock for the rest of the run.
  local ok = pcall(sh.send, sh, "deckLight", { lx, ly })
  if ok and hasShadow then
    -- only sent when the rewrite actually landed; the uniform does not
    -- exist otherwise and send() throws on an unknown name
    local mode = Settings.shadow:get()
    local ox, oy = GbcLight.shadowOffset(lx, ly, mode)
    ok = pcall(sh.send, sh, "deckShadowOff", { ox, oy })
    GbcLight.shadowX, GbcLight.shadowY = ox, oy
    if ok and hasAmount then
      GbcLight.shadowAmt = (mode == "off") and 0 or 1
      ok = pcall(sh.send, sh, "deckShadowAmt", GbcLight.shadowAmt)
    end
  end
  if not ok then
    shader, failure = false, "NO UNIF"
    return stockPresent(canvas, pixelScale)
  end

  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas, 0, 0)
  love.graphics.setShader()

  -- Proof the patched pass actually ran, rather than something upstream
  -- quietly handing back to stock. Tests assert on it; nothing else reads it.
  GbcLight.frames = (GbcLight.frames or 0) + 1
  GbcLight.lightX, GbcLight.lightY = lx, ly
end

-- Is another mod holding GBC FX off, and do we mean to draw anyway?
--
-- AUTO deliberately does NOT ask which mod is responsible.  Any mod may pin
-- the level, and a list of names here would be wrong the moment a new one
-- appeared -- so the question asked is the one that matters: is the light
-- gone.  ON is the same answer without the condition, for a player who wants
-- the overlay over a plain frame too.
function GbcLight.overlayWanted()
  if Settings.motion:get() == "off" then return false end
  local mode = Settings.overlay:get()
  if mode == "off" then return false end
  if mode == "on" then return true end
  return (GBCFX.level or 0) <= 0        -- auto
end

-- SUBTLE is not a smaller number picked by feel: at 1.0 the bands are the
-- engine's own strength, which is calibrated for a backing-blended frame and
-- is visibly too much here.  See Overlay's SHIMMER_CHROMA_GAIN.
-- Multipliers on the overlay's base unit.  FULL = 3.0 is the engine's own
-- SHIMMER_CHROMA_GAIN, so FULL means "as strong as GBC FX" and the values
-- below it are genuinely weaker rather than a guess.  MAX goes past it,
-- because a full screen spreads what a 160x144 panel concentrated.
local SHIMMER = { off = 0, subtle = 0.8, normal = 1.8, full = 3.0, max = 5.0 }
local GLARE   = { off = 0, low = 0.7, normal = 1.0, high = 2.2, max = 4.0 }

function GbcLight.shimmerAmount()
  return SHIMMER[Settings.shimmer:get()] or SHIMMER.normal
end

function GbcLight.glareAmount()
  return GLARE[Settings.glare:get()] or GLARE.high
end

-- Our own pass, over whatever the engine composed -- including another mod's
-- 3D render.  Nothing here reads or writes options.gbcfx, so a mod that pins
-- that value has nothing to fight: it keeps its zero and we never ask for it.
-- `clean` is the frame as it was before the TV/RF and CRT passes ran, when
-- either of them did. Optional: called without it (as the tests do, and as an
-- older caller would) the shadow falls back to reading the frame it is drawing
-- over, which is exactly right when nothing ran ahead of it.
function GbcLight.presentOverlay(canvas, pixelScale, clean)
  local Overlay = V.require("Overlay")
  local sh = Overlay.shader()
  if not sh then return stockPresent(canvas, pixelScale) end

  local dt = (love.timer and love.timer.getDelta and love.timer.getDelta()) or 0
  local lx, ly = Motion.light(dt)
  if not lx then return stockPresent(canvas, pixelScale) end

  local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local mode = Settings.shadow:get()
  local ox, oy = GbcLight.shadowOffset(lx, ly, mode)
  local ok = pcall(function()
    sh:send("time", t)
    sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
    sh:send("deckLight", { lx, ly })
    sh:send("deckShadowOff", { ox, oy })
    sh:send("deckShadowAmt", (mode == "off") and 0 or 1)
    sh:send("deckGlare", GbcLight.glareAmount())
    sh:send("deckShimmer", GbcLight.shimmerAmount())
    -- Only a DIFFERENT canvas counts as a clean frame. When nothing ran ahead
    -- of us `clean` is the very canvas being drawn, and sampling that as a
    -- second texture is both pointless and, on some drivers, a read of the
    -- active render source -- so the flag stays 0 and the shader reads `tex`.
    local hasClean = (clean ~= nil and clean ~= canvas)
    sh:send("deckHasClean", hasClean and 1 or 0)
    sh:send("deckClean", hasClean and clean or canvas)
    -- the same barrel the picture is bent by, so the shadow lies under the
    -- same glass and swings with it instead of sitting flat on top
    sh:send("deckCurve", hasClean and V.require("RfTv").barrelK() or 0)
  end)
  if not ok then return stockPresent(canvas, pixelScale) end

  love.graphics.setShader(sh)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(canvas, 0, 0)
  love.graphics.setShader()

  GbcLight.overlayFrames = (GbcLight.overlayFrames or 0) + 1
  GbcLight.shadowX, GbcLight.shadowY = ox, oy
  GbcLight.lightX, GbcLight.lightY = lx, ly
end

function GbcLight.install()
  if installed then return end
  installed = true
  GBCFX.present = present
  -- The engine only calls present() when GBCFX.active() is true, and that is
  -- false at level 0 -- which is exactly the condition the overlay exists
  -- for.  So active() has to answer for the overlay as well, or the pass it
  -- gates is never reached.  Stock answer otherwise, untouched.
  local stockActive = GBCFX.active
  GBCFX.active = function(...)
    if (GBCFX.level or 0) <= 0 then
      if GbcLight.overlayWanted() then return true end
      -- ...and the same for TV/RF, which is a whole pass of its own and has
      -- nothing to do with the light or the sensor.  Without this the row
      -- would set a value that never reached a frame -- a setting you can
      -- select that then does nothing, which is worse than no setting.
      local okRf, Rf = pcall(V.require, "RfTv")
      if okRf and Rf and Rf.wanted() then return true end
      local okB, Beam = pcall(V.require, "CrtBeam")
      if okB and Beam and Beam.wanted() then return true end
    end
    return stockActive(...)
  end
end

-- What the mod's status row shows.  Our own trouble outranks the IMU's:
-- a shader we could not patch is the thing to fix first.
function GbcLight.status()
  local Imu = V.require("Imu")
  if Settings.motion:get() == "off" then return "OFF" end
  if (GBCFX.level or 0) <= 0 then
    -- "GBCFX OFF" is only the whole story when nothing is drawing.  With the
    -- overlay running the mod IS working, and saying otherwise sends someone
    -- to fix a setting that is not the problem.
    if GbcLight.overlayWanted() then
      local Overlay = V.require("Overlay")
      return Overlay.status() or Imu.status
    end
    return "GBCFX OFF"
  end
  if shader == false then return failure or "ERROR" end
  return Imu.status
end

return GbcLight
