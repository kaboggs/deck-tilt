-- LCD persistence: the smear a real Game Boy panel leaves behind moving art.
--
-- ------- what it is, and the one thing everyone gets backwards
--
-- A DMG/GBC panel is a twisted-nematic cell that is TRANSPARENT at rest and
-- goes dark when driven. Those two directions are not the same speed and not
-- the same mechanism:
--
--   going DARK   the cell is driven by an applied field -- fast
--   going LIGHT  the field is removed and the crystal relaxes elastically
--                back to rest -- slow
--
-- So the trail lives on the LIGHTENING side. It is BEHIND a sprite that has
-- moved on, not in front of the one arriving. Implemented symmetrically, or
-- with the two swapped, the result reads as input lag rather than as a panel
-- -- which is the note the the hardware model core leads with, and it is right.
--
-- ------- the numbers, and where they come from
--
-- The model, as a first-order relaxation:
--
--     state += (target - state) * (1 - exp(-dt / tau))
--
--     tauRise = 8 + 102 * 0.52 = 61.04 ms   (lightening, relaxation, slow)
--     tauFall = tauRise * 0.35 = 21.36 ms   (darkening, driven, fast)
--
-- The relaxation runs in TRANSMITTANCE space at gamma 2.2 rather than on the
-- stored sRGB values. That matters for mid-greys: a trail through the middle
-- of the range carries visibly the wrong weight if it is lerped on gamma-
-- encoded numbers, because equal steps there are not equal light.
--
-- A luminance gate (0.05) snaps small differences straight to the target, so
-- static content stays crisp instead of very slowly crawling toward itself
-- through floating-point noise. The hardware indexes a smoothstep LUT by the
-- squared length to avoid a square root; there is no reason to avoid one here.
--
-- ------- DEVIATION from the reference, stated plainly
--
-- A hardware model holds this state after its dot grid. This holds it BEFORE the mod's
-- own RF and CRT passes instead, for two reasons.
--
-- The first is ordering that the user asked for directly: the RF pass bows the
-- picture and the CRT pass lays a phosphor mask over it. A ghost computed
-- after those would be a ghost of a bent, masked image, and it would smear the
-- MASK -- which does not move and must not appear to. Held before them, the
-- trail is part of the picture, and the curve and the mask then happen to it
-- exactly as they happen to everything else. It bends with the screen because
-- it is on the screen rather than over it.
--
-- The second is memory: the state buffer is native 160x144 here rather than
-- the scaled output the hardware note says it could not afford at 4x.
--
-- ------- failure is a no-op
--
-- Every step is pcall'd and any fault switches the pass off for the rest of
-- the run, returning the frame untouched. This mod can stop working; it
-- cannot break a frame.

local V = ...

local Ghost = {}

local GB_W, GB_H = 160, 144

-- ------- the reference constants
Ghost.TAU_RISE_MS = 61.04 -- lightening: relaxation, slow, this is the trail
Ghost.TAU_FALL_MS = 21.36 -- darkening: driven, fast
Ghost.GAMMA = 2.2
Ghost.GATE = 0.05

-- How the strength row scales the trail. The row multiplies the LIGHTENING
-- time constant only: a longer relaxation is a longer trail, while the
-- darkening edge stays as sharp as the panel makes it. Scaling both would
-- soften the leading edge too, which is the input-lag look again.
local STRENGTH = {
  off    = 0,
  subtle = 0.5,
  normal = 1.0, -- the measured hardware value
  strong = 1.8,
  max    = 3.0,
}

local shader, failed = nil, false
local stateA, stateB   -- ping-pong: last frame's cell state, and this one's
local haveState = false

local SHADER_SRC = [[
extern Image ghostPrev;   // last frame's cell state
extern number ghostAlphaRise;  // lightening step, 0..1  (slow, the trail)
extern number ghostAlphaFall;  // darkening step, 0..1   (fast)
extern number ghostGamma;
extern number ghostGate;
extern number ghostHasPrev;

// Rec.601 luma, matching the gate the reference uses.
number lumaOf(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 sc) {
    vec4 src = Texel(tex, uv);
    if (ghostHasPrev < 0.5) { return src * color; }

    vec3 prev = Texel(ghostPrev, uv).rgb;

    // Relax in TRANSMITTANCE space, not on the stored values: equal steps on
    // a gamma-encoded number are not equal light, and a mid-grey trail comes
    // out the wrong weight if this is skipped.
    vec3 t  = pow(max(src.rgb, 0.0), vec3(ghostGamma));
    vec3 p  = pow(max(prev,     0.0), vec3(ghostGamma));

    vec3 d  = t - p;

    // Per channel, because the two directions are different mechanisms.
    //
    // THE SIGN. This is the one the reference leads with, so it is spelled
    // out rather than left to be re-derived:
    //
    //   d > 0  the pixel is getting LIGHTER on screen. The cell is passing
    //          more light, so it is LESS driven -- it is relaxing back to
    //          rest. Relaxation is the SLOW one: ghostAlphaRise.
    //   d < 0  the pixel is getting DARKER. The cell is being driven by an
    //          applied field, which is the FAST one: ghostAlphaFall.
    //
    // That is what puts the trail BEHIND a sprite that has left rather than
    // in front of one arriving. Swap these two and the panel reads as input
    // lag -- everything arrives smeared and nothing leaves one.
    vec3 a = vec3(
        d.r > 0.0 ? ghostAlphaRise : ghostAlphaFall,
        d.g > 0.0 ? ghostAlphaRise : ghostAlphaFall,
        d.b > 0.0 ? ghostAlphaRise : ghostAlphaFall
    );

    vec3 next = p + d * a;

    // Snap small differences so static content does not crawl.
    number gate = smoothstep(0.0, max(ghostGate, 1e-5), length(d));
    next = mix(t, next, gate);

    vec3 outc = pow(max(next, 0.0), vec3(1.0 / ghostGamma));
    return vec4(outc, src.a) * color;
}
]]
Ghost.SHADER_SRC = SHADER_SRC

