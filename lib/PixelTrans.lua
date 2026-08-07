-- The pixel-transparency pass: the picture as an UNLIT Game Boy Color panel.
--
-- ------- the observation it is built on
--
-- A GBC has no backlight, so a light pixel is not white light -- it is a
-- WINDOW, and what you see through it is the grey plate behind the LCD.
-- Games authored for that hardware used "white" as transparent, and on a lit
-- modern panel those areas come back as searing white instead. This puts the
-- plate back. On top of that it models what sunlight does to the front of
-- the panel: the rear circular polarizer's quarter-wave film gives an exact
-- lambda/4 shift only at its design wavelength, and the chromatic mismatch
-- everywhere else leaks through as the angle-dependent rainbow every GBC
-- owner has seen outdoors.
--
-- The spectral core is kept faithful to the physics rather than
-- approximated: a 7-wavelength integration and Snell refraction through the
-- film. The suite diffs the spectral table in the GLSL against the Lua copy
-- below, so the two cannot drift apart.
--
-- ------- no sensor path of its own
--
-- The obvious way to build this is to read the accelerometer in the vertex
-- stage and derive tilt there. This pass deliberately does not.
--
-- This mod IS a motion stack -- a fused gyro/accelerometer filter with
-- recentring, auto-levelling and per-axis mapping, all measured on this
-- hardware (see Motion.lua). A second, cruder one inside a shader would mean
-- two filters disagreeing about where the light is. So this takes ONE light
-- position as a uniform, the same lx, ly every other pass here is driven by,
-- and the shadow offset arrives precomputed from GbcLight.shadowOffset,
-- which already knows how to point a shadow away from that light without
-- snapping at the pivot.
--
-- There is no glare here either. Overlay.lua already draws a specular glare
-- from the same light on the GLARE row, and a second hotspot under the first
-- would be two rows fighting over one highlight.
--
-- ------- where it sits in the frame
--
-- FIRST -- before TV/RF and the CRT, on the same side of the pipeline as the
-- swatch strips.  The panel is part of the PICTURE: the plate, its grain,
-- its shadows and its rainbow are all things a camera pointed at a GBC would
-- record, so the barrel curve, the phosphor mask and the scanlines must all
-- happen TO them.  Drawn after those passes instead, the plate would sit
-- flat on top of a bowed picture -- exactly the "flat sticker on curved
-- glass" failure drawSwatches in GbcLight exists to avoid.  See the chain
-- comment in GbcLight.present: SIGNAL -> TUBE -> front reflection; this pass
-- is what the signal is OF.

local V = ...
local Settings = V.require("Settings")

local PixelTrans = {}

