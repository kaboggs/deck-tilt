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

-- Published so the SHADOW AMT row's NORMAL rung can mean exactly this number
-- rather than a copy of it that stops agreeing the moment either is touched.
GbcLight.SHADOW_STOCK_LEN = SHADOW_LEN

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
--
-- `lenPx` is the throw the SHADOW AMT row asks for, defaulting to the stock
-- 3.45. It is a PARAMETER rather than a read of the setting so this stays a
-- pure function of its inputs and the test suite can walk the whole ladder
-- without touching stored options.
--
-- The softening near the pivot is a fraction of the throw rather than a fixed
-- number of pixels, so it scales with it: the worst frame-to-frame jump was
-- measured at 0.01px on the stock length, which is 0.08px at the longest rung
-- and still well under the one pixel that would make the reversal visible.
function GbcLight.shadowOffset(lx, ly, mode, lenPx)
  local L = lenPx or SHADOW_LEN
  -- FIXED is the engine's own down-right constant, scaled by the same ratio,
  -- so the row still lengthens a shadow that has been told not to move.
  if mode ~= "follow" then
    local k = L / SHADOW_LEN
    return SHADOW_BASE * k, SHADOW_BASE * k
  end
  local dx = 0.5 - (lx or 0.5)
  local dy = 0.5 - (ly or 0.5) + DOWN_LEAN
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1e-6 then return 0, 0 end
  -- full length everywhere except close to the pivot, where it eases to
  -- nothing so the direction reversal is not visible
  local scale = L * math.min(1, len / SOFT)
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
  -- The light, computed ONCE for the whole frame, at the top.  It used to be
  -- computed inside whichever branch drew it, which was correct while only
  -- one branch per frame read it -- but the panel pass below reads it too,
  -- and Motion.light(dt) ADVANCES the filters, so a second call in the same
  -- frame would run the smoothing at twice its tuned rate.  nil here means
  -- Motion declined (MOTION off, or no sensor), and every consumer below
  -- already has a stock answer for that.
  local dt = (love.timer and love.timer.getDelta and love.timer.getDelta()) or 0
  local lx, ly = Motion.light(dt)

  -- ---- the passes UNDER everything below ----
  --
  -- Physical order, and it is the reason these lines are first rather than
  -- last.  The chain, outermost last: PANEL -> SIGNAL -> TUBE -> the glass
  -- you look at.  The GBC panel pass is what the picture IS -- its plate,
  -- grain, shadows and rainbow are part of the image a camera would record,
  -- so the RF curve and the CRT mask must happen TO them (a panel drawn
  -- after the curve is a flat sticker on bowed glass, the same failure
  -- drawSwatches exists to avoid).  RF is that picture as a signal arriving
  -- at the set, CrtBeam is the tube it is painted onto, and this mod's own
  -- glare, shimmer and drop shadow are the reflection off the front -- so
  -- they stay on top of everything, always.  Adding a pass means adding a
  -- line here and nowhere else.
  --
  -- Unconditional because every apply() hands back the canvas it was given
  -- whenever its pass is off or anything failed, so there is no branch to
  -- get wrong and stockPresent below receives a drawable canvas either way.
  -- ------- the SCREEN FX master
  --
  -- One row gates every picture pass, at the point they run rather than by
  -- changing their settings -- so switching it back on restores exactly what
  -- was configured. The tilt light below is deliberately outside this: it is
  -- the mod, not an effect over the picture, and MOTION is its master.
  local fx = true
  do
    local okS, S = pcall(function() return V.require("Settings") end)
    if okS and S and S.screenFxOn then
      local okV, on = pcall(S.screenFxOn)
      if okV then fx = on end
    end
  end

  local pre = canvas
  -- `source` is the frame the overlay's drop shadow is cast from: AFTER the
  -- panel passes (the shadow should fall over the plate you can actually
  -- see) and BEFORE the RF and CRT passes (whose scan structure would fake
  -- occluders -- see the shadow block in Overlay.lua). Initialised to the
  -- incoming frame so it is still valid with SCREEN FX off.
  local source = canvas
  if fx then
    canvas = V.require("PixelTrans").apply(canvas, pixelScale, lx, ly) or canvas
    -- The panel's own physics -- crosstalk, the cell shadow, its colour and
    -- its dead lines -- sit with the panel and before the tube, for the same
    -- reason the GBC pass does: they are part of the picture a camera would
    -- record, so the curve and the mask must happen TO them.
    canvas = V.require("DmgPanel").apply(canvas, pixelScale, lx, ly) or canvas
    -- LCD persistence sits with the PANEL and not with the tube: it is the
    -- liquid crystal relaxing, so it belongs to the picture the panel makes,
    -- and the RF curve and CRT mask must then happen TO the trail. Held
    -- after the curve it would smear the MASK, which does not move and must
    -- never appear to. (the hardware model holds its state after its own dot grid; the
    -- note in lib/Ghost says why this deviates.)
    canvas = V.require("Ghost").apply(canvas, pixelScale) or canvas
    source = canvas
    canvas = V.require("RfTv").apply(canvas, pixelScale) or canvas
    canvas = V.require("CrtBeam").apply(canvas, pixelScale) or canvas
  end
  -- measured against `pre`, not `source`: a frame only the panel pass drew
  -- still has to reach the screen by the plain-draw path below
  local drew = (canvas ~= pre)

  -- GBC FX off, but the overlay wants the frame: draw the light on our own
  -- pass instead of handing back.  Checked BEFORE build(), because build()
  -- patches the ENGINE's shader and that is not the shader this path uses.
  if (GBCFX.level or 0) <= 0 then
    if GbcLight.overlayWanted() then
      -- `source` is the frame before RF and CRT touched it. The overlay casts
      -- its drop shadow from that rather than from the processed picture, so
      -- the shadow keeps following the GYRO instead of following the
      -- scanlines. See the shadow block in Overlay.lua.
      return GbcLight.presentOverlay(canvas, pixelScale, source, lx, ly)
    end
    -- A pass drew, with no light wanted over it.  We cannot hand this to
    -- stockPresent: the engine's present is written for a level it does not
    -- have here, and active() is only answering true because WE asked it to
    -- for this pass.  So draw the buffer plainly -- the passes have already
    -- done all the work, and this is just getting it to the screen.
    if drew then
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
    local ox, oy = GbcLight.shadowOffset(lx, ly, mode,
                                         Settings.shadowLenPx(SHADOW_LEN))
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

