-- The electron-beam pass: the phosphor mask, the beam that lights it, and the
-- rolling scan that draws it.
--
-- Additive with the TV/RF pass rather than an alternative to it, and for the
-- same reason the two are separate rows: RF models the SIGNAL arriving at the
-- set, this models the TUBE the signal is painted onto.  A real television
-- does both, and either is useful without the other -- RF alone is a clean
-- flat CRT-ish picture, mask alone is a modern panel pretending to be a tube.
--
-- ------- what this is a reimplementation OF
--
-- Three references, none of them linked against, none copied from:
--
--   crt-royale        libretro/slang-shaders, crt/shaders/crt-royale
--                     (c) TroggleMonkey, GPLv2+.  The beam model: scanline
--                     width varying with brightness.
--   crt-sony-megatron libretro/slang-shaders, hdr/shaders/crt-sony-megatron
--                     (c) Major Pain The Cactus.  The ORDER: brighten first,
--                     then mask -- which is what makes a mask cost brightness
--                     you added rather than brightness you had.
--   crt-beam-simulator github.com/blurbusters/crt-beam-simulator, MIT,
--                     (c) Mark Rejhon / Timothy Lottes.  The rolling scan.
--
-- ------- the beam, from crt-royale
--
-- The one idea worth having from royale is that a scanline is not a fixed
-- dark stripe: the beam spot GROWS with the signal, so a bright line is fat
-- and nearly touches its neighbours while a dim line is thin with black
-- either side.  That is why a royale picture looks lit rather than screened,
-- and it is the difference between this and the RF pass's flat scanlines.
--
--   sigma = beam_min_sigma + (beam_max_sigma - beam_min_sigma)
--                          * pow(colour, beam_spot_power)
--
-- with royale's own defaults, kept below: min 0.02, max 0.3, power 0.33.  The
-- profile is a generalised gaussian whose shape also opens with brightness
-- (min_shape 2.0 -> max_shape 4.0, shape_power 0.25): 2.0 is a true gaussian,
-- higher is flatter-topped, so a bright line is not merely wider but squarer.
--
-- ------- the mask, from megatron and royale
--
-- Three geometries, which is what the glass actually was:
--   GRILLE  vertical RGB stripes, uninterrupted (Trinitron)
--   SLOT    stripes broken into staggered slots, offset every other row
--   SHADOW  a triad of round dots on a hex lattice
--
-- Megatron's contribution is not the geometry, it is the ORDER.  A mask
-- multiplies two thirds of the picture towards black, so applying it to an
-- already-correct image just makes a dim image.  A real tube runs the gun
-- harder to compensate.  So: gain FIRST, then mask.  That is the whole reason
-- MASK_GAIN exists below, and why the mask rungs do not simply darken.
--
-- ------- the rolling scan, from crt-beam-simulator
--
-- A CRT lights each line for a moment, not for the whole frame.  Simulating
-- that needs the DISPLAY to refresh several times per simulated tube frame --
-- you draw a different slice of the cycle each refresh, and the eye
-- integrates them back into a whole picture with less motion blur.
--
-- The row names the TUBE, not the ratio, and the ratio is measured: see the
-- note above CrtBeam.ROLL for why that way round.  MEASURED on this hardware:
-- ~88 presents per second against a 90 Hz panel, so a 60 Hz tube is N=1.47
-- and buys a 32% blur reduction.  That is modest but real, and 60 Hz is what
-- an actual tube ran at -- so it flickers no more than the thing it imitates.
--
-- This is only possible because the engine keeps LOGIC on a fixed step
-- (src/core/FixedStep.STEP is 1/60 exactly) and caps only the RENDER
-- (src/core/FrameCap's header says "Render-only").  The same 60 Hz game frame
-- is therefore presented more than once, and those repeats ARE the subframes.
-- Without that separation every present would be new content, N would be 1,
-- and there would be nothing to roll.
--
-- The row still reports what it is getting -- as a blur-reduction percentage,
-- measured on the machine in your hands -- in the same spirit as the SENSOR
-- row saying ASLEEP.  And like every other row here it has an OFF, which is
-- its default: nothing about this is on unless it is asked for.
--
-- Energy is conserved: each pixel emits its whole brightness over one tube
-- cycle, spread across however many refreshes that cycle covers, so the
-- average over a cycle is the original picture.  That is what makes it a beam
-- simulation rather than black-frame insertion.  Working in LINEAR light is
-- not optional here -- it is what the reference means by its GAMMA constant,
-- and doing the arithmetic in sRGB is what produces the horizontal banding
-- their HOWTO spends most of its length on.

local V = ...
local Settings = V.require("Settings")

local CrtBeam = {}

local SHADER_SRC = [[
// Every uniform declared here MUST be referenced below.  A GLSL compiler
// removes one that is not, and LOVE's send() then throws on a name the
// program does not have -- which took this whole pass out silently, because
// the failure looks exactly like the pass being switched off.  `time` was
// declared and never used, and that was the bug.  The suite now diffs the
// externs against the body so it cannot happen again.
extern number pixelScale;
extern number frameIndex;
extern number beamMask;     // 0 off, 1 grille, 2 slot, 3 shadow,
                            // 4 pvm, 5 trinitron, 6 dot
extern number beamMaskAmt;
extern number beamPitch;    // triad pitch in SCREEN pixels
extern number beamMono;     // 1 = black and white
extern number beamSat;      // saturation, 1 = unchanged
extern number beamContrast; // contrast, 1 = unchanged
extern number beamScan;     // royale beam profile strength
extern number beamGlow;     // halation + diffusion
extern vec3 beamGlowTint;   // the colour of the phosphor's own light
extern number beamEdge;     // vignette + edge rolloff
extern number beamCurve;    // the RF pass's barrel k, so the edges bow with it
extern number beamEdgeSoft; // how gradual the falloff is; 1.0 = the reference
extern number beamRoll;     // refreshes per tube frame; 0 = off

#define PI 3.14159265359

// crt-royale, bind-shader-params.h defaults
#define BEAM_MIN_SIGMA 0.02
#define BEAM_MAX_SIGMA 0.30
#define BEAM_SPOT_POWER 0.33
#define BEAM_MIN_SHAPE 2.0
#define BEAM_MAX_SHAPE 4.0
#define BEAM_SHAPE_POWER 0.25
#define HALATION_WEIGHT 0.10
#define DIFFUSION_WEIGHT 0.075
// The gun runs harder to pay for the mask -- see the megatron note in the
// header. Without this a mask is just a brightness cut.
#define MASK_GAIN 1.9
// crt-beam-simulator
#define BEAM_GAMMA 2.4
#define GAIN_VS_BLUR 0.7
// Contrast pivots about middle grey rather than about black. A control that
// scales from zero is a BRIGHTNESS control wearing the wrong name: it makes
// the whole picture lighter or darker and leaves the ratio between light and
// dark exactly where it was. Contrast is the ratio, so the arithmetic has to
// push away from a fixed middle. 0.18 is photographic middle grey, in linear
// light, which is where this pass already is.
#define CONTRAST_PIVOT 0.18

float srgb2lin(float c) { return pow(max(c, 0.0), BEAM_GAMMA); }
float lin2srgb(float c) { return pow(max(c, 0.0), 1.0 / BEAM_GAMMA); }
vec3 srgb2lin3(vec3 c) { return vec3(srgb2lin(c.r), srgb2lin(c.g), srgb2lin(c.b)); }
vec3 lin2srgb3(vec3 c) { return vec3(lin2srgb(c.r), lin2srgb(c.g), lin2srgb(c.b)); }

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// ---- the edges of the tube ----
//
// TWO things, because a real tube dims towards the edges for two unrelated
// reasons and one term cannot do both:
//
//   the VIGNETTE is the gun working at an angle. It is a broad, smooth
//   falloff over the whole picture, strongest in the corners because that is
//   where the beam is furthest off-axis. `1 - k*r^4` is the famicom RF
//   reference's own shape (sdl_display.cpp: vig = 1.0 - 0.18*r2*r2), kept.
//
//   the ROLLOFF is the last few percent of the picture, where the phosphor
//   stops and the shadow of the bezel and the curve of the glass take over.
//   It is narrow and much steeper, and it is the part that actually reads as
//   "this is a tube" rather than as a darkened photograph -- a vignette alone
//   just looks like a lens.
//
// Deliberately independent of RF CURVE, which carries its own vignette tied
// to its barrel distortion: that one belongs to the RF pass's geometry and
// this one is the tube's own. With both on they stack, which is correct --
// they are two passes modelling two things -- but it is why this has its own
// row rather than being folded into the curve.
// `k` is the barrel constant the TV/RF pass is bending the picture by. The
// vignette is evaluated in the PICTURE's coordinates rather than the screen's,
// so the dark border follows the bowed edge of the glass instead of darkening
// a flat rectangle over a curved image -- which reads as a frame sitting in
// front of the tube rather than as the tube's own falloff.
//
// This runs AFTER the curve (the RF pass is a separate, earlier pass) and
// BEFORE the light, which is the last thing over everything.
vec2 curved(vec2 tc, float k)
{
    if (k <= 0.0) return tc;
    vec2 n = (tc - 0.5) * 2.0;
    float f = 1.0 + k * dot(n, n);
    return 0.5 + n * f * 0.5;
}

// `soft` is separate from `amt` on purpose, because they are different
// questions. `amt` is HOW DARK the edges get; `soft` is HOW FAR IN the
// darkening reaches and how gradually it arrives. A player who wants a gentle
// wash over the outer third is not asking for a darker corner -- they are
// asking for the same darkness spread over more of the picture, and one
// strength dial cannot say that. 1.0 is the reference's own shape both ways.
float edgeFall(vec2 tcIn, float amt, float k, float soft)
{
    if (amt <= 0.0) return 1.0;
    float sf = max(soft, 0.05);
    vec2 tc = curved(tcIn, k);
    vec2 n = (tc - 0.5) * 2.0;
    float r2 = dot(n, n);

    // The exponent is what decides REACH. r^4 keeps the falloff in the
    // corners, which is the famicom reference's shape; easing towards r^2
    // spreads the same darkening inwards across the whole picture, which is
    // what "softer" means for a vignette. Past 1.0 the shape opens; below it
    // the corners tighten instead.
    float shape = mix(r2 * r2, r2, clamp(sf - 1.0, 0.0, 1.0));
    shape = mix(shape, r2 * r2 * r2, clamp(1.0 - sf, 0.0, 1.0));
    float vig = 1.0 - 0.18 * amt * shape;

    // distance into the picture from the nearest edge, in fractions of the
    // screen. smoothstep rather than a hard step so it cannot alias, and the
    // width scales with `soft` so the bezel rolloff feathers with everything
    // else rather than staying a hard line inside a soft vignette.
    vec2 d = min(tc, vec2(1.0) - tc);
    float edge = min(d.x, d.y);
    float roll = smoothstep(0.0, max(0.045 * sf, 0.002), edge);
    roll = mix(1.0, roll, clamp(amt, 0.0, 1.0));

    return max(0.0, vig * roll);
}

// ---- the phosphor mask ----
// Returns a per-channel multiplier. Normalised so a full triad averages to
// 1.0 BEFORE MASK_GAIN, which is what lets the gain mean "how much harder the
// gun runs" rather than "how bright I felt like making it".
// `pitch` is the triad width in SCREEN pixels, not source ones: a mask finer
// than the panel can resolve is a grey wash plus moire, so it has to be
// expressed in the pixels that actually exist. It is a uniform rather than a
// constant because pitch is the single thing that separates one real tube
// from another -- a BVM and a consumer set can carry the SAME geometry and
// still look nothing alike, because one has 0.25mm slots and the other 0.8mm.
vec3 mask(vec2 px, float kind, float pitch)
{
    if (kind < 0.5) return vec3(1.0);
    // (see edgeFall below for the vignette; it is not part of the mask)

    float cell = px.x / pitch;
    float slot = fract(cell) * 3.0;      // 0..3 across one RGB triad

    if (kind < 1.5) {
        // GRILLE: uninterrupted vertical stripes
        vec3 m = vec3(step(slot, 1.0),
                      step(1.0, slot) * step(slot, 2.0),
                      step(2.0, slot));
        return m * 3.0;
    }
    if (kind < 2.5) {
        // SLOT: the same stripes, broken and staggered every other row. The
        // half-triad shift on alternate slot rows is the whole visual
        // signature -- without it this is just GRILLE with gaps.
        float row = floor(px.y / (pitch * 2.0));
        float shifted = fract(cell + 0.5 * mod(row, 2.0)) * 3.0;
        vec3 m = vec3(step(shifted, 1.0),
                      step(1.0, shifted) * step(shifted, 2.0),
                      step(2.0, shifted));
        // the gap between slots, vertically
        float gap = step(0.12, fract(px.y / (pitch * 2.0) * 2.0));
        return m * 3.0 * mix(0.55, 1.0, gap);
    }
    if (kind < 3.5) {
        // SHADOW: round dots on a staggered lattice, which is a hex packing
        float row = floor(px.y / (pitch * 1.732));
        vec2 c = vec2(fract(cell + 0.5 * mod(row, 2.0)),
                      fract(px.y / (pitch * 1.732)));
        float slot2 = c.x * 3.0;
        vec3 m = vec3(step(slot2, 1.0),
                      step(1.0, slot2) * step(slot2, 2.0),
                      step(2.0, slot2));
        float d = abs(c.y - 0.5) * 2.0;
        return m * 3.0 * smoothstep(1.0, 0.35, d);
    }
    if (kind < 4.5) {
        // PVM: the professional aperture grille. Same stripes as GRILLE, but
        // with a GUARD BAND -- unlit glass between one triad and the next.
        // A broadcast monitor does not run its phosphor edge to edge, and
        // that black between the triads is most of why a PVM picture reads
        // as having bite rather than as being bright: the black is actually
        // black, so the lit stripe has something to be brighter THAN.
        //
        // GUARD is the lit fraction of each stripe's third. The 3/GUARD
        // renormalisation is what keeps a full triad averaging 1.0 before
        // MASK_GAIN, so the guard band costs contrast rather than light --
        // which is the whole point of it.
        float g = 0.78;
        vec3 m = vec3(step(slot, g),
                      step(1.0, slot) * step(slot, 1.0 + g),
                      step(2.0, slot) * step(slot, 2.0 + g));
        return m * (3.0 / g);
    }
    if (kind < 5.5) {
        // TRINITRON: an aperture grille plus its DAMPER WIRES.
        //
        // A grille is loose vertical strips of foil with nothing holding them
        // sideways, so Sony strung one or two fine horizontal wires across it
        // to stop them ringing. Those wires sit in front of the phosphor and
        // cast a faint shadow all the way across the picture -- one wire on a
        // small set, two on a large one. It is the single most recognisable
        // thing about a Trinitron, it is the thing people either love or send
        // the set back over, and it is why this is its own rung rather than a
        // switch on GRILLE.
        vec3 m = vec3(step(slot, 1.0),
                      step(1.0, slot) * step(slot, 2.0),
                      step(2.0, slot)) * 3.0;
        // Two wires, at the thirds -- the large-set arrangement. Placed by
        // FRACTION of the picture rather than in pixels, because the wire is
        // a fixed feature of the tube and does not move when the window does.
        float wire = max(pitch * 0.5, 1.0);
        float d1 = abs(px.y - love_ScreenSize.y * 0.3333);
        float d2 = abs(px.y - love_ScreenSize.y * 0.6667);
        float shade = min(smoothstep(0.0, wire, d1), smoothstep(0.0, wire, d2));
        return m * mix(0.45, 1.0, shade);
    }
    // DOT: the fine-pitch shadow mask of a high-end set -- the same hex
    // lattice as SHADOW, but the dots are round in BOTH axes rather than
    // banded only vertically. That is what a mask actually looks like once
    // the pitch is fine enough that you stop reading it as stripes, and it
    // is the reason this is a separate rung: at FINE pitch it dissolves into
    // colour rather than into a pattern, which SHADOW never quite does.
    float rowd = floor(px.y / (pitch * 1.732));
    vec2 cd = vec2(fract(cell + 0.5 * mod(rowd, 2.0)),
                   fract(px.y / (pitch * 1.732)));
    float s3 = cd.x * 3.0;
    vec3 m = vec3(step(s3, 1.0),
                  step(1.0, s3) * step(s3, 2.0),
                  step(2.0, s3));
    vec2 dv = vec2(fract(s3) - 0.5, cd.y - 0.5) * 2.0;
    float r = length(dv);
    // A round dot lights less of its cell than a vertical band does, so the
    // triad would average below 1.0 and the rung would read as "darker" when
    // what changed was the SHAPE. 1.55 is the ratio of the two coverages and
    // puts it back on equal terms with the rungs above.
    return m * 3.0 * 1.55 * smoothstep(1.0, 0.30, r);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 pc)
{
    vec3 src = Texel(tex, tc).rgb;
    if (beamMask < 0.5 && beamScan <= 0.0 && beamGlow <= 0.0
        && beamEdge <= 0.0 && beamRoll <= 0.0
        && beamMono < 0.5
        && abs(beamSat - 1.0) < 0.001 && abs(beamContrast - 1.0) < 0.001)
        return vec4(src, 1.0) * color;

    float ps = max(pixelScale, 1.0);
    vec2 gbPix = pc / ps;
    vec3 lin = srgb2lin3(src);

    // ---- 0. the controls on the front of the set ----
    //
    // FIRST, and not last, because that is where they were. Colour and
    // contrast are decoder and gun-drive controls: they act on the signal on
    // its way to the phosphor, so everything below -- the glow, the beam
    // profile, the mask -- sees the picture you actually asked for. Turning
    // contrast up makes the glow bloom harder, which is what a real set does
    // and would not happen if these were a grade applied over the top.
    //
    // In LINEAR light, like everything else in this pass. Saturation done in
    // sRGB pulls saturated colours dark as it goes, because the luma it
    // mixes towards is not the luma the eye is using.
    if (beamMono > 0.5) {
        lin = vec3(luma(lin));
    } else {
        // Past 1.0 this extrapolates AWAY from grey rather than clamping, so
        // MAX oversaturates the way a set with its colour control wound up
        // does -- reds bloom and detail in them is lost. That is the effect,
        // not a defect of it.
        lin = max(mix(vec3(luma(lin)), lin, beamSat), vec3(0.0));
    }
    lin = max((lin - CONTRAST_PIVOT) * beamContrast + CONTRAST_PIVOT,
              vec3(0.0));

    // ---- 1. halation and diffusion (royale) ----
    // Light scattering forward through the glass and sideways in the phosphor.
    // Cheap two-radius blur; the point is a soft bloom around bright areas,
    // and a wide one is what stops a mask reading as dirt on the screen.
    if (beamGlow > 0.0) {
        // Ring radii, in screen pixels. The far ring used to sit at 4.0*ps --
        // 20 screen pixels at this upscale -- sampled by only FOUR taps at
        // fixed angles. That is not a blur: four point samples that far out
        // are four DISPLACED COPIES of the picture, and at GLOW HIGH they
        // carry 0.2 weight each, which is a visible ghost. It reads worst
        // with RF CURVE on, because the barrel moves the picture under a ring
        // that does not move with it, so the copies land on content that no
        // longer lines up.
        //
        // Fixed by making the ring an actual ring: 8 taps 45 degrees apart,
        // the two rings rotated 22.5 degrees against each other so their taps
        // interleave rather than stack into the same eight directions, and the
        // far radius pulled in to 2.5*ps. Sixteen reads instead of eight.
        vec2 t1 = 1.5 * ps / love_ScreenSize.xy;
        vec2 t2 = 2.5 * ps / love_ScreenSize.xy;
        vec3 near = vec3(0.0), far = vec3(0.0);
        float nearW = 0.0, farW = 0.0;
        for (int i = 0; i < 8; i++) {
            float a = float(i) * (PI * 0.25);
            vec2 dn = vec2(cos(a), sin(a));
            vec2 df = vec2(cos(a + PI * 0.125), sin(a + PI * 0.125));
            vec2 sn = tc + dn * t1;
            vec2 sf = tc + df * t2;
            // A tap that leaves the picture is DROPPED, not clamped. Outside
            // the tube RfTv writes black, and clamping pulls that black (or
            // the border pixel, smeared) inward as a dark rim that tracks the
            // curve. Renormalising by the taps that survived keeps the glow
            // the same brightness at the edge as in the middle.
            if (sn.x >= 0.0 && sn.x <= 1.0 && sn.y >= 0.0 && sn.y <= 1.0) {
                near += srgb2lin3(Texel(tex, sn).rgb); nearW += 1.0;
            }
            if (sf.x >= 0.0 && sf.x <= 1.0 && sf.y >= 0.0 && sf.y <= 1.0) {
                far += srgb2lin3(Texel(tex, sf).rgb); farW += 1.0;
            }
        }
        near /= max(nearW, 1.0); far /= max(farW, 1.0);
        // The colour of the light the coating gives back.
        //
        // Normalised by its OWN luma before it is applied, so choosing a
        // colour changes the HUE of the glow and not its strength. Without
        // that, a warm tint would read as "less glow" and a cool one as
        // "more", and the colour row would quietly be a second brightness
        // row -- which is exactly the kind of dial that makes a picture
        // impossible to tune, because two rows would be fighting over one
        // quantity.
        vec3 tint = beamGlowTint / max(luma(beamGlowTint), 1e-3);
        lin += (far * HALATION_WEIGHT + near * DIFFUSION_WEIGHT)
             * beamGlow * tint;
    }

    // ---- 2. the beam profile (royale) ----
    // Distance from this pixel to the centre of its scanline, in scanlines.
    // The width follows the SIGNAL, which is the whole idea: bright lines
    // swell until they nearly touch, dim ones stay thin with black between.
    if (beamScan > 0.0) {
        float dist = abs(fract(gbPix.y) - 0.5) * 2.0;
        vec3 c = clamp(lin, 0.0, 1.0);
        vec3 sigma = vec3(BEAM_MIN_SIGMA)
                   + (BEAM_MAX_SIGMA - BEAM_MIN_SIGMA)
                     * pow(c, vec3(BEAM_SPOT_POWER));
        vec3 shape = vec3(BEAM_MIN_SHAPE)
                   + (BEAM_MAX_SHAPE - BEAM_MIN_SHAPE)
                     * pow(c, vec3(BEAM_SHAPE_POWER));
        // generalised gaussian: exp(-(|d|/sigma)^shape)
        vec3 w = exp(-pow(vec3(dist * 0.5) / max(sigma, vec3(1e-4)), shape));
        lin *= mix(vec3(1.0), w, beamScan);
    }

    // ---- 3. the mask, AFTER the gain (megatron) ----
    if (beamMask >= 0.5) {
        vec3 m = mask(pc, beamMask, max(beamPitch, 1.0));
        lin *= mix(vec3(1.0), m * (MASK_GAIN / 3.0), beamMaskAmt);
    }

    // ---- 3b. the edges of the tube ----
    // After the mask, because the bezel shadows the mask too -- a tube does
    // not get brighter at the edge just because the phosphor is still there.
    // Before the rolling scan, which is a temporal thing and should not have
    // its energy budget bent by a spatial one.
    if (beamEdge > 0.0) {
        lin *= edgeFall(tc, beamEdge, beamCurve, beamEdgeSoft);
    }

    // ---- 4. the rolling scan (crt-beam-simulator) ----
    // Each pixel emits its whole brightness once per tube cycle, over a window
    // whose LENGTH is set by how bright it is -- a dim pixel flashes briefly,
    // a bright one stays lit most of the cycle. Summed across the refreshes in
    // one cycle this returns the original picture exactly, which is what makes
    // it a beam rather than black-frame insertion.
    if (beamRoll > 0.0) {
        float fph = max(beamRoll, 1.0);
        // where in the tube cycle this refresh sits
        float sub = mod(frameIndex, fph);
        float winA = sub / fph;
        float winB = (sub + 1.0) / fph;
        // where in the cycle this LINE is painted (top to bottom)
        float scanPos = clamp(tc.y, 0.0, 1.0);

        float l = luma(clamp(lin, 0.0, 1.0));
        // fraction of the cycle this pixel needs to be lit for
        float need = clamp(l / GAIN_VS_BLUR, 1.0 / fph, 1.0);
        float a = scanPos - need * 0.5;
        float b = scanPos + need * 0.5;
        // wrap: the window can straddle the top of the frame
        float ov = max(0.0, min(b, winB) - max(a, winA))
                 + max(0.0, min(b + 1.0, winB) - max(a + 1.0, winA))
                 + max(0.0, min(b - 1.0, winB) - max(a - 1.0, winA));
        // emit at 1/need, integrate over the refresh's slice, renormalise so
        // the mean across the cycle is unity
        lin *= (ov / need) * fph;
    }

    return vec4(clamp(lin2srgb3(lin), 0.0, 1.0), 1.0) * color;
}
]]

CrtBeam.SHADER_SRC = SHADER_SRC

CrtBeam.MASK   = { off = 0, grille = 1, slot = 2, shadow = 3,
                   pvm = 4, trinitron = 5, dot = 6 }
CrtBeam.MASKAMT= { off = 0, grille = 0.85, slot = 0.85, shadow = 0.85,
                   pvm = 0.85, trinitron = 0.85, dot = 0.85 }

-- Triad pitch in SCREEN pixels. This is the row that decides WHICH tube a
-- geometry belongs to: a slot mask at 6px is a 1980s living-room set and the
-- same slot mask at 2px is a late broadcast monitor, and neither is a
-- different pattern. NORMAL is 3px, which at this upscale is about one and a
-- half source pixels per triad -- fine enough to read as colour rather than
-- as bars, coarse enough that the panel can still resolve it.
--
-- FINE is the honest limit rather than a rung for its own sake: below ~2
-- screen pixels a triad cannot be drawn by a panel with square pixels
-- without turning into moire, so there is nothing under it.
CrtBeam.PITCH  = { fine = 2.0, normal = 3.0, wide = 4.5, widest = 6.0 }

-- ------- the controls on the front of the set
--
-- Fine ladders rather than the OFF/LOW/NORMAL/HIGH the rest of this page
-- uses, because these are the two rows a player is genuinely tuning by eye
-- against their own panel rather than choosing a character for. Four rungs
-- would mean the right answer is usually between two of them. The labels are
-- percentages for the same reason: 100% is unmistakably "unchanged", where
-- NORMAL only means it if you already believe it.
CrtBeam.CONTRAST = {
  ["50"] = 0.50, ["60"] = 0.60, ["70"] = 0.70, ["80"] = 0.80,
  ["90"] = 0.90, ["100"] = 1.00, ["110"] = 1.10, ["120"] = 1.20,
  ["130"] = 1.30, ["140"] = 1.40, ["150"] = 1.50,
}
-- 0% is a black and white picture reached by the colour control, which is
-- how a set with a colour knob does it. CRT MONO is the separate switch, and
-- it is not the same thing: the switch is a hard mono path that survives
-- whatever this row is set to, so it can be turned on and off without losing
-- a saturation you had tuned.
CrtBeam.SAT = {
  ["0"] = 0.0, ["25"] = 0.25, ["50"] = 0.50, ["75"] = 0.75,
  ["100"] = 1.00, ["125"] = 1.25, ["150"] = 1.50, ["175"] = 1.75,
  ["200"] = 2.00,
}
CrtBeam.MONO = { off = 0, on = 1 }

CrtBeam.SCAN   = { off = 0, low = 0.35, normal = 0.7, high = 1.0 }
CrtBeam.GLOW   = { off = 0, low = 0.5, normal = 1.0, high = 2.0 }

-- ------- the colour of the glow
--
-- The light a coating gives back is not white, and which not-white it is says
-- more about the set than almost anything else on this page.
--
-- The white points are real ones. 9300K is what nearly every Japanese
-- consumer set and nearly every Trinitron left the factory at -- markedly
-- blue against sRGB's own D65, and the reason period screenshots of Japanese
-- sets look cold. 7500K is where broadcast monitors were lined up. 5500K is
-- where a set that has been on for twenty years has drifted to, and where
-- late consumer sets were deliberately put because a warm picture sells.
--
-- The three below those are not white points at all -- they are the
-- monochrome phosphors, which is what you get if the glow is coming off a
-- single-phosphor tube: P3 amber, P1 green, P11 blue. They are included
-- because this mod already has an audience for a Game Boy under glass, and a
-- green tube is the nearest thing a CRT has to that.
--
-- WHITE is the P22 colour set with no tint at all, and is the default: it is
-- the one that changes nothing.
CrtBeam.GLOWCOL = {
  white  = { 1.00, 1.00, 1.00 },
  k9300  = { 0.86, 0.94, 1.20 },
  k7500  = { 0.93, 0.97, 1.10 },
  k5500  = { 1.12, 0.99, 0.80 },
  amber  = { 1.20, 0.80, 0.28 },
  green  = { 0.40, 1.25, 0.55 },
  blue   = { 0.55, 0.75, 1.30 },
}
-- NORMAL is the famicom RF reference's own vignette coefficient, so it means
-- "as much as the measured hardware" rather than "as much as looked nice".
CrtBeam.EDGE   = { off = 0, low = 0.5, normal = 1.0, high = 2.0 }
-- How far in the darkening reaches and how gradually it arrives. NORMAL is
-- the reference's own shape; SOFT and SOFTEST spread the same darkness over
-- more of the picture rather than making the corners darker.
CrtBeam.EDGESOFT = { tight = 0.45, normal = 1.0, soft = 2.0, softest = 3.5 }

-- ------- the rolling scan, expressed as a TUBE RATE rather than a ratio
--
-- The row used to name the ratio directly (1.5X / 2X / 3X), which was the
-- wrong thing to ask a player for: the ratio that is any good depends on the
-- display, so a fixed ladder of ratios is right on exactly one machine and
-- wrong everywhere else.  What a player actually wants to choose is the TUBE
-- -- 60Hz is what a real one ran at -- and the ratio is then arithmetic:
--
--     refreshes per tube frame = measured present rate / tube rate
--
-- which scales itself.  At the Deck's 90Hz a 60Hz tube is 1.5; on a 240Hz
-- display the same choice is 4.0, which is Blur Busters' own realtime figure.
-- Nothing has to be re-tuned by hand when the hardware changes.
--
-- This works here because the engine keeps LOGIC on a fixed-step accumulator
-- and caps only the RENDER (src/core/FrameCap.lua says so in its header: the
-- cap is "Render-only").  So at a 90Hz cap the same 60Hz game frame is
-- presented 1.5 times on average, and those repeats are the subframes the
-- rolling scan needs.  Without that separation there would be nothing to
-- roll -- every present would be new content and the ratio would be 1.
--
-- 20HZ is not a tube anyone shipped, and it is on the ladder for a reason
-- that is worth writing down. On the first second or two after launch the
-- rolling scan is VISIBLE -- a bright band sweeping down the picture -- and
-- then it vanishes. Nothing turns off: the band is always there, and the
-- reason you stop seeing it is that the eye starts integrating it. The phase
-- advances once per PRESENT (frameIndex counts apply() calls), so while the
-- app is still loading and presenting slowly, one cycle takes long enough to
-- read as a moving band; once presents reach ~88Hz a whole cycle finishes in
-- about 11ms and integrates back into a flat picture, which is exactly what
-- the pass is FOR. So the startup band is the pass working, seen through a
-- frame rate too low to hide it -- not a bug, and not something to fix.
--
-- But it is a look, and it is now askable for: at 20Hz the ratio on this
-- hardware is ~4.4, the lit window covers under a quarter of the cycle, and
-- the band stays visible at full speed. It flickers, which is the honest cost
-- of a tube running at a third of the rate a real one did.
-- The ladder runs to 120 in fives to 60 and tens above it. Fives where it
-- matters: between 40 and 60 every rung visibly changes how much the band
-- flickers against how much blur it removes, and that is the range every tube
-- anyone actually watched lived in. Tens above 60, because past the panel's
-- own rate the rungs stop differing in kind -- see below.
--
-- A tube FASTER than the display cannot roll. The ratio is presents divided
-- by tube rate, so at this console's ~88Hz anything from 90 up gives N < 1,
-- the shader clamps it away, and the row reads NO HZ. Those rungs are on the
-- ladder anyway, and deliberately: they are not junk, they are what this
-- setting will do on a 144Hz or 240Hz screen, and the row MEASURES rather
-- than assumes -- so it tells the truth about them on whatever it is run on
-- instead of a list being right on one machine. NO HZ is a reading, not an
-- error.
CrtBeam.ROLL = {
  off = 0,
  ["15hz"] = 15, ["20hz"] = 20, ["25hz"] = 25, ["30hz"] = 30,
  ["35hz"] = 35, ["40hz"] = 40, ["45hz"] = 45, ["50hz"] = 50,
  ["55hz"] = 55, ["60hz"] = 60,
  ["70hz"] = 70, ["80hz"] = 80, ["90hz"] = 90, ["100hz"] = 100,
  ["110hz"] = 110, ["120hz"] = 120,
}

-- Blur reduction is 1 - 1/N, which is the relation behind Blur Busters' own
-- published figures: 120Hz for 60fps content is N=2 and "up to 50%", 240Hz is
-- N=4 and 75%, 480Hz is N=8 and 87.5%.  At the Deck's 90Hz with a 60Hz tube,
-- N=1.5 and the reduction is 33% -- modest, but real, and NOT the "thin"
-- nothing an earlier version of this row claimed it was.
function CrtBeam.blurReduction(n)
  if not n or n <= 1.0 then return 0 end
  return 1.0 - 1.0 / n
end

local function amount(map, setting, fallback)
  return map[setting:get()] or map[fallback] or 0
end

function CrtBeam.maskKind() return amount(CrtBeam.MASK, Settings.beammask, "off") end

-- The chosen phosphor colour as {r, g, b}. Exposed rather than kept private
-- because the SD-GYRO page draws the swatches from this same table -- the
-- strip a player picks from and the tint the shader receives have to be the
-- same numbers, or the swatch is a decoration that lies.
function CrtBeam.glowColour(name)
  return CrtBeam.GLOWCOL[name or Settings.beamglowcol:get()]
      or CrtBeam.GLOWCOL.white
end

function CrtBeam.wanted()
  return CrtBeam.maskKind() > 0
      or amount(CrtBeam.SCAN, Settings.beamscan, "off") > 0
      or amount(CrtBeam.GLOW, Settings.beamglow, "off") > 0
      or amount(CrtBeam.EDGE, Settings.beamedge, "off") > 0
      or amount(CrtBeam.ROLL, Settings.beamroll, "off") > 0
      -- The picture controls have to be in here or they are rows that only
      -- work while some OTHER row is on. Black and white with no mask, no
      -- scanlines and no curve is a perfectly reasonable thing to want, and
      -- it is the pass being off -- not the setting being off -- that would
      -- have stopped it.
      or amount(CrtBeam.MONO, Settings.beammono, "off") > 0
      or amount(CrtBeam.SAT, Settings.beamsat, "100") ~= 1.0
      or amount(CrtBeam.CONTRAST, Settings.beamcontrast, "100") ~= 1.0
end

-- The MEASURED present rate, which is what the ratio has to be built from.
--
-- Not the display's advertised refresh and not the frame cap: either can be
-- higher than what is actually reaching the panel, and a ratio computed from
-- a number the machine is not achieving is a lie on the row. Averaged over a
-- second of real presents, because this is read every frame while the menu is
-- open and an instantaneous dt is noise.
local rateT0, rateN, rateHz = nil, 0, nil
function CrtBeam.presentRate()
  return rateHz
end

local function tickRate()
  local now = (love.timer and love.timer.getTime and love.timer.getTime())
  if not now then return end
  if not rateT0 then rateT0, rateN = now, 0 return end
  rateN = rateN + 1
  local dt = now - rateT0
  if dt >= 1.0 then
    rateHz = rateN / dt
    rateT0, rateN = now, 0
  end
end

-- Refreshes per simulated tube frame, from the measured rate and the chosen
-- tube. This is the number the shader actually runs on.
function CrtBeam.rollRatio()
  local tube = amount(CrtBeam.ROLL, Settings.beamroll, "off")
  if tube <= 0 then return 0 end
  local hz = rateHz
  if not hz or hz <= 0 then
    -- nothing measured yet (the menu can be opened on the first frame), so
    -- fall back to what the window claims rather than refusing to draw
    if love and love.window and love.window.getMode then
      local ok, _, _, flags = pcall(love.window.getMode)
      if ok and flags then hz = tonumber(flags.refreshrate) end
    end
  end
  if not hz or hz <= 0 then return 0 end
  return hz / tube
end

-- What the ROLL row shows next to its value.  The rolling scan is the one
-- setting here whose usefulness is a property of the DISPLAY rather than of
-- the picture, and a player cannot be expected to know their refresh rate --
-- so it is measured and shown, along with what that buys.
--
-- The reading is the BLUR REDUCTION, because that is the thing the setting is
-- for. An earlier version showed THIN / FLICKER / OK, which was both vaguer
-- and wrong: it called 1.5x "thin" when 1.5x is a real 33% and is the correct
-- setting for this hardware.
function CrtBeam.rollStatus()
  local n = CrtBeam.rollRatio()
  if n <= 0 then return nil end
  if n < 1.05 then return "NO HZ" end
  return ("%d%%"):format(math.floor(CrtBeam.blurReduction(n) * 100 + 0.5))
end

local shader, failure, target = nil, nil, nil

function CrtBeam.shader()
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

function CrtBeam.status()
  if shader == false then return failure or "ERROR" end
  return nil
end

function CrtBeam.reset()
  shader, failure, target = nil, nil, nil
  CrtBeam.frames = nil
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

-- Same contract as RfTv.apply: hands back the canvas it was given on every
-- failure and whenever the pass is off, so callers chain the two without a
-- branch and neither can take a frame down.
function CrtBeam.apply(canvas, pixelScale)
  if not canvas or not CrtBeam.wanted() then return canvas end
  local sh = CrtBeam.shader()
  if not sh then return canvas end

  local okDim, w, h = pcall(canvas.getDimensions, canvas)
  if not okDim or not w then return canvas end
  local dst = buffer(w, h)
  if not dst then return canvas end

  CrtBeam.frames = (CrtBeam.frames or 0) + 1
  tickRate()
  -- No `time` here on purpose. This pass has no clock-driven term -- the
  -- rolling scan steps on frameIndex, which counts PRESENTS, because the beam
  -- has to advance exactly once per refresh and a wall clock does not
  -- guarantee that. Sending a uniform the shader does not declare is what
  -- took this whole pass out silently once already.
  local ok = pcall(function()
    sh:send("pixelScale", math.max(1, math.floor(tonumber(pixelScale) or 1)))
    -- the refresh counter, which is what the rolling scan advances on. Taken
    -- from our own frame count rather than the clock: the pass has to step
    -- exactly once per PRESENT or the beam stutters against the display.
    sh:send("frameIndex", CrtBeam.frames % 4096)
    sh:send("beamMask", CrtBeam.maskKind())
    sh:send("beamMaskAmt", amount(CrtBeam.MASKAMT, Settings.beammask, "off"))
    sh:send("beamPitch", amount(CrtBeam.PITCH, Settings.beammaskpitch, "normal"))
    sh:send("beamMono", amount(CrtBeam.MONO, Settings.beammono, "off"))
    sh:send("beamSat", amount(CrtBeam.SAT, Settings.beamsat, "100"))
    sh:send("beamContrast",
            amount(CrtBeam.CONTRAST, Settings.beamcontrast, "100"))
    sh:send("beamScan", amount(CrtBeam.SCAN, Settings.beamscan, "off"))
    sh:send("beamGlow", amount(CrtBeam.GLOW, Settings.beamglow, "off"))
    sh:send("beamGlowTint", CrtBeam.glowColour())
    sh:send("beamEdge", amount(CrtBeam.EDGE, Settings.beamedge, "off"))
    -- the RF pass's barrel, so the vignette bows with the glass rather than
    -- darkening a flat rectangle over a curved picture
    sh:send("beamCurve", V.require("RfTv").barrelK())
    sh:send("beamEdgeSoft",
            amount(CrtBeam.EDGESOFT, Settings.beamedgesoft, "normal"))
    -- the derived ratio, not the rung's raw value: the rung names a TUBE and
    -- the shader wants refreshes-per-tube-frame
    sh:send("beamRoll", CrtBeam.rollRatio())
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
  return dst
end

return CrtBeam
