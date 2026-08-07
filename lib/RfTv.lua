-- The TV/RF pass: what the picture looks like after it has been through a
-- composite video signal and a CRT.
--
-- ------- what this is a reimplementation OF
--
-- `github.com/GOROman/famicom-rf-hackrf-decoder` (MIT, (c) GOROman), which
-- receives a real Famicom's VHF output with an SDR and decodes NTSC in
-- software.  A copy sits in the project at `reference/famicom-rf-hackrf-
-- decoder/`; nothing links against it and nothing here is copied from it.
-- What is taken is its DSP chain and its constants, both of which are written
-- down there as working code measured against real hardware.
--
-- That distinction is the whole point of doing it this way.  A CRT shader
-- written from screenshots reproduces the LOOK of composite video.  This
-- reproduces the CAUSE: dot crawl, cross-colour and chroma smear are not
-- drawn here, they FALL OUT of encoding the frame to a composite signal and
-- decoding it back with a real Y/C split.  Nothing below draws a rainbow.
--
-- ------- the chain, and where each piece comes from
--
--   reference                              here
--   ---------------------------------------------------------------------
--   kFsc = 315e6/88 = 3.579545 MHz         CYCLES_PER_PX, derived below
--   52.6 us active line                    "
--   burst phase per line (chroma.hpp)      LINE_PHASE, the 180 deg flip
--   y = ire_frac(p) - chroma_frac(p)       Y = lowpass(composite)
--     (ntsc_decoder.cpp:325)                 -- same thing: composite minus
--                                            its own 3.58 MHz band IS its
--                                            lowpass, to first order
--   su = 2*c*sin(th), sv = 2*c*cos(th)     the demod loop, verbatim in form
--     then a per-line UV LPF                 then a wider UV tap window
--   r = y + 1.140v                         RGB, same matrix
--   g = y - 0.395u - 0.581v
--   b = y + 2.032u
--   apply_crt: k1 = 0.055, odd row * 0.72, BARREL_K1, SCAN_FLOOR, VIGNETTE
--     vig = 1 - 0.18*r2*r2 (sdl_display)
--
-- ------- the one number that had to be decided rather than copied
--
-- The reference decodes a real signal, so it knows how many samples it has
-- per subcarrier cycle.  A 160x144 Game Boy frame is not a signal and has no
-- line structure at all, so the question "how many colour cycles fit across
-- one GB pixel" has no measured answer and has to be constructed.  It is
-- constructed from the reference's own two constants and nothing else:
--
--   52.6 us active line x 3.579545 MHz  = 188.28 subcarrier cycles per line
--   188.28 cycles / 160 GB pixels       = 1.1768 cycles per GB pixel
--
-- so one colour cycle is about 0.85 of a GB pixel.  Every artefact's SCALE
-- follows from that number: make it larger and the dots get finer, smaller
-- and they coarsen into stripes.  It is the first thing to change if this
-- ever looks wrong, and it is a derivation rather than a measurement -- which
-- this mod's own history says is exactly the kind of number to distrust (the
-- gyro scale was confidently 4.9x wrong, with the wrong sign, for a while).
--
-- ------- where it sits in the frame
--
-- UNDER this mod's own light.  The order is physical and it is not arbitrary:
-- the RF artefacts are in the SIGNAL, the panel displays that signal, and the
-- glare is a reflection off the front of the panel you are looking at.  So
-- this pass runs first, into a buffer, and GbcLight draws its glare, shimmer
-- and drop shadow over the result -- see GbcLight.present / presentOverlay,
-- both of which call RfTv.apply on the way in.

local V = ...
local Settings = V.require("Settings")

local RfTv = {}

