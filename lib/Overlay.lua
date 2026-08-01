-- The light overlay, for when the engine's own GBC FX is not available.
--
-- The 3D mod holds GBC FX at zero while it is installed, and says why in its
-- changelog: GBC FX is a full-screen pass over the top of a diorama, and the
-- two fight.  What it objects to is the LCD SIMULATION -- the backing plate,
-- the subpixel grid, the brightness-keyed transparency that floats dark GB
-- pixels above a plastic sheet.  All of that models a handheld screen, and
-- none of it means anything over a 3D world.
--
-- The glare and the shimmer are not that.  They are what a light source does
-- to a surface you are holding, and they read the same over a diorama as over
-- a flat frame.  So this shader keeps those two and drops the panel.
--
-- Written out rather than patched out of GBCFX.SHADER_SRC.  The two-statement
-- rewrite in GbcLight is safe because it is small and asserted; carving four
-- separate blocks out of someone else's shader by text substitution is not,
-- and it would break on any upstream edit to any of them.  The glare and
-- shimmer constants below are the engine's, so the light matches.
--
-- The drop shadow is the one part that could not be carried over as it is.
-- The engine's version darkens the BACKING PLATE where a dark GB pixel
-- floats above it.  There is no backing plate here.  The equivalent that
-- does survive is a screen-space shadow: sample the frame at an offset
-- against the light, and darken where what is behind is darker than here.
-- Same reading -- a lit thing casting away from the light -- by the only
-- mechanism a composited frame offers.

local V = ...

local Overlay = {}