local SHADER_SRC = [[
extern number pixelScale;
extern number ptMode;       // 0 whites only, 1 by brightness, 2 all pixels
extern number ptAlpha;      // base transparency
extern vec3 ptBacking;      // plate tint, pre-normalised on the Lua side
extern number ptBackingMix; // 0 = plain grey plate, 1 = full tint
extern number ptShadow;     // shadow opacity; 0 = off
extern vec2 ptShadowOff;    // GB pixels, same convention as deckShadowOff
extern number ptRainbow;    // rainbow intensity; 0 = off
extern number ptSpread;     // band density: angle of incidence per unit dist
extern number ptSplotch;    // film thickness noise amount
extern number ptGrain;      // reflector sheet grain, 1.0 = the model
extern vec2 ptLight;        // the mod's light position, 0..1 screen space

// The model's own constants, kept at its defaults.  THRESHOLD is the
// white detection level; BACKING_BRIGHTNESS the unlit plate; NOISE_MEAN is
// the expected value of the 3-octave fbm below (0.5+0.25+0.125 halved), so
// subtracting it centres the grain instead of brightening the plate.
#define PT_THRESHOLD 0.90
#define BACKING_BRIGHTNESS 0.48
#define GRAIN_INTENSITY 0.065
#define GRAIN_SCALE 0.25
#define GRAIN_MEAN 0.5
#define NOISE_MEAN 0.4375
// Double-pass through the 137.5nm quarter-wave film, and its refractive
// index (stretched polycarbonate).  These two ARE the rainbow: gamma falls
// with viewing angle via Snell, and the 7 cos^2(k*gamma) terms below turn
// that into the colour cycle.
#define GAMMA_BASE 275.0
#define N_FILM 1.5
#define FILM_SCALE 0.6
#define SHADOW_BLUR 1.0
#define SHADOW_FLOOR 0.2
// The model's brightness-mode gain: at base alpha 0.20 a full-white
// pixel lands just past 0.5 transparency, which is its calibrated look.
#define BRIGHT_GAIN 2.665
// ~30:1 contrast of a reflective TFT: even a black pixel reflects a little.
#define REFLECT_FLOOR 0.03

float luma709(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float smoothValue(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// ------- the reflector sheet's grain, in the bands that actually read
//
// The model measured three bands in the sheet: about half a dot, one to
// three dots, and eighteen to thirty-six. Its conclusion is the useful part:
// "only the middle one reads as grain at the Pocket's pixel pitch; the finest
// is below what the panel resolves and the coarsest is mottling."
//
// The three-octave fbm this replaces did not respect that. At GRAIN_SCALE
// 0.25 its octaves landed at 128, 256 and 512 cycles across 160 dots -- a
// period of 1.25 dots, 0.63 and 0.31. Only the first was resolvable; the
// other two were below one dot, so they cost two thirds of the samples to
// produce aliasing rather than grain. And the coarse mottling band, which IS
// visible, was missing entirely.
//
// So: one raw-hash octave in the 1-3 dot band, where grain lives, plus one
// smooth octave in the 18-36 dot band, which reads as the sheet being
// unevenly mottled rather than as speckle. Two samples instead of three, and
// both of them land somewhere the eye can see.
//
//   107 cycles / 160 dots = 1.5 dots per cycle   (the grain band)
//   6.7 cycles / 160 dots = 24 dots per cycle    (the mottling band)
//
// Mean is 0.5 by construction -- both terms are mean-0.5 and the weights sum
// to one -- which is why GRAIN_MEAN below is a flat 0.5 rather than the
// fbm's awkward 0.4375.
#define GRAIN_MID_CYCLES 107.0
#define GRAIN_COARSE_CYCLES 6.7
#define GRAIN_COARSE_MIX 0.28

float reflectorGrain(vec2 uv)
{
    float mid = hash12(uv * GRAIN_MID_CYCLES);
    float coarse = smoothValue(uv * GRAIN_COARSE_CYCLES);
    return mid * (1.0 - GRAIN_COARSE_MIX) + coarse * GRAIN_COARSE_MIX;
}

// Film: the same fbm over INTERPOLATED noise, so it is smooth -- broad
// gradual variation, matching real QWP manufacturing thickness gradients.
float filmNoise(vec2 uv, float scale)
{
    vec2 p = uv * scale * 8.0;
    float n = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < 3; i++) {
        n += smoothValue(p * frequency) * amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return n;
}

// A white pixel needs BOTH a bright luma and no dark channel: a saturated
// yellow can clear the luma bar and is emphatically not a window.
bool isWhitePixel(vec3 c)
{
    float b = luma709(c);
    float m = min(min(c.r, c.g), c.b);
    return (b > PT_THRESHOLD && m > PT_THRESHOLD * 0.9);
}

// The QWP chromatic dispersion, integrated over 7 wavelengths.  Each line is
// one wavelength: its spectral colour, and cos^2 of (4*pi/lambda) times the
// effective retardance.  The literals are the model's own table; the
// suite checks them against the Lua copy AND against 4*pi/lambda, so an edit
// to either side fails a test instead of shifting the rainbow quietly.
vec3 qwpSpectralTint(float g)
{
    vec3 tint = vec3(0.0);
    float c;
    c = cos(0.031415927 * g); tint += vec3(0.000000, 0.000000, 0.026075) * c * c;
    c = cos(0.028399638 * g); tint += vec3(0.141223, 0.000000, 0.368894) * c * c;
    c = cos(0.025874228 * g); tint += vec3(0.000000, 0.480861, 0.473477) * c * c;
    c = cos(0.023809524 * g); tint += vec3(0.081095, 0.812848, 0.339825) * c * c;
    c = cos(0.021991149 * g); tint += vec3(0.783356, 0.793891, 0.134941) * c * c;
    c = cos(0.020462441 * g); tint += vec3(0.972432, 0.423991, 0.215476) * c * c;
    c = cos(0.019138570 * g); tint += vec3(0.648322, 0.114430, 0.000000) * c * c;
    float peak = max(tint.r, max(tint.g, tint.b));
    if (peak > 0.001) tint /= peak;
    return tint;
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 pc)
{
    vec3 pix = Texel(tex, tc).rgb;
    vec3 outc = pix;
    float ps = max(pixelScale, 1.0);
    vec2 gbTexel = ps / love_ScreenSize.xy;

    bool white = isWhitePixel(pix);
    float intensity = luma709(pix);

    // ---- the plate behind the LCD ----
    vec3 background = vec3(BACKING_BRIGHTNESS)
        + vec3((reflectorGrain(tc) - GRAIN_MEAN) * GRAIN_INTENSITY * ptGrain);

    // ---- the shadow the LC layer drops onto it ----
    // Dark pixels float a little above the plate, so they shade it.  The
    // offset arrives from the Lua side, already pointing away from the same
    // light every other pass follows.  The 3x3 gaussian is the model's
    // high-quality blur, written as a loop because GLSL 1.20 has no array
    // constructors: centre 4, edges 2, corners 1, total 16.
    if (ptShadow > 0.0) {
        vec2 shadowOff = -ptShadowOff * gbTexel;
        vec2 blurDist = SHADOW_BLUR * gbTexel;
        float blurred = 0.0;
        for (int i = -1; i <= 1; i++) {
            for (int j = -1; j <= 1; j++) {
                vec2 sp = tc + shadowOff + vec2(float(i), float(j)) * blurDist;
                float w = (i == 0 && j == 0) ? 4.0 : ((i == 0 || j == 0) ? 2.0 : 1.0);
                blurred += (1.0 - luma709(Texel(tex, sp).rgb)) * w;
            }
        }
        float strength = (blurred / 16.0) * ptShadow;
        // deadzone: near-white neighbours must not dust the plate grey
        float deadzone = (1.0 - PT_THRESHOLD) * ptShadow;
        if (deadzone > 0.001) {
            strength = smoothstep(0.0, deadzone, strength) * strength;
        }
        background = mix(background, background * SHADOW_FLOOR, strength);
    }

    // ---- the plate's tint ----
    // The model's palette arithmetic: the tint plus the grain remapped
    // to -1..1, clamped -- so the grain survives the tint instead of being
    // averaged away by a mix towards a flat colour.
    if (ptBackingMix > 0.0) {
        vec3 tinted = clamp(ptBacking + background * 2.0 - vec3(1.0), 0.0, 1.0);
        background = mix(background, tinted, ptBackingMix);
    }

    // ---- the transparency itself ----
    // BRIGHT: every pixel is a window in proportion to its brightness.
    // WHITES / ALL: the model's other two modes -- only detected whites,
    // or everything, each at intensity/3 + base.
    if (ptMode > 0.5 && ptMode < 1.5) {
        float t = clamp(ptAlpha * intensity * BRIGHT_GAIN, 0.0, 1.0);
        outc = mix(pix, background, t);
    } else if (ptMode > 1.5 || white) {
        float a = clamp(intensity / 3.0 + ptAlpha, 0.0, 1.0);
        outc = mix(pix, background, a);
    }

    // ---- the front polarizer ----
    // Iodine-PVA, seen twice (light goes in and back out), so the model
    // squares its single-pass (0.97, 1.0, 0.93) to (0.94, 1.0, 0.865).
    outc *= vec3(0.94, 1.0, 0.865);

    // ---- the sunlight rainbow ----
    if (ptRainbow > 0.0) {
        float aspect = love_ScreenSize.x / love_ScreenSize.y;
        vec2 toL = (tc - ptLight) * vec2(aspect, 1.0);
        float d = length(toL);
        // angle of incidence grows with distance from the light (the
        // reference's flat-light model, its shipped default), refracts into
        // the film by Snell, and shortens the effective retardance
        float angle = clamp(d * ptSpread, 0.0, 1.4);
        float sinr = sin(angle) / N_FILM;
        float cosr = sqrt(1.0 - sinr * sinr);
        float gammaEff = GAMMA_BASE * cosr;
        // manufacturing variation bends the rings into the splotchy patches
        // real hardware shows, instead of clean compass circles
        if (ptSplotch > 0.0) {
            float n = filmNoise(vec2(tc.x * aspect, tc.y), FILM_SCALE) - NOISE_MEAN;
            gammaEff *= (1.0 + n * ptSplotch);
        }
        vec3 tint = qwpSpectralTint(gammaEff);
        // the reflection double-passes the LC layer, so dark pixels return
        // less of it; and it double-passes the colour filters, so the pixel
        // colour is squared
        float strength = ptRainbow * mix(REFLECT_FLOOR, 1.0, intensity);
        tint *= pix * pix;
        // luminance-preserving: shift the colour, give back the brightness
        vec3 tinted = outc * mix(vec3(1.0), tint, strength);
        float l0 = luma709(outc);
        float l1 = luma709(tinted);
        if (l1 > 0.001) tinted *= l0 / l1;
        outc = tinted;
    }

    // anti-banding dither: the plate is a near-flat gradient, which is
    // exactly where 8-bit quantisation draws contour lines
    outc += vec3((hash12(pc) - 0.5) / 255.0);

    return vec4(clamp(outc, 0.0, 1.0), 1.0) * color;
}
]]

PixelTrans.SHADER_SRC = SHADER_SRC

-- ------- the pure arithmetic, in Lua
--
-- The GLSL cannot run in the test harness, so every piece of it that decides
-- what the effect looks like exists here too, as plain functions of their
-- inputs -- the same arrangement GbcLight.shadowOffset uses.  These are not
-- approximations of the shader: they are the SPEC it is written against, and
-- the suite holds the shader's literals to them.  (What they cannot promise
-- is bit-equality with a GPU, whose floats are 32-bit; the properties the
-- tests assert -- determinism, bounds, means, monotonicity -- survive that.)

local function fract(x) return x - math.floor(x) end
local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

PixelTrans.THRESHOLD = 0.90

-- BT.709, the same weights the engine's GBC FX uses for "how bright".
function PixelTrans.luma(r, g, b)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
end

function PixelTrans.isWhite(r, g, b, threshold)
  local t = threshold or PixelTrans.THRESHOLD
  local bright = PixelTrans.luma(r, g, b)
  local m = math.min(r, math.min(g, b))
  return bright > t and m > t * 0.9
end

-- The model's hash (Dave Hoskins' hash12), mirrored operation for
-- operation so the noise tests exercise the same arithmetic the GPU runs.
function PixelTrans.hash(x, y)
  local a = fract(x * 0.1031)
  local b = fract(y * 0.1031)
  local c = fract(x * 0.1031)
  local d = a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33)
  a, b, c = a + d, b + d, c + d
  return fract((a + b) * c)