local SHADER_SRC = [[
extern number time;
extern number pixelScale;
extern number rfStrength;   // master, 0 = off
extern number rfDots;       // Y/C leakage -> dot crawl
extern number rfColour;     // chroma gain -> cross-colour, smear
extern number rfChroma;     // chroma BANDWIDTH -> how far colour smears
extern number rfTint;       // subcarrier phase error, in radians
extern number rfScan;       // scanline depth
extern number rfCurve;      // barrel + vignette
extern number rfNoise;      // RF snow

#define PI 3.14159265359

// 52.6us active line * 3.579545MHz / 160 GB pixels.  See the note in RfTv.lua
// -- this is the number every artefact's scale hangs off.
#define CYCLES_PER_PX 1.1768
// NTSC flips the burst 180 degrees line to line.  This is what makes the
// chroma error alternate vertically, and it is the whole reason dot crawl is
// a moving checkerboard rather than a static tint.
#define LINE_PHASE 0.5
// ...and the field alternation, which is what makes it CRAWL rather than sit
// still.  Stepped off the clock at the field rate rather than the frame rate
// the game happens to be running at, so it does not change speed with fps.
#define FIELD_HZ 59.94
// Taps either side of the pixel, at TAP_STEP GB pixels apart.  9 taps at 0.25
// spans 2.0 GB pixels ~= 2.35 subcarrier cycles, which is enough to average
// the subcarrier out of the luma.  Fewer and the subcarrier survives into Y
// as a standing stripe pattern rather than as dots.
#define TAPS 4
#define TAP_STEP 0.25
// The UV filter is deliberately WIDER than the luma one.  That asymmetry is
// not a performance shortcut -- it is why colour smears sideways past a hard
// edge while the edge itself stays sharp, which is the single most
// recognisable composite artefact there is.
//
// It is the BASE of the width now rather than the width itself: RF CHROMA
// scales it, because how far colour runs past an edge is a property of the
// SET (its chroma bandwidth) and not of the standard.  A studio monitor
// decoding the same signal keeps colour much tighter than a portable does,
// and that difference is the single biggest reason two CRTs fed the same
// tape do not look alike.  NTSC allotted about 1.3MHz to I and 0.5MHz to Q
// against luma's 4.2; a cheap set threw both away down to a few hundred kHz.
#define UV_WIDEN 2.0

#define BARREL_K1 0.055     // sdl_display.cpp CrtLut
#define VIGNETTE 0.18       // vig = 1.0 - 0.18 * r2 * r2
#define SCAN_FLOOR 0.72     // odd lines * 0.72

float hash21(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// BT.601, the inverse of the reference's own output matrix
vec3 rgb2yuv(vec3 c)
{
    float y = dot(c, vec3(0.299, 0.587, 0.114));
    return vec3(y, 0.492 * (c.b - y), 0.877 * (c.r - y));
}

vec3 yuv2rgb(vec3 yuv)
{
    return vec3(yuv.x + 1.140 * yuv.z,
                yuv.x - 0.395 * yuv.y - 0.581 * yuv.z,
                yuv.x + 2.032 * yuv.y);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 pc)
{
    if (rfStrength <= 0.0) return Texel(tex, tc) * color;

    float ps = max(pixelScale, 1.0);

    // ---- 1. the tube: barrel distortion, before anything is sampled ----
    // A coordinate remap has to come first or every artefact below would be
    // computed on the flat picture and then bent, which puts the scanlines in
    // the wrong place -- they belong to the tube, not to the signal.
    vec2 uv = tc;
    float r2 = 0.0;
    if (rfCurve > 0.0) {
        vec2 n = (tc - 0.5) * 2.0;
        r2 = dot(n, n);
        float f = 1.0 + BARREL_K1 * rfCurve * r2;
        uv = 0.5 + n * f * 0.5;
        // outside the tube.  Black, not clamped: a clamped edge smears the
        // border pixel outward into a skirt, which reads as a bad upscale
        // rather than as the edge of a screen.
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
            return vec4(0.0, 0.0, 0.0, 1.0) * color;
    } else {
        vec2 n = (tc - 0.5) * 2.0;
        r2 = dot(n, n);
    }

    vec2 gbPix = (uv * love_ScreenSize.xy) / ps;
    vec2 texelPerGb = ps / love_ScreenSize.xy;

    // The subcarrier angle at a given GB-pixel column on this line.  The line
    // and field terms are what turn a static chroma error into crawling dots.
    float field = floor(time * FIELD_HZ);
    float linePh = LINE_PHASE * (floor(gbPix.y) + field);

    // ---- 2. encode to composite, and decode it back ----
    // Both halves run in the same loop over the same taps, because they are
    // the same samples: encode(x) is evaluated at each tap and immediately
    // accumulated into the three decoded outputs.
    float ySum = 0.0, uSum = 0.0, vSum = 0.0;
    float yW = 0.0, uvW = 0.0;

    // How wide the chroma average is, in taps. Clamped above 0.25 rather than
    // allowed to reach zero: at zero every UV weight is zero, uvW is zero, and
    // the divide below falls back on its epsilon and produces whatever the
    // last tap happened to be. NARROW is meant to be a tight decoder, not an
    // undefined one.
    float uvWide = max(UV_WIDEN * rfChroma, 0.25);

    for (int i = -TAPS; i <= TAPS; i++) {
        float off = float(i) * TAP_STEP;
        vec2 stc = uv + vec2(off * texelPerGb.x, 0.0);
        vec3 yuv = rgb2yuv(Texel(tex, stc).rgb);

        // encode: composite = Y + U*sin(th) + V*cos(th), the reference's own
        // convention (it demods with sin for U and cos for V)
        float th = 2.0 * PI * (CYCLES_PER_PX * (gbPix.x + off) + linePh);
        float s = sin(th), c = cos(th);
        float comp = yuv.x + (yuv.y * s + yuv.z * c) * rfColour;

        // luma: a plain lowpass across the taps.  The reference writes this
        // as composite MINUS its 3.58MHz bandpass; averaging over whole
        // subcarrier cycles is the same statement.  Whatever subcarrier
        // survives this average IS the dot crawl, which is why rfDots scales
        // the chroma that gets encoded rather than adding a pattern.
        float wy = 1.0 - abs(off) / (float(TAPS) * TAP_STEP + TAP_STEP);
        ySum += comp * wy;
        yW += wy;

        // chroma: demod against the same angle PLUS whatever error the set's
        // reference oscillator is carrying, then a wider average.  Luma
        // detail sitting near the subcarrier frequency demods into U/V here
        // and comes out as colour that was never in the source -- cross
        // colour, for free, because we did not special-case it.
        //
        // rfTint is that error, and it is the whole of "Never The Same
        // Color": NTSC sends hue as the PHASE of the subcarrier, so a
        // receiver whose reference is a few degrees out of step decodes every
        // hue rotated by those degrees.  It is a receiver fault rather than a
        // signal one, which is why it is demodulated in and not encoded in --
        // encoding it would mean the picture really was that colour, and a
        // second set would then agree with the first, which is the one thing
        // NTSC never did.
        float thd = th + rfTint;
        float sd = sin(thd), cd = cos(thd);
        float wuv = 1.0 - abs(off) / (float(TAPS) * TAP_STEP * uvWide);
        wuv = max(wuv, 0.0);
        uSum += 2.0 * comp * sd * wuv;
        vSum += 2.0 * comp * cd * wuv;
        uvW += wuv;
    }

    float Y = ySum / max(yW, 1e-5);
    float U = uSum / max(uvW, 1e-5);
    float Vv = vSum / max(uvW, 1e-5);

    // rfDots pulls the decoded luma back towards the raw composite at this
    // exact pixel, which is the residual subcarrier the average removed --
    // i.e. the leakage the Y/C split failed to reject.  Turning it up is
    // "this TV has a worse comb filter", not "draw more dots".
    if (rfDots > 0.0) {
        float th = 2.0 * PI * (CYCLES_PER_PX * gbPix.x + linePh);
        vec3 here = rgb2yuv(Texel(tex, uv).rgb);
        float comp0 = here.x + (here.y * sin(th) + here.z * cos(th)) * rfColour;
        Y = mix(Y, comp0, 0.35 * rfDots);
    }

    vec3 col = yuv2rgb(vec3(Y, U, Vv));

    // ---- 3. the tube again: scanlines and vignette ----
    if (rfScan > 0.0) {
        // The reference darkens every odd row of a 480-row frame, i.e. two
        // scan rows per decoded line, as a lookup table at native resolution.
        // We cannot do that: at 5 screen pixels per GB pixel a hard odd/even
        // rule lands on 2.5 px and aliases into moire the moment the window
        // is not an exact multiple.  So the same period is drawn as a smooth
        // profile instead -- same two-per-line rate, same 0.72 floor, no
        // stair-stepping.  This is a deliberate departure from the reference
        // and the only one in this file.
        float phase = 0.5 + 0.5 * cos(2.0 * PI * gbPix.y * 2.0);
        col *= mix(mix(1.0, SCAN_FLOOR, rfScan), 1.0, phase);
    }
    if (rfCurve > 0.0) {
        col *= max(0.0, 1.0 - VIGNETTE * rfCurve * r2 * r2);
    }

    // ---- 4. what the aerial picked up that was not the picture ----
    if (rfNoise > 0.0) {
        float n = hash21(floor(gbPix * vec2(1.0, 1.0)) + vec2(time * 61.0, 0.0));
        col += (n - 0.5) * 0.09 * rfNoise;
    }

    // rfStrength is the whole pass's dry/wet, so OFF and the rungs below
    // NORMAL cost the same as any other frame in everything except the
    // texture reads -- and mean exactly what they say.
    //
    // The dry sample is taken at `uv`, NOT at `tc`. That is the difference
    // between a mix and a DOUBLE EXPOSURE. `col` was built from samples at
    // uv = curved(tc); sampling the dry side at tc instead composites an
    // UNWARPED copy of the picture over the warped one, and at NORMAL that is
    // a 20% ghost of every sprite, sitting still while the real picture bows
    // away from it. It was reported as "a ghosted shadow that doesn't move,
    // and it ghosts the other sprites as well", which is precisely what it is.
    //
    // Geometry cannot be dry/wet mixed. Blending a bent and an unbent image
    // does not give you a less bent one. So the barrel is applied in full
    // whenever this pass runs at all, RF CURVE alone decides how much of it
    // there is, and rfStrength mixes only what it can meaningfully mix: the
    // SIGNAL -- the Y/C split, the dot crawl, the cross colour.
    vec3 dry = Texel(tex, uv).rgb;
    col = mix(dry, col, clamp(rfStrength, 0.0, 1.0));
    return vec4(col, 1.0) * color;
}
]]

RfTv.SHADER_SRC = SHADER_SRC

-- Multipliers on the shader's base unit, in this mod's existing idiom: named
-- rungs, NORMAL meaning "the reference's own constant", and the rungs above
-- it going past what the hardware did because a 1280x800 screen spreads what
-- a 256x240 tube concentrated.
RfTv.STRENGTH = { off = 0, soft = 0.45, normal = 0.8, harsh = 1.0 }
RfTv.DOTS     = { off = 0, low = 0.4, normal = 1.0, high = 1.8 }
RfTv.COLOUR   = { off = 0, faint = 0.25, low = 0.5, normal = 1.0,
                  high = 1.6, max = 2.4 }
-- Chroma BANDWIDTH, as a multiplier on UV_WIDEN -- how far colour runs past
-- an edge, which is a different question from how much colour there is.
-- STUDIO is a monitor holding colour nearly as tight as luma; PORTABLE is a
-- cheap set that threw its chroma bandwidth away and smears a red roof half
-- way across the sky.
RfTv.CHROMA   = { studio = 0.45, tight = 0.7, normal = 1.0, wide = 1.6,
                  portable = 2.4 }
-- Subcarrier phase error, in RADIANS. Negative rotates hues towards green,
-- positive towards red -- which is exactly what the TINT knob on the front of
-- an NTSC set did, and the reason it was there at all. 0.17 rad is about 10
-- degrees, 0.35 about 20.
RfTv.TINT     = { off = 0, green = -0.17, greenmore = -0.35,
                  red = 0.17, redmore = 0.35 }
RfTv.SCAN     = { off = 0, low = 0.45, normal = 1.0, high = 1.0 }
RfTv.CURVE    = { off = 0, low = 0.5, normal = 1.0, high = 2.0 }
RfTv.NOISE    = { off = 0, low = 0.35, normal = 1.0, high = 2.2 }

local function amount(table_, setting, fallback)
  return table_[setting:get()] or table_[fallback] or 0
end

-- Is the pass meant to draw at all?  One question, asked in one place, so the
-- row, the status line and the frame cannot disagree about it.
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

function RfTv.wanted()
  if fxOff() then return false end
  return amount(RfTv.STRENGTH, Settings.rf, "off") > 0
end

-- The barrel constant the shader is actually bending the picture by, for the
-- passes that have to agree with it: the CRT edge vignette, which must bow
-- with the glass rather than darken a flat rectangle, and the drop shadow,
-- which must lie under the same glass as the sprite casting it.
--
-- NOT scaled by the master mix. It used to be, on the theory that rfStrength
-- partly un-bent the picture -- but that was only true because the dry side
-- was sampled unwarped, which was the ghosting bug. The dry side is now
-- sampled through the same warp, so the geometry is full-strength whenever
-- the pass runs and RF CURVE alone decides how much of it there is. The
-- followers have to say exactly that or they drift out of step with the glass
-- they are meant to be under.
RfTv.BARREL_K1 = 0.055        -- must equal the shader's #define
function RfTv.barrelK()
  if amount(RfTv.STRENGTH, Settings.rf, "off") <= 0 then return 0 end
  local curve = amount(RfTv.CURVE, Settings.rfcurve, "low")
  if curve <= 0 then return 0 end
  return RfTv.BARREL_K1 * curve
end

local shader = nil        -- nil = untried, false = failed
local failure = nil
local target = nil        -- the intermediate buffer

function RfTv.shader()
  if shader ~= nil then return shader or nil end
  if not (love and love.graphics and love.graphics.newShader) then
    shader, failure = false, "NO GFX"
    return nil
  end
  local ok, made = pcall(love.graphics.newShader, SHADER_SRC)
  if not ok or not made then
    shader, failure = false, "BAD GLSL"
    return nil
  end
  shader = made
  return shader
end

function RfTv.status()
  if shader == false then return failure or "ERROR" end
  return nil
end

-- Reset between tests; a compiled shader and a canvas are both bound to a
-- graphics context that the harness does not have.
function RfTv.reset()
  shader, failure, target = nil, nil, nil
end

local function buffer(w, h)
  if target and target:getWidth() == w and target:getHeight() == h then
    return target
  end
  if not (love.graphics and love.graphics.newCanvas) then return nil end
  local ok, made = pcall(love.graphics.newCanvas, w, h)
  if not ok or not made then return nil end
  target = made
  return target
end

-- Run the pass and hand back a canvas for the light to draw over.
--
-- Returns the ORIGINAL canvas on every failure and whenever the pass is off,
-- so a caller can write `canvas = RfTv.apply(canvas, ps)` unconditionally.
-- That contract is what keeps this inside the mod's rule that it may stop
-- working but may not break a frame: there is no path here that returns
-- something a caller cannot draw.
function RfTv.apply(canvas, pixelScale)
  if not canvas or not RfTv.wanted() then return canvas end
  local sh = RfTv.shader()
  if not sh then return canvas end

  local okDim, w, h = pcall(canvas.getDimensions, canvas)
  if not okDim or not w then return canvas end
  local dst = buffer(w, h)
  if not dst then return canvas end

  local t = (love.timer and love.timer.getTime and love.timer.getTime()) or 0
  local ok = pcall(function()
    sh:send("time", t)
    sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
    sh:send("rfStrength", amount(RfTv.STRENGTH, Settings.rf, "off"))
    sh:send("rfDots", amount(RfTv.DOTS, Settings.rfdots, "normal"))
    sh:send("rfColour", amount(RfTv.COLOUR, Settings.rfcolour, "normal"))
    sh:send("rfChroma", amount(RfTv.CHROMA, Settings.rfchroma, "normal"))
    sh:send("rfTint", amount(RfTv.TINT, Settings.rftint, "off"))
    sh:send("rfScan", amount(RfTv.SCAN, Settings.rfscan, "normal"))
    sh:send("rfCurve", amount(RfTv.CURVE, Settings.rfcurve, "low"))
    sh:send("rfNoise", amount(RfTv.NOISE, Settings.rfnoise, "off"))
  end)
  if not ok then
    shader, failure = false, "NO UNIF"
    return canvas
  end

  ok = pcall(function()
    local prev = love.graphics.getCanvas()
    love.graphics.setCanvas(dst)
    love.graphics.clear(0, 0, 0, 1)
    love.graphics.setShader(sh)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, 0, 0)
    love.graphics.setShader()
    love.graphics.setCanvas(prev)
  end)
  if not ok then
    -- leave the canvas stack alone rather than guessing at it
    pcall(love.graphics.setShader)
    return canvas
  end

  RfTv.frames = (RfTv.frames or 0) + 1
  return dst
end

return RfTv