-- ------- the colour of the glare
--
-- The glare is a reflection off the FRONT of the glass, and a reflection is
-- the colour of whatever is being reflected. On a real handheld that is the
-- room -- a tungsten bulb, a window, a screen -- and it is almost never the
-- neutral white this always added.
--
-- Two families here, and they are different claims. WARM through COOL are
-- light SOURCES a console is realistically held under. AMBER through PINK are
-- not: they are a choice, for a player who wants the highlight to read as a
-- colour rather than as a room.
--
-- Stored at full saturation and normalised to unit LUMA before it reaches the
-- shader, so moving down this row changes the hue of the highlight and not
-- its strength. Without that, BLUE would land visibly dimmer than AMBER for
-- the same GLARE rung and the two rows would fight each other.
GbcLight.GLARETINT = {
  white  = { 1.00, 1.00, 1.00 },
  warm   = { 1.00, 0.86, 0.68 }, -- tungsten, the usual indoor reflection
  cool   = { 0.78, 0.88, 1.00 }, -- daylight through a window
  amber  = { 1.00, 0.72, 0.32 },
  gold   = { 1.00, 0.84, 0.42 },
  green  = { 0.62, 1.00, 0.66 },
  blue   = { 0.55, 0.74, 1.00 },
  violet = { 0.80, 0.66, 1.00 },
  pink   = { 1.00, 0.70, 0.85 },
}

-- Rec. 601 luma, the same weighting the rest of this shader family uses.
local function unitLuma(c)
  local y = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
  if y <= 1e-4 then return 1, 1, 1 end
  return c[1] / y, c[2] / y, c[3] / y
end

function GbcLight.glareTint()
  local c = GbcLight.GLARETINT[Settings.glaretint:get()]
        or GbcLight.GLARETINT.white
  return unitLuma(c)
end