end

function PixelTrans.paperNoise(x, y, scale)
  local px, py = x * scale * 512.0, y * scale * 512.0
  local n, amplitude, frequency = 0.0, 0.5, 1.0
  for _ = 1, 3 do
    n = n + PixelTrans.hash(px * frequency, py * frequency) * amplitude
    amplitude = amplitude * 0.5
    frequency = frequency * 2.0
  end
  return n
end

local function smoothValue(x, y)
  local ix, iy = math.floor(x), math.floor(y)
  local fx, fy = x - ix, y - iy
  fx = fx * fx * (3.0 - 2.0 * fx)
  fy = fy * fy * (3.0 - 2.0 * fy)
  local a = PixelTrans.hash(ix, iy)
  local b = PixelTrans.hash(ix + 1, iy)
  local c = PixelTrans.hash(ix, iy + 1)
  local d = PixelTrans.hash(ix + 1, iy + 1)
  local top = a + (b - a) * fx
  local bot = c + (d - c) * fx
  return top + (bot - top) * fy
end

function PixelTrans.filmNoise(x, y, scale)
  local px, py = x * scale * 8.0, y * scale * 8.0
  local n, amplitude, frequency = 0.0, 0.5, 1.0
  for _ = 1, 3 do
    n = n + smoothValue(px * frequency, py * frequency) * amplitude
    amplitude = amplitude * 0.5
    frequency = frequency * 2.0
  end
  return n