-- The engine's own values, so the glare and the bands match GBC FX exactly.
local SHADER_SRC = [[
extern number time;
extern number pixelScale;
extern vec2 deckLight;
extern vec2 deckShadowOff;
extern number deckShadowAmt;
extern number deckGlare;
extern number deckShimmer;

#define PI 3.14159265359
// The engine's 0.15 is a hotspot on a 160x144 panel.  Spread over a full
// screen it is nearly invisible, so the GLARE row scales it and reaches well
// past 1.0.
#define GLARE_INTENSITY 0.15
#define GLARE_SIGMA 0.25
#define SHIMMER_INTENSITY 0.25
// The engine uses 3.0 here, and says why: it compensates for an image that
// has already been desaturated and blended into the backing plate.  This
// pass has no backing plate, so the bands land on full-brightness pixels and
// 3.0 over-drives them into thin coloured contour lines wherever the frame
// is large, flat and pale -- which a 3D world mostly is.
#define SHIMMER_CHROMA_GAIN 1.0
// Fewer, broader rings.  The engine's 1.8 packs the bands tightly, which is
// splotchy over a 160x144 panel and aliases into hairlines at full res.
#define SHIMMER_SPREAD 1.0
// Flat pale ground is where the rings have nothing to hide behind, so ease
// the shimmer out as a pixel approaches white.  Modest: at 0.55 this removed
// the bands from exactly the surfaces a 3D world is mostly made of, which
// read on hardware as no colour at all.
#define SHIMMER_WHITE_FADE 0.30
#define LIGHT_RANGE 0.6
#define FILM_NOISE_AMOUNT 0.5
#define REFLECT_FLOOR 0.03
#define SHADOW_OPACITY 0.30
// Fraction of the engine's shadow offset this pass uses. See the note at
// the sample below.
#define SHADOW_REACH 0.42

float hash21(vec2 p)
{
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float luma(vec3 c)
{
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 pc)
{
    vec4 src = Texel(tex, tc);
    vec3 col = src.rgb;

    float ps = max(pixelScale, 1.0);
    vec2 gbPix = pc / ps;
    vec2 gbTexel = (1.0 / love_ScreenSize.xy) * ps;

    vec2 lightPos = deckLight;

    // ---- screen-space drop shadow, away from the light ----
    // Read the frame back along the shadow direction.  Where that sample is
    // darker than this one, something dark stands between here and the
    // light, so this pixel sits in its shadow.  Only darkening, never
    // lightening: a shadow cannot add light.
    if (deckShadowAmt > 0.0) {
        // Shortened hard.  The engine's 3.45px offset is tuned for dark GB
        // pixels floating over a backing plate; here it lands a glyph-sized
        // distance away on a glyph-dense page, so the shadow of one letter
        // covers the next and the whole page reads as doubled text rather
        // than as anything lit.  Captured and compared against the same page
        // with this pass disabled, which is how the doubling was spotted.
        vec2 shOff = deckShadowOff * SHADOW_REACH;
        vec3 behind = Texel(tex, tc - shOff * gbTexel).rgb;
        float here = luma(col);
        float there = luma(behind);
        // 'cast' is a GLSL reserved word -- it compiles nowhere.
        //
        // Weighted by how dark the OCCLUDER is and how bright THIS pixel is,
        // not by the difference between them. The difference alone traces
        // every edge in the frame, so on a menu -- black glyphs on white --
        // it drew a grey copy of every letter offset from the letter, which
        // reads as doubled text rather than as a shadow.
        //
        // A shadow only ever falls on a lit surface, and only ever from
        // something darker than it. Both terms are needed: drop either and
        // the ghost comes back.
        float occl = clamp((1.0 - there) * here, 0.0, 1.0);
        occl *= smoothstep(0.10, 0.55, occl);
        col = mix(col, col * 0.66, occl * SHADOW_OPACITY * deckShadowAmt);
    }

    float aspect = love_ScreenSize.x / love_ScreenSize.y;
    vec2 p = vec2(tc.x * aspect, tc.y);
    vec2 lp = vec2(lightPos.x * aspect, lightPos.y);
    float d = distance(p, lp);
    float lum = luma(src.rgb);

    // ---- rainbow shimmer (quarter-wave-plate bands) ----
    if (deckShimmer > 0.0) {
        float film = vnoise(gbPix * 0.06 + vec2(7.3, 2.9) + time * 0.01);
        float gammaEff = (260.0 + 620.0 * SHIMMER_SPREAD * (d / LIGHT_RANGE))
                       * (1.0 + FILM_NOISE_AMOUNT * (film - 0.5));
        float ph = 4.0 * PI * gammaEff;

        vec3 rb = vec3(0.0);
        float cw;
        cw = cos(ph / 400.0); rb += cw * cw * vec3(0.15, 0.00, 0.50);
        cw = cos(ph / 450.0); rb += cw * cw * vec3(0.00, 0.10, 1.00);
        cw = cos(ph / 500.0); rb += cw * cw * vec3(0.00, 0.80, 0.40);
        cw = cos(ph / 550.0); rb += cw * cw * vec3(0.20, 1.00, 0.00);
        cw = cos(ph / 600.0); rb += cw * cw * vec3(1.00, 0.60, 0.00);
        cw = cos(ph / 650.0); rb += cw * cw * vec3(1.00, 0.10, 0.00);
        cw = cos(ph / 700.0); rb += cw * cw * vec3(0.70, 0.00, 0.00);
        rb /= vec3(3.05, 2.60, 1.90);

        float att = 1.0 - smoothstep(0.0, LIGHT_RANGE, d);
        float refl = max(lum, REFLECT_FLOOR);
        // roll off towards white: 1.0 at mid tones, SHIMMER_WHITE_FADE at 1.0
        refl *= mix(1.0, 1.0 - SHIMMER_WHITE_FADE, smoothstep(0.62, 0.98, lum));
        vec3 shimmer = (rb - vec3(luma(rb))) * SHIMMER_CHROMA_GAIN
                     * src.rgb * src.rgb * refl * att;
        col += shimmer * SHIMMER_INTENSITY * deckShimmer;
    }

    // ---- specular glare, on top, as a front-surface reflection ----
    if (deckGlare > 0.0) {
        float g = GLARE_INTENSITY
                * exp(-d * d / (2.0 * GLARE_SIGMA * GLARE_SIGMA));
        col += vec3(g * deckGlare);
    }

    return vec4(col, src.a) * color;
}
]]

Overlay.SHADER_SRC = SHADER_SRC

local shader = nil      -- nil = untried, false = failed
local failure = nil

function Overlay.shader()
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

function Overlay.status()
  if shader == false then return failure or "ERROR" end
  return nil
end

-- Reset between tests; the compiled shader is bound to a graphics context.
function Overlay.reset()
  shader, failure = nil, nil
end

return Overlay
