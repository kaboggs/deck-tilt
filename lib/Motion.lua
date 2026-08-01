-- Gravity in, light position out.
--
-- Five steps, and nothing else:
--
--   1. smooth the gravity direction
--   2. turn it into angles, in degrees
--   3. subtract the anchor -- how you were holding it when you last centred
--   4. scale by a gain sized to the tilt available on that side
--   5. clamp to the screen
--
-- Step 4 is the only subtle one, and it is what most of this file is about.
-- A fixed gain is uniform but cannot promise the screen edge from an awkward
-- anchor; a gain scaled purely to the room left promises the edge but goes
-- sluggish when the room is large.  Bounding the span gives both:
-- comfortable where there is room, compressed where there is not.

local V = ...
local Imu = V.require("Imu")
local Settings = V.require("Settings")

local Motion = {}

-- Where the light rests, and the box it travels in.  The box runs slightly
-- outside the frame so the light can be pushed fully off an edge.
local CX, CY = 0.5, 0.5
local LO, HI = -0.10, 1.10
local TRAVEL = 0.60          -- centre to clamp

-- How far the console can physically be tilted, in degrees.  Pitch runs from
-- upright to a little past flat -- you cannot tip it further and still see
-- the screen.  Measured, not assumed: a logged session spanned -60 to +2.
local PITCH_MIN, PITCH_MAX = -90.0, 5.0
local ROLL_MIN, ROLL_MAX = -60.0, 60.0

-- The tilt that carries the light from centre to an edge when there is room
-- for it, and the least tilt it may be compressed into when there is not.
-- SPAN keeps the response comfortable and uniform; MIN_ROOM stops a
-- direction with almost no tilt left from going completely dead.
local SPAN = 30.0
local MIN_ROOM = 12.0

-- Multipliers around NORMAL, from the two AMT rows.
local MULT = {
  subtle = 0.5, low = 0.7, normal = 1.0,
  high   = 1.4, wide = 2.0, max    = 3.0,
}

-- ---- gyro fusion ---------------------------------------------------------
--
-- The accelerometer cannot do this alone.  Measured while tilting by hand,
-- 71% of its samples were more than 15% off gravity -- it reads gravity PLUS
-- whatever the hands are doing, and the hands dominate.  Filtering harder
-- only trades one fault for lag.
--
-- So the gyro carries the fast response and the accelerometer corrects it
-- slowly underneath.  The gyro is immune to linear acceleration and needs no
-- smoothing at all, which is where the immediacy comes from; it drifts, which
-- is what the accelerometer is for.
--
-- Degrees per second per raw count, per axis, measured on this hardware
-- rather than taken from a datasheet.
--
-- Pitch, from three slow single-axis tilts with still periods either side:
-- +0.0201, +0.0168, +0.0234.
--
-- Roll, from a separate roll-only capture: -0.0217, -0.0279, -0.0350.  The
-- SIGN is the important part and it is opposite: rolling one way moves gx in
-- the direction that ry reports as negative.  Both axes were briefly given
-- the same positive constant, which had the gyro driving roll backwards
-- while the accelerometer pulled the other way every frame.
--
-- The magnitudes differ more than one three-axis gyro should, and the roll
-- capture is the dirtier of the two -- 13% pitch cross-talk against about 5%
-- the other way -- so each axis keeps its own measured value rather than
-- being forced to agree.  A scale error costs a little lag, which the
-- accelerometer correction absorbs; a sign error does not degrade, it fights.
-- One per device axis, regressed against the accelerometer over the two
-- captures.  About X is the well measured one (133 degrees of travel); the
-- others come from smaller spans, so their magnitudes are less certain than
-- their signs -- and a sign error fights the accelerometer where a scale
-- error only costs a little lag.
local GYRO_K = { x = -0.019, y = -0.027, z = 0.019 }

-- Which gyro axis drives which angle.  rx->pitch is measured: in a clean
-- capture 91% of the gyro energy sat on rx while pitch moved 8.7 degrees and
-- roll stayed flat.  ry->roll follows from the geometry -- rotation about the
-- device's Y axis is what moves gx -- and from a three-axis gyro sharing one
-- scale.  It was NOT measured directly: the capture ended before that
-- segment.
--
-- How long the accelerometer takes to pull the fused angle back to truth.
-- Long enough that hand motion does not reach the light, short enough that
-- gyro drift never accumulates visibly.
local FUSE_TAU = 1.2

-- How fast the anchor follows a sustained change of hold, in seconds.
--
-- Measured, not guessed: with the anchor fixed, 10 degrees of posture drift
-- pins the light against the top edge and 25 degrees puts the resting
-- position off the screen entirely.  Nobody holds a console at one angle for
-- ten minutes -- wrists settle -- so a fixed anchor cannot stay centred.
--
-- These are far longer than an aiming tilt and far shorter than a posture
-- change.  A tilt held two seconds loses about a tenth of its deflection at
-- SLOW, which is not perceptible; a lean that lasts a minute is absorbed.
-- OFF is kept because an anchor that moves at all is wrong for a player who
-- recentres by hand and wants the mapping to stay exactly where it was put.
local LEVEL_TAU = { off = nil, slow = 45.0, normal = 20.0, fast = 8.0 }
-- --------------------------------------------------------------------------