end

-- The 7-wavelength table: spectral colour, phase factor, and the wavelength
-- the factor is 4*pi over.  One copy, here; the GLSL literals are diffed
-- against it by the suite, which is what "the same model" means in practice.
PixelTrans.SPECTRUM = {
  { s = { 0.000000, 0.000000, 0.026075 }, k = 0.031415927, nm = 400.000 },
  { s = { 0.141223, 0.000000, 0.368894 }, k = 0.028399638, nm = 442.857 },
  { s = { 0.000000, 0.480861, 0.473477 }, k = 0.025874228, nm = 485.714 },
  { s = { 0.081095, 0.812848, 0.339825 }, k = 0.023809524, nm = 528.571 },
  { s = { 0.783356, 0.793891, 0.134941 }, k = 0.021991149, nm = 571.429 },
  { s = { 0.972432, 0.423991, 0.215476 }, k = 0.020462441, nm = 614.286 },
  { s = { 0.648322, 0.114430, 0.000000 }, k = 0.019138570, nm = 657.143 },
}

-- The spectral tint for an effective retardance, peak-normalised to 1.
function PixelTrans.qwpTint(gammaEff)
  local r, g, b = 0.0, 0.0, 0.0
  for _, w in ipairs(PixelTrans.SPECTRUM) do
    local c = math.cos(w.k * gammaEff)
    local cc = c * c
    r = r + w.s[1] * cc
    g = g + w.s[2] * cc
    b = b + w.s[3] * cc
  end
  local peak = math.max(r, math.max(g, b))
  if peak > 0.001 then
    r, g, b = r / peak, g / peak, b / peak
  end
  return r, g, b
