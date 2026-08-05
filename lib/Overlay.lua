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
// The frame as it was BEFORE the TV/RF and CRT passes ran, and whether there
// is one. See the shadow block for why the shadow must be cast from this and
// not from what is on screen.
extern Image deckClean;
extern number deckHasClean;
// The barrel strength the TV/RF pass is bending the picture by, already scaled
// by its own dry/wet mix. Zero when that pass is off. The shadow is warped by
// exactly this so it lies UNDER the same glass as the picture.
extern number deckCurve;

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
// How much of the picture's barrel the FRONT-SURFACE reflection follows.
// The shadow is behind the glass and uses the full curve; the glare and the
// shimmer are on the glass and use this fraction of it. See the note at rtc.
#define REFLECT_BOW 0.45
// How much deeper than the picture surface the drop shadow's plane sits, as a
// fraction of the glass's own deflection. This is what makes the shadow SLIDE
// relative to its sprite across a curved screen instead of bowing with it --
// see the note in the shadow block. Zero would put both planes at the same
// depth, which is what "the shadow does not move with the curve" looked like.
#define GLASS_PARALLAX 0.40
// Ceiling on that slide, as a FRACTION of the shadow's own throw. Without a
// cap the corners detach the shadow from its sprite entirely (the deflection
// reaches 33px against a 1.45px throw). But the cap must also stay BELOW the
// throw, and that is the harder lesson: at 3.0 the glass displaced the shadow
// three times further than the gyro ever moves it, so the shadow sat at a big
// static curve-driven offset with the tilt as a small wobble on top -- and it
// read as not following the gyro at all, which is exactly what was reported.
//
// The gyro is the PRIMARY driver here; the glass is a secondary bias on it.
// Anything at or above 1.0 inverts that and breaks the whole point of the mod.
#define GLASS_SLIDE_MAX 0.6
// How hard the glass SWINGS the shadow's direction, in radians per unit of
// deflection. This is where the curve gets to move the shadow a lot without
// fighting the gyro for it.
//
// Translation could not do the job: the gyro throw is only 1.45px, so any
// slide big enough to be obvious was bigger than the tilt itself and the
// shadow read as stuck (that was GLASS_SLIDE_MAX 3.0). Rotation composes
// instead of competing -- the gyro sets the base direction, the glass leans
// it, and both are visible because they are the same kind of motion on the
// same vector.
//
// Physically it is the apparent light direction shifting as you look through
// curved glass away from its axis: dead centre you look straight through and
// nothing leans, at the edges you look through it at an angle. At RF CURVE
// HIGH this reaches about 33 degrees at the screen edge and ~10 at 80% across.
#define GLASS_SWING 18.0

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

