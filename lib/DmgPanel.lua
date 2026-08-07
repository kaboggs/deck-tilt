-- The DMG panel itself: crosstalk, the cell's two-layer shadow, the panel's
-- own colour trim, and dead electrode lines.
--
-- Ported from a hardware model of the panel. Everything here is a property of a passive-matrix reflective LCD
-- rather than of the picture, which is why it is one pass: they share the
-- same neighbourhood reads and the order between them is load-bearing.
--
-- ------- 1. crosstalk, and why it is the DMG look
--
-- A passive matrix has no transistor per cell. A driven column pulls on every
-- cell it passes, so a dark block drags a visible smear through its own
-- column -- and that smear is what makes a Game Boy screen look like a Game
-- Boy screen more than the green does.
--
-- It is ASYMMETRIC. From the reference: "a dark block bleeds down strongly
-- and up weakly (0.4x), which is what makes it read as crosstalk surrounding
-- dark content rather than a second copy of the drop shadow."
--
-- Their FPGA port could not finish it -- a top-to-bottom raster cannot see
-- the rows below, so the upward field needs a bottom-to-top pre-pass during
-- blanking, and their README still lists the weak upward bleed as pending.
-- A fragment shader has the whole frame addressable, so both directions come
-- out for free. This is the one place our medium is easier than theirs.
--
-- The hardware accumulates d^2 through an IIR, exp(-1/12) down the rows and
-- exp(-1/8) across them. A shader has no running state, so the same decay is
-- summed explicitly over a finite tap window -- exp(-12/12) is 0.37 and
-- exp(-24/12) is 0.14, so twelve taps carry the great majority of it and the
-- tail is not worth the samples.
--
-- ------- 2. the cell's shadow has TWO layers
--
-- The element plane sits above the reflector with an air gap, so each dark
-- cell throws a shadow onto the sheet behind it. One blur cannot express
-- that; the reference thresholds the caster twice, "a sharp near umbra and a
-- broad, weaker penumbra", at 1.35 and 3.24 dots.
--
-- Those two distances are the whole trick and they are easy to get wrong. The
-- reference records its own miss: an earlier revision "used adjacent cells
-- for both layers, which put the shadow one dot from its caster instead of
-- 1.35 and 3.24, and made it fade about three times too fast."
--
-- The direction is this mod's own light, so the gap parallaxes as the console
-- tilts -- which is the entire premise of the mod applied to a real feature
-- of the panel rather than to a decoration.
--
-- ------- 3. the panel's colour trim
--
-- A DMG does not show its palette cleanly. Measured constants, applied in the
-- reference's order (bleed -> offTint -> crosstalk -> gamma -> saturation ->
-- warm -> contrast -> brightness -> blackLift), and the order IS the model:
-- "moving any of them changes what the panel looks like."
--
-- The one worth naming is blackLift. A reflective panel has no black to
-- reach: the darkest thing on it is still the reflector seen through a fully
-- driven cell, so 0.10 of lift is not a stylistic choice, it is the floor.
--
-- ------- 4. dead electrode lines
--
-- And the detail nearly every emulator gets backwards: real dead lines are
-- WHITE. "A ribbon or heat-seal bond failure floats a whole electrode, so its
-- LC relaxes to the un-driven state: on a normally-white reflective panel
-- that is the light reflector." Only about six per cent settle dark, from
-- leakage bias on the floating electrode.
--
-- They also clump -- the flex is lap-bonded along one edge and a lap joint
-- peels from the ends of its overlap -- so they arrive as contiguous bands
-- concentrated near an edge, never evenly scattered.
--
-- ------- failure is a no-op
--
-- Every step is pcall'd; any fault switches the pass off for the run and
-- hands back the frame untouched.

local V = ...

local DmgPanel = {}

-- ------- measured constants
DmgPanel.XTALK        = 0.34 * 0.5  -- crosstalk x density
DmgPanel.XTALK_UP     = 0.4         -- the weak upward bleed
DmgPanel.XTALK_CLAMP  = 0.65        -- darken clamp
DmgPanel.DECAY_V      = 1 / 12      -- exp(-1/12) per row
DmgPanel.DECAY_H      = 1 / 8       -- exp(-1/8) per pixel
DmgPanel.TAPS         = 12

DmgPanel.UMBRA_DOTS   = 1.35
DmgPanel.PENUMBRA_DOTS= 3.24
DmgPanel.SHADOW_OP    = 0.34
DmgPanel.SHADOW_COL   = { 0.397, 0.391, 0.222 }