-- alpha for one frame of a first-order relaxation, per the reference model.
-- dt is CLAMPED: the hardware is frame-locked at 16.742ms and has no jitter,
-- but this runs on real elapsed time, and one long frame (a load, a window
-- drag) would otherwise snap the whole buffer to the new picture and drop the
-- trail entirely.
Ghost.DT_MAX = 0.05

function Ghost.alphaFor(dtSeconds, tauMs)
  local dt = tonumber(dtSeconds) or 0
  if dt < 0 then dt = 0 end
  if dt > Ghost.DT_MAX then dt = Ghost.DT_MAX end
  local tau = (tonumber(tauMs) or 0) / 1000
  if tau <= 0 then return 1 end
  return 1 - math.exp(-dt / tau)
end

-- The lightening time constant the strength row asks for, in ms. nil when the
-- row is OFF, which is how callers know to skip the pass entirely.
function Ghost.tauRiseMs()
  local ok, Settings = pcall(function() return V.require("Settings") end)
  if not ok or not Settings or not Settings.ghost then return nil end
  local mult = STRENGTH[Settings.ghost:get()] or 0
  if mult <= 0 then return nil end
  return Ghost.TAU_RISE_MS * mult
end

function Ghost.enabled() return Ghost.tauRiseMs() ~= nil end

Ghost.STRENGTH = STRENGTH

-- ------- the pass
local function ensure(w, h)
  if shader == nil then
    if not (love and love.graphics and love.graphics.newShader) then
      return false
    end
    local ok, made = pcall(love.graphics.newShader, SHADER_SRC)
    if not ok or not made then failed = true return false end
    shader = made
  end
  -- BOTH dimensions. Checking only the width would reuse a wrong-sized pair
  -- after a resize that changed the height alone -- a letterbox change does
  -- exactly that.
  if not stateA or stateA:getWidth() ~= w or stateA:getHeight() ~= h then
    local okA, a = pcall(love.graphics.newCanvas, w, h)
    local okB, b = pcall(love.graphics.newCanvas, w, h)
    if not (okA and okB and a and b) then failed = true return false end
    stateA, stateB, haveState = a, b, false
  end
  return true
end

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

function Ghost.wanted()
  if fxOff() then return false end
  return Ghost.enabled()
end

-- Run the persistence over `canvas`, returning the canvas to draw onward.
-- Returns nil when the pass is off or unavailable, meaning "use the original",
-- which is the same contract RfTv and CrtBeam hand back so the chain in
-- GbcLight.present needs no branch.
--
-- `pixelScale` is accepted and unused: the state buffer is the canvas's own
-- size, whatever that is. It is in the signature so this pass is swappable
-- with the others in the chain rather than being the one that reads
-- differently.
function Ghost.apply(canvas, pixelScale, dt)
  dt = dt or (love and love.timer and love.timer.getDelta
              and love.timer.getDelta()) or 0
  if failed or not canvas then return nil end
  local tau = Ghost.tauRiseMs()
  if not tau then
    haveState = false -- a fresh trail next time it is switched on
    return nil
  end

  local okDim, w, h = pcall(canvas.getDimensions, canvas)
  if not okDim or not w then return nil end
  if not ensure(w, h) then return nil end

  local gate = Ghost.GATE
  do
    local okS, Settings = pcall(function() return V.require("Settings") end)
    if okS and Settings and Settings.ghostGate then
      local okG, g = pcall(Settings.ghostGate)
      if okG and type(g) == "number" then gate = g end
    end
  end

  local aRise = Ghost.alphaFor(dt, tau)
  local aFall = Ghost.alphaFor(dt, tau * (Ghost.TAU_FALL_MS / Ghost.TAU_RISE_MS))

  local g = love.graphics
  local prevCanvas = g.getCanvas()
  local okRun = pcall(function()
    g.setCanvas(stateB)
    g.clear(0, 0, 0, 0)
    shader:send("ghostPrev", stateA)
    shader:send("ghostAlphaRise", aRise)
    shader:send("ghostAlphaFall", aFall)
    shader:send("ghostGamma", Ghost.GAMMA)
    shader:send("ghostGate", gate)
    shader:send("ghostHasPrev", haveState and 1 or 0)
    g.setShader(shader)
    g.setColor(1, 1, 1, 1)
    g.draw(canvas, 0, 0)
    g.setShader()
  end)
  pcall(g.setCanvas, prevCanvas)

  if not okRun then
    failed = true
    return nil
  end

  stateA, stateB = stateB, stateA -- the result becomes next frame's state
  haveState = true
  return stateA
end

-- Drop the trail: used when the picture cuts rather than moves, so a battle
-- transition does not drag the overworld into the first frame of the fight.
function Ghost.reset() haveState = false end

function Ghost.status()
  if failed then return "OFF" end
  return Ghost.enabled() and "ON" or "OFF"
end

return Ghost