-- Smoothing, seconds.  An accelerometer reads gravity plus whatever the
-- hands are doing; measured here the magnitude swings through 245% of its
-- median while tilting, so this cannot be quick.
local TAU = { tight = 0.10, normal = 0.20, loose = 0.40 }

-- Least a sample may be trusted.  Without a floor a single disturbed reading
-- multiplied the filter step by nearly zero: logged live, one frame in five
-- fell below 0.30 and the worst effective time constant was 99 seconds, so
-- the light was still chasing a tilt made seconds earlier.
local TRUST_FLOOR = 0.35


local fx, fy, fz               -- smoothed gravity direction
local aX, aY, aZ               -- anchor gravity direction
local dTip, dTurn, dSide       -- fused rotation since the anchor, degrees
local lastX, lastY = CX, CY

Motion.recentreCount = 0

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function approach(cur, target, tau, dt)
  if cur == nil then return target end
  if tau <= 0 or dt <= 0 then return target end
  return cur + (target - cur) * (1 - math.exp(-dt / tau))
end

-- Gravity direction to three angles in degrees, each independent of the
-- others.  asin of the component, NOT a ratio: dividing by gz coupled the
-- axes together and made the response vanish near vertical, where gz does.
function Motion.tilt(gx, gy, gz)
  local function deg(v) return math.deg(math.asin(clamp(v or 0, -1, 1))) end
  return deg(gx), deg(gy), deg(gz)
end

-- Rotation from the anchor to where the console is now, split into its three
-- device axes, in degrees.
--
-- This replaces measuring each axis as asin of a gravity component, which is
-- only decoupled for a console lying FLAT.  Held upright and rolled one side
-- up, gravity turns in the XY plane, so gy follows -cos(theta) -- and cosine
-- is symmetric, so BOTH roll directions produced the same false "tipped
-- forward" reading.  Simulated: a pure 30 degree roll moved asin(gy) by 30
-- degrees either way.  On screen that is the light sliding down whichever
-- way you roll, which is exactly what it did.
--
-- A cross product has no such coupling, at any hold: a pure roll gives zero
-- tip and a pure tip gives zero roll, exactly.  It is also anchor-relative by
-- construction, which is what RECENTRE means.
function Motion.deviation(ax, ay, az, gx, gy, gz)
  local function deg(v) return math.deg(math.asin(clamp(v, -1, 1))) end
  return deg(ay * gz - az * gy),   -- about X: tipping the top edge
         deg(az * gx - ax * gz),   -- about Y: turning like a page
         deg(ax * gy - ay * gx)    -- about Z: raising one side
end

-- Gain for one direction, from the tilt left in it.
function Motion.gainFor(room, mult)
  return TRAVEL / clamp(room, MIN_ROOM, SPAN) * (mult or 1)
end

function Motion.reset()
  fx, fy, fz = nil, nil, nil
  dTip, dTurn, dSide = nil, nil, nil
  lastX, lastY = CX, CY
  Imu.resetTwist()
end

-- Centre on the angle being held right now.
--
-- The smoothing is snapped to the current reading first.  It deliberately
-- lags to reject hand shake, so reading it here anchored to where the
-- console WAS: logged from a real session, the console was picked up off a
-- table and recentred, and the anchor came out at +0.9 degrees, still flat.
function Motion.recentre()
  Motion.recentreCount = Motion.recentreCount + 1
  if Imu.x and Imu.y and Imu.z then
    fx, fy, fz = Imu.x, Imu.y, Imu.z
  end
  if fx and fy and fz then
    aX, aY, aZ = fx, fy, fz
    dTip, dTurn, dSide = 0, 0, 0
  end
end

function Motion.resetCentre()
  aX, aY, aZ = nil, nil, nil
  dTip, dTurn, dSide = nil, nil, nil
end

-- Every axis the hardware offers, as deviations from the anchor in degrees.
-- The gyro ones are rates rather than angles, scaled to land in the same
-- ballpark so one gain serves them all.
-- The three rotations, named for what your hands do.  Which one moves the
-- light sideways depends on how you hold the console -- raising one side is
-- a turn about Y held flat, but about Z held upright -- so all three are
-- offered and the SIDEWAYS / UP-DOWN rows choose.
function Motion.sources(dTip, dTurn, dSide)
  return {
    off   = 0,
    tip   = dTip,    -- tip the top edge toward or away  (about the width line)
    turn  = dTurn,   -- turn it like a page              (about the centre line)
    twist = dSide,   -- raise one side                   (about the screen face)
    flat  = dTip,
    spiny = (Imu.rx or 0) * 12,
    spinx = (Imu.ry or 0) * 12,
  }