// The TV/RF pass's barrel transform, repeated here rather than shared, because
// the two shaders are separate programs and a uniform cannot carry a function.
// It MUST stay identical to RfTv's -- the whole point is that the shadow lands
// under the same glass the picture is behind, and two nearly-equal warps would
// slide the shadow off its own sprite. The test suite compares the two.
vec2 curved(vec2 tc, float k)
{
    if (k <= 0.0) return tc;
    vec2 n = (tc - 0.5) * 2.0;
    float f = 1.0 + k * dot(n, n);
    return 0.5 + n * f * 0.5;
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
        //
        // ---- cast from the CLEAN frame, not from what is on screen ----
        //
        // The occlusion test below asks "is the thing between me and the light
        // darker than me". Once the TV/RF and CRT passes exist, `tex` is no
        // longer the game's picture -- it is the picture after scanlines, dot
        // crawl and barrel distortion. Asking that question of THAT image
        // gives the wrong answer three separate ways:
        //
        //   * every dark scanline is darker than the lit line above it, so it
        //     reads as an occluder and the shadow appears along the SCAN
        //     STRUCTURE. The shadow pattern then belongs to RF SCAN, not to
        //     where the light is.
        //   * barrel distortion means a fixed offset in SCREEN space is a
        //     varying offset in PICTURE space, so the throw stretches and
        //     shortens across the frame and changes whenever RF CURVE does.
        //   * dot crawl adds high-frequency luma that trips the test at random.
        //
        // All three read as "the RF settings move the drop shadow", which is
        // exactly what they do. So the test is made against the frame as it
        // was BEFORE those passes. The darkening is still applied to `col` --
        // the shadow falls on what you can actually see -- but WHERE it falls
        // and WHICH WAY it points now come only from the gyro and the game's
        // own picture, which is the whole point of this mod.
        //
        // deckHasClean is 0 when nothing ran ahead of us, in which case the
        // clean frame and `tex` are the same image and this costs one branch.
        // ---- but it DOES travel with the glass ----
        //
        // Not responding to the scan structure is not the same as ignoring the
        // GEOMETRY. RF CURVE is a sheet of curved glass over the picture, and
        // a shadow that stays put while everything it falls on bows away from
        // it is pasted on top rather than under the glass -- which is what it
        // looked like when the fix above first landed.
        //
        // So the clean frame is read through the SAME barrel transform the RF
        // pass is applying. The offset is applied in that warped space, so the
        // throw stays constant in PICTURE terms -- a shadow is always the same
        // distance from its sprite -- while its position on screen swings side
        // to side with the curve, exactly as the sprite it belongs to does.
        //
        // The two effects are independent on purpose: which way the shadow
        // points is the gyro's business, and where the glass puts it is the
        // curve's. Turning RF CURVE up moves it further; turning the console
        // still turns the shadow.
        // ---- and the glass has THICKNESS, so it parallaxes ----
        //
        // Warping the shadow and its sprite by the SAME amount was not enough,
        // and the reason is worth writing down: they then move together, so
        // relative to the text the shadow never moves at all. Everything bows,
        // nothing slides, and it reads exactly as it did before -- which is
        // what "still not moving with the curve" meant.
        //
        // A drop shadow is not on the same plane as the thing casting it. It
        // lands BEHIND it. Under a curved sheet of glass, two planes at
        // different depths are displaced by different amounts -- that is
        // parallax, and it is the whole reason a curved screen reads as having
        // depth rather than as a bent picture. So the shadow's plane is warped
        // by MORE than the surface's: the extra is a fraction of however far
        // the glass moved this point, which is zero at the centre and grows
        // towards the edges, exactly as the deflection does.
        //
        // Measured at RF CURVE HIGH (k = 0.088) on a 1024px window: the glass
        // moves a point 9.7px at 80% across and 33px at 95%. At GLASS_PARALLAX
        // the shadow slides about one shadow-width out from under its sprite
        // by 80%, and further at the edge. It stays anchored to the SAME
        // sprite -- the lit test still reads the surface plane -- so it slides
        // rather than detaching and shadowing something else.
        vec2 shOff = deckShadowOff * SHADOW_REACH;
        vec3 hereRgb, behind;
        if (deckHasClean > 0.5) {
            vec2 ctc = curved(tc, deckCurve);
            vec2 glass = (ctc - tc) * GLASS_PARALLAX;
            // The deflection grows without limit towards the corners -- at RF
            // CURVE HIGH it reaches 33px, against a shadow throw of 1.45px --
            // and a "shadow" sampled 33px from its sprite is not that sprite's
            // shadow at all, it is a dark smear borrowed from somewhere else.
            // So the slide is capped at a few times the throw: enough to read
            // clearly as the shadow sliding out from under the thing casting
            // it, never enough to let go of it. Measured across the screen the
            // slide ramps up through the mid-field and then holds, which is
            // also what a real shadow does once the glass angle stops
            // steepening.
            // ---- the glass leans the shadow as well as sliding it ----
            // defl is how far the glass moved this point, and which way. Its
            // horizontal part swings the shadow; the vertical part would fight
            // the gyro's own up/down lean, so it is left alone.
            vec2 defl = ctc - tc;
            float ang = defl.x * GLASS_SWING;
            float ca = cos(ang), sa = sin(ang);
            shOff = vec2(shOff.x * ca - shOff.y * sa,
                         shOff.x * sa + shOff.y * ca);

            float throwLen = length(shOff * gbTexel);
            float maxSlide = throwLen * GLASS_SLIDE_MAX;
            float glassLen = length(glass);
            if (glassLen > maxSlide && glassLen > 1e-6) {
                glass *= maxSlide / glassLen;
            }
            hereRgb = Texel(deckClean, ctc).rgb;
            behind  = Texel(deckClean, ctc + glass - shOff * gbTexel).rgb;
        } else {
            hereRgb = col;
            behind  = Texel(tex, tc - shOff * gbTexel).rgb;
        }
        float here = luma(hereRgb);
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

    // ---- the light bows with the glass too, but LESS ----
    //
    // The glare and the shimmer are a reflection off the FRONT of the glass;
    // the picture is behind it. A curved front surface does bend the hotspot
    // and the interference rings, so they should not stay perfectly flat while
    // everything under them bows -- that reads as a sticker on the screen.
    // But they should not bow by the FULL amount either: the picture is seen
    // through the thickness of the glass and travels further than a reflection
    // off its surface does.
    //
    // Hence a fraction. REFLECT_BOW is the one number here that is a judgement
    // rather than a measurement -- it is "a bit", chosen so the hotspot
    // visibly follows the curve without swimming away from the light position
    // the gyro is driving. Where the shadow uses deckCurve in full, this uses
    // part of it, and with RF CURVE off both are zero and nothing moves.
    vec2 rtc = curved(tc, deckCurve * REFLECT_BOW);
    vec2 bowPix = (rtc * love_ScreenSize.xy) / ps;

    float aspect = love_ScreenSize.x / love_ScreenSize.y;
    vec2 p = vec2(rtc.x * aspect, rtc.y);
    vec2 lp = vec2(lightPos.x * aspect, lightPos.y);
    float d = distance(p, lp);
    float lum = luma(src.rgb);

    // ---- rainbow shimmer (quarter-wave-plate bands) ----
    if (deckShimmer > 0.0) {
        float film = vnoise(bowPix * 0.06 + vec2(7.3, 2.9) + time * 0.01);
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