end

PixelTrans.GAMMA_BASE = 275.0
PixelTrans.N_FILM = 1.5

-- Distance from the light -> effective retardance, via the flat-light angle
-- model and Snell refraction into the film.  This is the geometry half of
-- the rainbow; qwpTint is the spectral half.
function PixelTrans.gammaEff(dist, spread)
  local angle = clamp(dist * (spread or 1.8), 0.0, 1.4)
  local sinr = math.sin(angle) / PixelTrans.N_FILM
  local cosr = math.sqrt(1.0 - sinr * sinr)
  return PixelTrans.GAMMA_BASE * cosr
end

-- The compositing arithmetic: how transparent one pixel is.  mode is the
-- reference's PT_PIXEL_MODE (0 whites only, 1 by brightness, 2 all).
PixelTrans.BRIGHT_GAIN = 2.665
function PixelTrans.alphaFor(mode, intensity, baseAlpha, white)
  if mode == 1 then
    return clamp(baseAlpha * intensity * PixelTrans.BRIGHT_GAIN, 0.0, 1.0)
  end
  if mode == 0 and not white then return 0 end
  return clamp(intensity / 3.0 + baseAlpha, 0.0, 1.0)
end

-- ------- the rungs
--
-- MODE maps the master row straight onto the model's PT_PIXEL_MODE;
-- OFF is absent because OFF means the pass does not run at all.
PixelTrans.MODE = { whites = 0, bright = 1, all = 2 }

-- NORMAL is the model's shipped default in every ladder below, so the
-- row means "as the original effect" rather than "as looked nice here".
PixelTrans.ALPHA   = { low = 0.10, normal = 0.20, high = 0.35, max = 0.55 }
PixelTrans.SHADOW  = { off = 0, soft = 0.30, normal = 0.50, deep = 0.75 }
PixelTrans.RAINBOW = { off = 0, subtle = 0.08, normal = 0.15,
                       strong = 0.30, max = 0.50 }