DmgPanel.BLEED        = 0.16
DmgPanel.OFFTINT      = 0.10 * 0.5
DmgPanel.SATURATION   = 0.85
DmgPanel.WARM         = { 0.06 * 0.5, 0.06 * 0.15, 0.06 * -0.4 }
DmgPanel.CONTRAST     = 0.88
DmgPanel.BRIGHTNESS   = 0.88
DmgPanel.BLACKLIFT    = 0.10
DmgPanel.DEADLINE_LIT = 0.06        -- fraction of dead lines that settle DARK

local AMOUNT = { off = 0, low = 0.5, normal = 1.0, high = 1.6 }
local DEAD   = { off = 0, few = 0.12, some = 0.35, many = 1.0 }
-- how completely a failed line has failed: an intermittent bond still
-- passes some drive, so a partial line is as real as a total one
local DEADAMT = { faint = 0.35, half = 0.65, full = 1.0 }

local SHADER_SRC = [[
extern vec2  dmgTexel;      // one GB dot, in texture coords
extern number dmgXtalk;     // crosstalk strength, 0 = off
extern number dmgShadow;    // cell shadow strength, 0 = off
extern number dmgTrim;      // panel colour trim, 0 = off
// Room light, as a multiple of the reference level. A reflective panel makes
// no light of its own -- everything you see is the room, gone through the LC
// and back off the reflector -- so this scales the whole picture rather than
// being a brightness dial on top of it.
extern number dmgRoom;
extern number dmgDead;      // dead-line severity, 0 = none
extern number dmgDeadAmt;   // how completely a dead line has failed
extern number dmgSeed;
extern vec2  dmgLightDir;   // unit vector the shadow is thrown along
// Where the GAME PICTURE sits inside the canvas, in uv. The canvas is the
// window and the picture is letterboxed inside it -- measured on hardware,
// 800x720 of game inside a 1024x722 canvas, so 112px of dead space each side.
// Anything indexed by COLUMN has to be measured against the picture, not the
// canvas, or it counts the letterbox as screen.
extern vec2  dmgOrigin;
extern vec2  dmgSpan;

const int TAPS = 12;

number lum(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

number hash11(number p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    return fract(p * (p + p));
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec3 src = Texel(tex, uv).rgb;
    vec3 col = src;

    // ---- 1. crosstalk ------------------------------------------------------
    // Content ABOVE bleeds down onto us strongly; content BELOW bleeds up at
    // 0.4x. Accumulated as d^2, matching the hardware's IIR.
    if (dmgXtalk > 0.0) {
        number down = 0.0, up = 0.0, side = 0.0;
        for (int i = 1; i <= TAPS; i++) {
            number fi = number(i);
            number wv = exp(-fi / 12.0);
            number wh = exp(-fi / 8.0);

            number dA = 1.0 - lum(Texel(tex, uv - vec2(0.0, dmgTexel.y * fi)).rgb);
            number dB = 1.0 - lum(Texel(tex, uv + vec2(0.0, dmgTexel.y * fi)).rgb);
            number dL = 1.0 - lum(Texel(tex, uv - vec2(dmgTexel.x * fi, 0.0)).rgb);

            down += wv * dA * dA;
            up   += wv * dB * dB;
            side += wh * dL * dL;
        }
        // normalise by the weight sum so the strength dial means the same
        // thing whatever the tap count is
        number wsum = 0.0;
        for (int i = 1; i <= TAPS; i++) { wsum += exp(-number(i) / 12.0); }
        number field = (down + up * 0.4) / max(wsum, 1e-4)
                     + side * 0.22 / max(wsum, 1e-4);

        number darken = min(field * 0.17 * dmgXtalk, 0.65);
        col *= (1.0 - darken);
    }

    // ---- 2. the cell's two-layer shadow ------------------------------------
    // Sampled TOWARD the light, at 1.35 and 3.24 dots: a sharp near umbra and
    // a broad weak penumbra. One blur cannot express the air gap.
    if (dmgShadow > 0.0) {
        vec2 d = dmgLightDir * dmgTexel;
        number near = 1.0 - lum(Texel(tex, uv + d * 1.35).rgb);
        number far  = 1.0 - lum(Texel(tex, uv + d * 3.24).rgb);
        number self = 1.0 - lum(src);
        // a pixel dark in its own right does not show a shadow on top of it
        number amt = (near * 0.65 + far * 0.35) * (1.0 - self);
        amt *= 0.34 * dmgShadow;
        col = mix(col, vec3(0.397, 0.391, 0.222), clamp(amt, 0.0, 1.0));
    }

    // ---- 4. dead electrode lines -------------------------------------------
    // VERTICAL, because the DMG's heat-seal ribbon runs along one edge and a
    // failed column driver is the famous Game Boy line.
    //
    // Overwhelmingly WHITE: a floating electrode relaxes to the un-driven
    // state, which on a normally-white reflective panel is the reflector.
    // Only about six per cent settle dark, from leakage bias.
    //
    // A lap joint peels from the ENDS of its overlap, so failures concentrate
    // at both ends of the bonded edge and thin out in the middle -- and a
    // coarse clump term makes them arrive in contiguous groups rather than
    // evenly scattered, which is what a real panel does.
    //
    // The first version of this block produced ZERO lines at every severity:
    // it needed risk > 0.94 from a distribution that essentially never gets
    // there, and its edge term collapsed to nothing away from one sliver of
    // the screen. The counts are modelled now rather than assumed -- see the
    // dead-line test, which walks all 160 columns and asserts the spread.
    if (dmgDead > 0.0) {
        // Picture space, NOT canvas space.
        //
        // This was the bug that made the seed look like it did nothing. The
        // column index ran across the whole canvas (0..204 at the measured
        // 1024x722), so it did not line up with GB dots -- and the edge bias,
        // which deliberately concentrates failures at the two ends of the
        // bonded ribbon, was concentrating them in the LETTERBOX. Most of
        // every seed's lines were generated where nothing is drawn, leaving
        // only the sparse middle few on screen, and those barely differ from
        // one seed to the next.
        vec2 pic = (uv - dmgOrigin) / max(dmgSpan, vec2(1e-6));
        if (pic.x >= 0.0 && pic.x <= 1.0 && pic.y >= 0.0 && pic.y <= 1.0) {
            number colIdx = floor(pic.x * 160.0);
            number h      = hash11(colIdx * 1.7 + dmgSeed);
            number clump  = hash11(floor(colIdx / 6.0) * 3.3 + dmgSeed * 2.0);
            number ends   = pow(clamp(abs(pic.x - 0.5) * 2.0, 0.0, 1.0), 1.5);
            number bias   = mix(0.45, 1.9, ends) * (0.35 + 1.65 * clump);
            if (h < 0.055 * dmgDead * bias) {
                number lit = hash11(colIdx * 7.3 + dmgSeed * 11.0);
                vec3 dead = (lit < 0.06) ? vec3(0.13, 0.16, 0.10)
                                         : vec3(0.93, 0.91, 0.75);
                col = mix(col, dead, clamp(dmgDeadAmt, 0.0, 1.0));
            }
        }
    }

    // ---- 3. the panel's own colour trim ------------------------------------
    // In the reference's order. blackLift last, because a reflective panel
    // has no black to reach.
    if (dmgTrim > 0.0) {
        number k = dmgTrim;
        number l = lum(col);
        col = mix(col, vec3(l), 0.15 * k);                       // saturation 0.85
        col += vec3(0.03, 0.009, -0.024) * k;                    // warm
        col = (col - 0.5) * mix(1.0, 0.88, k) + 0.5;             // contrast
        col *= mix(1.0, 0.88, k);                                // brightness
        col = col * (1.0 - 0.10 * k) + 0.10 * k;                 // blackLift

        // ---- and finally, how much light there is to reflect ---------------
        // Last, because it is not part of the panel's response -- it is how
        // much light arrives at it. A dim room does not change the contrast
        // curve of the LC, it just gives it less to work with. Applied after
        // blackLift so the lifted floor dims with everything else, which is
        // what makes a Game Boy in a dark room murky rather than merely dark.
        col *= dmgRoom;
    }

    return vec4(clamp(col, 0.0, 1.0), 1.0) * color;
}
]]
DmgPanel.SHADER_SRC = SHADER_SRC

local shader, failed = nil, false

local function setting(key)
  local ok, S = pcall(function() return V.require("Settings") end)
  if not ok or not S or not S[key] then return nil end
  local okV, v = pcall(function() return S[key]:get() end)
  return okV and v or nil
end

function DmgPanel.xtalk()  return AMOUNT[setting("dmgxtalk")  or "off"] or 0 end
function DmgPanel.shadow() return AMOUNT[setting("dmgshadow") or "off"] or 0 end
function DmgPanel.trim()   return (setting("dmgtrim") == "on") and 1 or 0 end

-- The room's light level, as a multiplier. 1.0 when the trim is off, because
-- the trim is the row that models the panel answering to light -- without it
-- there is nothing here for the room to act on, and dimming the picture from
-- a row on another page would be a surprise.
function DmgPanel.room()
  if DmgPanel.trim() == 0 then return 1.0 end
  local ok, S = pcall(function() return V.require("Settings") end)
  if not ok or not S or not S.roomLightScale then return 1.0 end
  local okV, v = pcall(S.roomLightScale)
  return (okV and type(v) == "number") and v or 1.0
end
function DmgPanel.dead()   return DEAD[setting("dmgdead") or "off"] or 0 end
function DmgPanel.deadAmt()
  return DEADAMT[setting("dmgdeadamt") or "full"] or 1.0
end
DmgPanel.DEAD, DmgPanel.DEADAMT = DEAD, DEADAMT

-- Every picture pass answers `false` here while the SCREEN FX master row is
-- off. The gate lives in wanted() rather than only in the chain that calls
-- apply(), so there is ONE answer to "does this pass run" and a caller
-- reaching for a pass directly cannot slip past the master.
local function fxOff()
  local ok, S = pcall(function() return V.require("Settings") end)
  if not ok or not S or not S.screenFxOn then return false end
  local okV, on = pcall(S.screenFxOn)
  return okV and not on
end

function DmgPanel.wanted()
  if fxOff() then return false end
  return DmgPanel.xtalk() > 0 or DmgPanel.shadow() > 0
      or DmgPanel.trim() > 0 or DmgPanel.dead() > 0
end

function DmgPanel.apply(canvas, pixelScale, lx, ly)
  if failed or not canvas or not DmgPanel.wanted() then return nil end
  if not (love and love.graphics and love.graphics.newShader) then return nil end
  if shader == nil then
    local ok, made = pcall(love.graphics.newShader, SHADER_SRC)
    if not ok or not made then failed = true return nil end
    shader = made
  end

  local okDim, w, h = pcall(canvas.getDimensions, canvas)
  if not okDim or not w then return nil end
  local ps = math.max(1, math.floor(tonumber(pixelScale) or 1))

  -- the shadow is thrown AWAY from the light, in this mod's own light
  -- direction, so the air gap parallaxes as the console tilts
  local dx, dy = 0.55, 0.83
  if lx and ly then
    local vx, vy = 0.5 - lx, 0.5 - ly + 0.25
    local len = math.sqrt(vx * vx + vy * vy)
    if len > 1e-4 then dx, dy = vx / len, vy / len end
  end

  local out = love.graphics.newCanvas(w, h)
  local prev = love.graphics.getCanvas()
  local okRun = pcall(function()
    love.graphics.setCanvas(out)
    love.graphics.clear(0, 0, 0, 0)
    shader:send("dmgTexel", { ps / w, ps / h })
    shader:send("dmgXtalk", DmgPanel.xtalk())
    shader:send("dmgShadow", DmgPanel.shadow())
    shader:send("dmgTrim", DmgPanel.trim())
    shader:send("dmgRoom", DmgPanel.room())
    shader:send("dmgDead", DmgPanel.dead())
    shader:send("dmgDeadAmt", DmgPanel.deadAmt())
    local seed = 17.0
    do
      local okS, S = pcall(function() return V.require("Settings") end)
      if okS and S and S.deadSeed then
        local okD, v = pcall(S.deadSeed)
        if okD and type(v) == "number" then seed = v end
      end
    end
    shader:send("dmgSeed", seed)
    shader:send("dmgLightDir", { dx, dy })
    -- the picture's rectangle inside the canvas, derived the same way
    -- GbcLight.drawSwatches derives it rather than assumed to be the whole
    -- canvas -- it is not, and assuming so is what broke the dead lines
    local GB_W, GB_H = 160, 144
    local offX = (w - GB_W * ps) * 0.5
    local offY = (h - GB_H * ps) * 0.5
    shader:send("dmgOrigin", { offX / w, offY / h })
    shader:send("dmgSpan", { GB_W * ps / w, GB_H * ps / h })
    love.graphics.setShader(shader)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0)
    love.graphics.setShader()
  end)
  pcall(love.graphics.setCanvas, prev)
  if not okRun then failed = true return nil end
  return out
end

function DmgPanel.status()
  if failed then return "ERROR" end
  return DmgPanel.wanted() and "ON" or "OFF"
end

return DmgPanel