end

function Motion.signed(dx, dy)
  if Settings.signx:get() == "neg" then dx = -dx end
  if Settings.signy:get() == "neg" then dy = -dy end
  return dx, dy
end

-- Deviations in degrees to a screen position.  Each direction is scaled by
-- the tilt still available on that side of the anchor, so recentring
-- anywhere reaches both edges wherever the tilt allows it.
-- Deviations are now rotation FROM the anchor, so both directions always
-- have room and the gain is simply fixed: SPAN degrees carries the light
-- from centre to an edge, the same from any hold.
function Motion.project(devX, devY)
  local gx = TRAVEL / SPAN * (MULT[Settings.xrange:get()] or 1)
  local gy = TRAVEL / SPAN * (MULT[Settings.yrange:get()] or 1)
  return clamp(CX - gx * devX, LO, HI),
         clamp(CY - gy * devY, LO, HI)
end

-- One step of the complementary filter, for all three axes.
--
-- Pure, and separate from light(), so it can be tested without a sensor.
-- It was inline before, where the only way to exercise it was to hold a
-- Deck -- and a sign error in the roll constant reached the player because
-- of exactly that.  A headless test would have caught it in a second.
--
-- Integrate the gyro for this frame (instant, no smoothing), then bleed
-- towards the accelerometer over FUSE_TAU (absolute, kills drift).
function Motion.fuse(tip, turn, side, accTip, accTurn, accSide, rx, ry, rz, dt)
  tip  = (tip  or accTip)  + rx * GYRO_K.x * dt
  turn = (turn or accTurn) + ry * GYRO_K.y * dt
  side = (side or accSide) + rz * GYRO_K.z * dt
  local w = 1 - math.exp(-dt / math.max(FUSE_TAU, 1e-6))
  return tip  + (accTip  - tip)  * w,
         turn + (accTurn - turn) * w,
         side + (accSide - side) * w
end

-- Returns the light position, or nil to mean "let the engine draw its own".
function Motion.light(dt)
  local mode = Settings.motion:get()
  if mode == "off" then
    Motion.reset()
    return nil
  end

  dt = clamp(tonumber(dt) or 0, 0, 0.1)
  local gx, gy, gz = Imu.poll(dt, mode == "demo")
  if not gx then
    if Imu.isLive() then return lastX, lastY end
    Motion.reset()
    return nil
  end

  -- Step scaled by how far this reading can be trusted, floored so a
  -- disturbed sample slows the filter rather than stalling it.
  local tau = TAU[Settings.smooth:get()] or TAU.normal
  local step = dt * math.max(Imu.trust or 1, TRUST_FLOOR)
  fx = approach(fx, gx, tau, step)
  fy = approach(fy, gy, tau, step)
  fz = approach(fz, gz, tau, step)

  -- the anchor is the gravity direction itself, not a pair of angles
  aX = aX or fx; aY = aY or fy; aZ = aZ or fz

  -- Let the anchor follow a sustained change of hold.  Applied to the
  -- anchor rather than to the output: the deviation stays a true rotation
  -- between two gravity directions, so the mapping keeps reaching both
  -- edges instead of being nudged off centre by a correction term.
  local levelTau = LEVEL_TAU[Settings.level:get()]
  if levelTau then
    local w = 1 - math.exp(-dt / levelTau)
    aX = aX + (fx - aX) * w
    aY = aY + (fy - aY) * w
    aZ = aZ + (fz - aZ) * w
    -- renormalise: two unit vectors blended are shorter than one, and the
    -- cross product this feeds reads that shortfall as a smaller angle
    local m = math.sqrt(aX * aX + aY * aY + aZ * aZ)
    if m > 1e-6 then aX, aY, aZ = aX / m, aY / m, aZ / m end
  end

  -- accelerometer's opinion of the rotation since the anchor
  local accTip, accTurn, accSide = Motion.deviation(aX, aY, aZ, fx, fy, fz)

  dTip, dTurn, dSide = Motion.fuse(dTip, dTurn, dSide,
    accTip, accTurn, accSide, Imu.rx or 0, Imu.ry or 0, Imu.rz or 0, dt)

  local src = Motion.sources(dTip, dTurn, dSide)
  local dx, dy = Motion.signed(src[Settings.srcx:get()] or 0,
                               src[Settings.srcy:get()] or 0)
  lastX, lastY = Motion.project(dx, dy)

  return lastX, lastY
end

function Motion.lastLightX() return lastX end
function Motion.lastLightY() return lastY end
function Motion.anchorPitch() return dTip end

Motion.FRAME = { xMin = LO, xMax = HI, yMin = LO, yMax = HI,
                 restX = CX, restY = CY,
                 pitchMin = PITCH_MIN, pitchMax = PITCH_MAX,
                 rollMin = ROLL_MIN, rollMax = ROLL_MAX,
                 span = SPAN, minRoom = MIN_ROOM }

return Motion