PixelTrans.SPREAD  = { wide = 1.0, normal = 1.8, fine = 2.6, finest = 3.4 }
PixelTrans.SPLOTCH = { off = 0, low = 0.25, normal = 0.5, high = 0.8 }
-- The sheet grain, as a multiple of the model's own 0.065. It had no row
-- at all and could not be tried; NORMAL is exactly the model.
PixelTrans.GRAIN = { off = 0, low = 0.5, normal = 1.0, high = 2.0, max = 3.5 }
PixelTrans.GRAIN_MID_CYCLES = 107.0
PixelTrans.GRAIN_COARSE_CYCLES = 6.7
PixelTrans.GRAIN_COARSE_MIX = 0.28
PixelTrans.GRAIN_MEAN = 0.5

-- ------- the plate colours
--
-- The model's four palettes plus its palette-off grey, keyed by the
-- BACKING row's values.  Stored raw; the swatch strip reads this table (see
-- GyroMenu.settingRow) and the shader receives backingColour() below.
-- OLIVE is the plain Warm1 -- the green-grey plate of an actual GBC, and
-- the colour in its own screenshots -- so it is the row's default.
PixelTrans.BACKING = {
  plain   = { 0.48, 0.48, 0.48 },      -- BACKING_BRIGHTNESS: no tint at all
  olive   = { 0.651, 0.675, 0.518 },   -- Warm1, the real console's plate
  warm    = { 0.72, 0.73, 0.66 },      -- Warm2
  neutral = { 0.766, 0.73, 0.763 },
  silver  = { 0.76, 0.76, 0.76 },      -- aluminium, spectrally neutral
}

-- What the shader is sent: the model normalises every palette to Warm1's
-- peak channel (0.675) so switching plates changes the COLOUR of the plate
-- and not how bright it is -- the same one-question-per-row rule the glare
-- tint follows.
PixelTrans.BACKING_PEAK = 0.675

-- ------- how much light is falling on the panel
--
-- The one control a screen with NO BACKLIGHT actually has, and the model
-- exposes it (PT_BACKING_BRIGHTNESS, 0.20 to 0.65, shipping at 0.48) while
-- this port had it welded to 0.48.
--
-- It is not a brightness slider in the television sense. The panel emits
-- nothing; everything you see is room light going through the LCD, off the
-- reflector and back out. Turn it down and you get the real experience of a
-- Game Boy Color in a dim room -- murky, low contrast, the thing that made
-- everyone hold it under a lamp. Turn it up and you get it on a bright day.
--
-- The rungs span the model's full range, with NORMAL on its shipped
-- value so the default is unchanged.
PixelTrans.ROOMLIGHT = {
  dim = 0.20, low = 0.32, normal = 0.48, bright = 0.58, sunlit = 0.65,
}
PixelTrans.ROOMLIGHT_REF = 0.48

-- Delegates to Settings, which owns the ladder now that the DMG pass reads it
-- too. The table below is kept as the published reference for the tests.
function PixelTrans.roomLight()
  local ok, v = pcall(Settings.roomLight)
  if ok and type(v) == "number" then return v end
  return PixelTrans.ROOMLIGHT_REF
end

function PixelTrans.backingColour(name)
  local c = PixelTrans.BACKING[name or Settings.ptback:get()]
         or PixelTrans.BACKING.olive
  local m = math.max(c[1], math.max(c[2], c[3]))
  if m <= 1e-6 then return 1, 1, 1 end
  -- normalise to Warm1's peak so the BACKING row changes hue only, THEN
  -- scale by the room light so this row changes level only. Two rows, two
  -- questions, in that order.
  local k = (PixelTrans.BACKING_PEAK / m)
            * (PixelTrans.roomLight() / PixelTrans.ROOMLIGHT_REF)
  return c[1] * k, c[2] * k, c[3] * k
end