-- Our own pass, over whatever the engine composed -- including another mod's
-- 3D render.  Nothing here reads or writes options.gbcfx, so a mod that pins
-- that value has nothing to fight: it keeps its zero and we never ask for it.
-- `clean` is the frame as it was before the TV/RF and CRT passes ran, when
-- either of them did. Optional: called without it (as the tests do, and as an
-- older caller would) the shadow falls back to reading the frame it is drawing
-- over, which is exactly right when nothing ran ahead of it.
-- `lx, ly` is the light position present() already computed this frame.
-- Optional for the same reason `clean` is; but when present() supplies it,
-- reading the sensor again here would advance Motion's filters a second time
-- in one frame, so an older caller falls back and a current one must not.
function GbcLight.presentOverlay(canvas, pixelScale, clean, lx, ly)
  local Overlay = V.require("Overlay")
  local sh = Overlay.shader()
  if not sh then return stockPresent(canvas, pixelScale) end

  if not lx then
    local dt = (love.timer and love.timer.getDelta and love.timer.getDelta()) or 0
    lx, ly = Motion.light(dt)
  end
  if not lx then return stockPresent(canvas, pixelScale) end

  local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local mode = Settings.shadow:get()
  local ox, oy = GbcLight.shadowOffset(lx, ly, mode,
                                       Settings.shadowLenPx(SHADOW_LEN))
  local ok = pcall(function()
    sh:send("time", t)
    sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
    sh:send("deckLight", { lx, ly })
    sh:send("deckShadowOff", { ox, oy })
    sh:send("deckShadowAmt", (mode == "off") and 0 or 1)
    sh:send("deckGlare", GbcLight.glareAmount())
    sh:send("deckShimmer", GbcLight.shimmerAmount())
    local tr, tg, tb = GbcLight.glareTint()
    sh:send("deckGlareTint", { tr, tg, tb })
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

-- ------- the colour swatches, and why they are drawn from HERE
--
-- GLOW COLOUR is the one row on this mod's page that cannot be drawn by the
-- page. The SD-GYRO menu draws into the engine's 160x144 Game Boy
-- framebuffer, and that frame then goes through PaletteFX, which remaps the
-- four DMG SHADES to a palette. Anything drawn with the rest of the page is
-- therefore a shade and not a colour -- a swatch strip drawn there would
-- arrive as four greys, which is worse than no swatches at all, because it
-- would look like the colours were broken rather than absent.
--
-- So the strip is drawn where this mod's own light is drawn: after present,
-- over the finished picture, in real RGB. It is still in the canvas's
-- 160x144 coordinates, because the engine's transform is still current at
-- this point -- so it lands exactly beside its row and scales with the
-- window without knowing anything about either.
--
-- GyroMenu publishes the request on CrtBeam (a module both sides already
-- hold) rather than being required from here, which would be a cycle. It is
-- cleared as it is consumed, so the strip cannot outlive the page that asked
-- for it by even one frame.
-- Sizes are in GAME BOY pixels -- 160x144 -- and scaled up on the way out.
-- The strip sits right of the value text, which at eight pixels a glyph runs
-- to about x=72 for the longest label here.
-- Sized to the LONGEST palette on any row, not to the first one written.
--
-- The strip starts after the value text and must end inside the 160px screen,
-- so the arithmetic that matters is SWATCH_X + n*(SWATCH_W+1) <= 160. At the
-- original 7px from x=88 that allowed nine, and GLOW COLOUR now offers
-- fifteen -- the strip ran 48px off the side of the screen, invisible in
-- source and obvious on hardware, which is the same failure mode as the
-- SELECT hint that overran once already.
--
-- 5px from x=82 gives (160-82)/6 = 13... so 4px at pitch 5 from x=80 fits
-- sixteen with two to spare. The value labels on the rows that carry a strip
-- are at most six glyphs ("VIOLET"), ending at 24+48 = 72, so 80 clears them.
local SWATCH_W, SWATCH_H, SWATCH_X = 4, 6, 80
local SWATCH_PITCH = 5
-- published so the test suite can assert the strip fits rather than eyeball it
GbcLight.SWATCH_W, GbcLight.SWATCH_X = SWATCH_W, SWATCH_X
GbcLight.SWATCH_PITCH = SWATCH_PITCH
local GB_W, GB_H = 160, 144

-- Drawn INTO the canvas on its way in, not over the finished frame.
--
-- Over the top was the obvious place and it was wrong twice. The canvas that
-- reaches present is already the size of the WINDOW, not 160x144, so drawing
-- in menu coordinates put the strip in the corner of the screen at a
-- seventh of its intended size. And even scaled correctly it would sit flat
-- on a picture that the RF pass then bows away underneath it, so the strip
-- would drift off its own row towards the edges of the glass.
--
-- Going in early fixes both at once and costs nothing: the swatches become
-- part of the picture, so the curve, the mask and the scanlines all happen
-- TO them. They bend with their row because they are on the same glass,
-- which is also just what a strip of colours on a menu would look like on a
-- television.
local function drawSwatches(canvas, pixelScale)
  local okB, CrtBeam = pcall(V.require, "CrtBeam")
  if not okB or not CrtBeam then return end
  local req = CrtBeam.swatchStrip
  CrtBeam.swatchStrip = nil
  if not req or not req.values or not canvas then return end

  local ok, w, h = pcall(canvas.getDimensions, canvas)
  if not ok or not w then return end
  local ps = math.max(1, math.floor(tonumber(pixelScale) or 1))
  -- The game's picture is centred in the canvas with the letterbox either
  -- side, so the offset is derived from the two rather than assumed to be
  -- zero. Derived, because it changes with the window and this must not need
  -- editing when it does.
  local offX = (w - GB_W * ps) * 0.5
  local offY = (h - GB_H * ps) * 0.5

  -- the value line of the row's box, in OptionRows' own geometry: four boxes
  -- of four 8px tiles, label on the second tile, value on the third
  local y = ((req.slot - 1) * 4 + 2) * 8
  local g = love.graphics
  local prev = g.getCanvas()
  local okDraw = pcall(function()
    g.setCanvas(canvas)
    for i, name in ipairs(req.values) do
      local x = SWATCH_X + (i - 1) * SWATCH_PITCH
      -- a black frame, because WHITE against the menu's light background is
      -- otherwise an invisible swatch in the middle of the strip
      g.setColor(0, 0, 0, 1)
      g.rectangle("fill", offX + (x - 1) * ps, offY + (y - 1) * ps,
                  (SWATCH_W + 2) * ps, (SWATCH_H + 2) * ps)
      -- The palette comes WITH the request, so a second row of colours does
      -- not have to be a second copy of this function. GLOW COLOUR omits it
      -- and gets the tube palette it always had.
      local palette = req.palette or CrtBeam.GLOWCOL
      local c = palette[name] or { 1, 1, 1 }
      -- Scaled so the brightest channel is full, NOT normalised by luma the
      -- way the shader does it. The shader is answering "how much light does
      -- this add", which must not change with hue; a swatch is answering
      -- "which colour is this", which wants the most saturated honest
      -- version of it. Same numbers, two different questions.
      local m = math.max(c[1], c[2], c[3], 1e-3)
      g.setColor(c[1] / m, c[2] / m, c[3] / m, 1)
      g.rectangle("fill", offX + x * ps, offY + y * ps,
                  SWATCH_W * ps, SWATCH_H * ps)
      if i == req.index then
        g.setColor(0, 0, 0, 1)
        g.rectangle("fill", offX + (x - 1) * ps,
                    offY + (y + SWATCH_H + 2) * ps,
                    (SWATCH_W + 2) * ps, 2 * ps)
      end
    end
  end)
  g.setColor(1, 1, 1, 1)
  pcall(g.setCanvas, prev)
  if not okDraw then CrtBeam.swatchStrip = nil end
end

function GbcLight.install()
  if installed then return end
  installed = true
  -- Wrapped rather than assigned straight through, so the swatch strip is
  -- drawn on EVERY path through present -- stock, overlay, patched shader
  -- and all the failure returns. A strip that only appeared when the light
  -- happened to be running would be a row that shows its colours on some
  -- settings and not others.
  --
  -- BEFORE present, not after: the strip has to be in the picture before the
  -- RF and CRT passes read it, or it is a flat sticker on a curved screen.
  -- Renderer ignores present's return value (Renderer.lua calls it as a
  -- statement), so nothing is lost by not passing one back.
  GBCFX.present = function(canvas, pixelScale)
    pcall(drawSwatches, canvas, pixelScale)
    present(canvas, pixelScale)
  end
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
      -- ...and the GBC panel pass, which is a frame pass in exactly the way
      -- TV/RF is: without this its rows would set values that never reach a
      -- frame while GBC FX is held off, which is precisely the situation
      -- (the 3D mod) the pass is most likely to be used in.
      -- ...and all of it is behind the SCREEN FX master, so with that off
      -- none of these rows claim the pass.
      local okFx, S = pcall(function() return V.require("Settings") end)
      local fxOn = true
      if okFx and S and S.screenFxOn then
        local okV, on = pcall(S.screenFxOn)
        if okV then fxOn = on end
      end
      if not fxOn then return stockActive(...) end
      local okP, Pt = pcall(V.require, "PixelTrans")
      if okP and Pt and Pt.wanted() then return true end
      local okG, Gh = pcall(V.require, "Ghost")
      if okG and Gh and Gh.wanted() then return true end
      local okD, Dp = pcall(V.require, "DmgPanel")
      if okD and Dp and Dp.wanted() then return true end
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