-- ------- the shadow's direction
--
-- Delegated to GbcLight.shadowOffset, the same function the engine patch and
-- the overlay use, so all three shadows in this mod agree about which way
-- "away from the light" is -- including the pivot softening that keeps the
-- reversal sub-pixel.  With no light (MOTION off, no sensor) the offset is
-- the fixed stock down-right, which is also what the model does with its
-- sensor path disabled.  Deliberately NOT coupled to the SHADOW row: that
-- row owns the drop shadow of the text and sprites, and a row labelled
-- SHADOW OFF that also deleted a row labelled LCD SHADOW NORMAL would be two
-- rows disagreeing about one value.  Required lazily, as GbcLight requires
-- this module, and two eager requires in a cycle would be a load-order bug.
function PixelTrans.shadowFor(lx, ly)
  local opacity = PixelTrans.SHADOW[Settings.ptshadow:get()]
               or PixelTrans.SHADOW.normal
  local GbcLight = V.require("GbcLight")
  local ox, oy
  if lx and ly then
    ox, oy = GbcLight.shadowOffset(lx, ly, "follow")
  else
    ox, oy = GbcLight.shadowOffset(nil, nil, "fixed")
  end
  return ox, oy, opacity
end

local function amount(map, setting, fallback)
  return map[setting:get()] or map[fallback] or 0
end

-- One question, one place, same as RfTv: does the pass draw at all.
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

function PixelTrans.wanted()
  if fxOff() then return false end
  return PixelTrans.MODE[Settings.pt:get()] ~= nil
end

local shader, failure, target = nil, nil, nil

function PixelTrans.shader()
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

function PixelTrans.status()
  if shader == false then return failure or "ERROR" end
  return nil
end

-- Reset between tests; the shader and canvas belong to a graphics context
-- this harness does not have.
function PixelTrans.reset()
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

-- Run the pass and hand back a canvas for the passes above to bend and mask.
--
-- Same contract as RfTv.apply and CrtBeam.apply, to the letter: the ORIGINAL
-- canvas comes back on every failure and whenever the pass is off, so the
-- caller chains it without a branch and no path here can cost a frame.
--
-- `lx, ly` is the mod's light position, or nil when Motion declined.  Passed
-- IN rather than read here, because Motion.light(dt) advances the filters
-- and must be called exactly once a frame -- GbcLight.present owns that call
-- and hands the result to everything that wants it.  With no light the panel
-- still draws (the plate and the transparency need no light at all); only
-- the shadow direction and the rainbow centre fall back to their static
-- reference defaults.
function PixelTrans.apply(canvas, pixelScale, lx, ly)
  if not canvas or not PixelTrans.wanted() then return canvas end
  local sh = PixelTrans.shader()
  if not sh then return canvas end

  local okDim, w, h = pcall(canvas.getDimensions, canvas)
  if not okDim or not w then return canvas end
  local dst = buffer(w, h)
  if not dst then return canvas end

  local ok = pcall(function()
    sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
    sh:send("ptMode", PixelTrans.MODE[Settings.pt:get()] or 1)
    sh:send("ptAlpha", amount(PixelTrans.ALPHA, Settings.ptalpha, "normal"))
    local br, bg, bb = PixelTrans.backingColour()
    sh:send("ptBacking", { br, bg, bb })
    sh:send("ptBackingMix", Settings.ptback:get() == "plain" and 0 or 1)
    local ox, oy, op = PixelTrans.shadowFor(lx, ly)
    sh:send("ptShadow", op)
    sh:send("ptShadowOff", { ox, oy })
    sh:send("ptRainbow", amount(PixelTrans.RAINBOW, Settings.ptrainbow, "normal"))
    sh:send("ptSpread", amount(PixelTrans.SPREAD, Settings.ptbands, "normal"))
    sh:send("ptSplotch", amount(PixelTrans.SPLOTCH, Settings.ptfilm, "normal"))
    sh:send("ptGrain", amount(PixelTrans.GRAIN, Settings.ptgrain, "normal"))
    -- the model's PT_LIGHT_X/Y default: centred, when nothing drives it
    sh:send("ptLight", { lx or 0.5, ly or 0.5 })
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
    pcall(love.graphics.setShader)
    return canvas
  end

  PixelTrans.frames = (PixelTrans.frames or 0) + 1
  return dst
end

return PixelTrans
