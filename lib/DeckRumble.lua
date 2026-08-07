-- This mod's own vibration driver: channels, priority, and a response curve.
--
-- ------- why this exists when CONTROLLER_RUMBLE already works
--
-- It works, and the reason to own one anyway is not that its effects are bad.
-- It is that scaling somebody else's output cannot make a rumble STRONGER
-- past a point, and the point arrives early.
--
-- `setVibration` takes 0..1 and the driver clamps there. Measured from that
-- mod's own calls: a menu-move tick asks for 0.10, its story pulses run 0.16
-- to 0.55, an HP-drain grind reaches 0.85 and a faint 0.85/0.75. Multiply all
-- of that by ten and every single one of them is 1.0. The motor is at its
-- limit and so is the ladder, and a flat multiplier has one more property
-- nobody wants: it destroys the ORDERING on the way. At 10X a cursor tick and
-- a Pokemon fainting are the same sensation.
--
-- ------- the curve is the whole point
--
-- Owning the mixer means the strengths can be reshaped rather than scaled:
--
--     out = in ^ gamma        (gamma <= 1)
--
-- A power curve below 1 lifts the quiet end hard and the loud end barely,
-- because 1^g is 1 for every g. It is monotonic, so nothing ever overtakes
-- anything, and it never exceeds 1.0, so it cannot clip. At the widest
-- setting (gamma 0.30):
--
--     authored   0.10   0.22   0.35   0.55   0.85   1.00
--     flat 10X   1.00   1.00   1.00   1.00   1.00   1.00   <- everything, always
--     curve      0.50   0.65   0.73   0.84   0.95   1.00   <- still a range
--
-- That is the thing a boost cannot do at any number, and it is why the port
-- was worth writing rather than turning the multiplier up again.
--
-- ------- what is NOT claimed
--
-- This does not make the motor stronger than 1.0. Nothing can: the ceiling is
-- SDL's and the hardware's, not CONTROLLER_RUMBLE's. What it buys is the loud
-- end reached by more of the effects, with the quiet ones still distinguishable
-- underneath, plus hold time on top (see holdFrames scaling below).
--
-- ------- the shape of the port
--
-- The channel model is CONTROLLER_RUMBLE's and is kept deliberately: four
-- named channels at fixed priorities, highest wins, ties take the louder
-- motor, each holds for a frame count and expires. That design is correct --
-- a battle shake must beat an ambient heartbeat rather than sum with it into
-- mush -- and reproducing it means the paired events feel like themselves.
--
-- See lib/RumbleEvents for the wiring that feeds it.

local V = ...

local DeckRumble = {}

-- Higher wins outright. Same numbers as the mod this pairs with, so an event
-- ported across keeps its place in the pecking order.
local PRIORITY = {
  shake   = 100, -- screen-shake sync: the faithful layer, beats everything
  impact  = 80,  -- damage, faints, catches
  story   = 60,  -- level-ups, evolutions, confirms
  ambient = 20,  -- heartbeat, footsteps, cursor ticks
}
DeckRumble.PRIORITY = PRIORITY

-- channel -> { left, right, frames, priority }
local channels = {}
local vibrating = false
local lastLeft, lastRight = 0, 0

DeckRumble.lastLeft, DeckRumble.lastRight = 0, 0

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

-- ------- the response curve
--
-- gamma 1.0 is authored strength, untouched -- the NORMAL rung, and what the
-- other mod does at its own HIGH. Below 1.0 lifts the quiet end.
--
-- 0.30 is the floor rather than something smaller because the curve flattens
-- as gamma falls and stops buying anything: at 0.15 a 0.10 tick is already
-- 0.71 and the gap to a 1.0 faint is down to a third of the range. Past that
-- it is the flat multiplier again by another route.
DeckRumble.GAMMA_MIN = 0.30

function DeckRumble.shape(v, gamma)
  v = clamp01(tonumber(v) or 0)
  if v <= 0 then return 0 end -- silence stays silent at every setting
  gamma = tonumber(gamma) or 1
  if gamma >= 1 then return v end
  if gamma < DeckRumble.GAMMA_MIN then gamma = DeckRumble.GAMMA_MIN end
  return clamp01(v ^ gamma)
end

-- Authored strength -> what to drive, with both settings rows applied.
-- Through pcall so the driver still runs if Settings is mid-load.
local function shaped(v)
  local ok, s = pcall(function() return V.require("Settings") end)
  if not ok or not s or not s.rumbleShapeValue then return clamp01(v) end
  local okS, out = pcall(s.rumbleShapeValue, v)
  return (okS and type(out) == "number") and out or clamp01(v)
end

local function joysticks()
  if not (love and love.joystick and love.joystick.getJoysticks) then
    return {}
  end
  local ok, pads = pcall(love.joystick.getJoysticks)
  if not ok or type(pads) ~= "table" then return {} end
  return pads
end

function DeckRumble.pad()
  for _, p in ipairs(joysticks()) do
    if p.isVibrationSupported then
      local ok, yes = pcall(p.isVibrationSupported, p)
      if ok and yes then return p end
    end
  end
  return nil
end

-- The kernel path: love.joystick, which on this hardware reaches Steam
-- Input's emulated pad and produces the gentle buzz the game always had.
-- Kept, for two reasons: it is the STOCK rung, so "put it back how it was" is
-- a real setting rather than an approximation; and above the stacking
-- threshold it runs UNDERNEATH the direct drive, where it adds.
local function applyKernel(left, right, seconds)
  left, right = clamp01(left), clamp01(right)
  local any = false
  for _, pad in ipairs(joysticks()) do
    local supported = false
    if pad.isVibrationSupported then
      local ok, yes = pcall(pad.isVibrationSupported, pad)
      supported = ok and yes
    end
    if supported and pad.setVibration then
      -- short refresh so a missed stop cannot leave the pad buzzing
      local ok = pcall(pad.setVibration, pad, left, right, seconds or 0.08)
      if ok then any = true end
    end
  end
  return any
end

-- ------- the output stage
--
-- STOCK is the kernel path alone: exactly what the game did before any of
-- this, so the bottom of the ladder is the original feel and not a guess at
-- it. Every rung above it drives the actuators DIRECTLY over HID, which is
-- the only route with any real strength on a Deck -- see lib/DeckHaptics for
-- the measurements, and for why there is no amplitude to turn up.
--
-- The two are not exclusive at the top: past DeckHaptics.STACK_FROM the
-- kernel path runs underneath the direct one and adds to it, because both
-- reach the same actuators by different routes.
local function applyMotors(left, right, seconds)
  local okS, Settings = pcall(function() return V.require("Settings") end)
  local direct = okS and Settings and Settings.rumbleDirect
                 and Settings.rumbleDirect() or false

  if not direct then
    return applyKernel(left, right, seconds)
  end

  local okH, Haptics = pcall(V.require, "DeckHaptics")
  if not okH or not Haptics or not Haptics.available() then
    -- no HID route: fall back rather than going silent, so a machine this
    -- does not work on still rumbles the way it used to
    return applyKernel(left, right, seconds)
  end

  local ok, stack = Haptics.playSides(clamp01(left), clamp01(right),
                                      seconds or 0.10)
  if stack then applyKernel(left, right, seconds) end
  return ok
end

-- Stop BOTH routes unconditionally, whichever one was running. Cheap, and it
-- means switching the power row mid-buzz cannot strand the other path on.
local function stopMotors()
  for _, pad in ipairs(joysticks()) do
    if pad.setVibration then pcall(pad.setVibration, pad, 0, 0) end
  end
  local okH, Haptics = pcall(V.require, "DeckHaptics")
  if okH and Haptics then pcall(Haptics.stop) end
end

-- ------- channels
--
-- Strengths are stored AS AUTHORED and shaped at the motor, not here. Two
-- reasons: the curve can then change while a channel is still holding without
-- that channel keeping the old shape for its remaining frames, and the events
-- stay readable as the numbers their author chose.
function DeckRumble.setChannel(name, left, right, holdFrames)
  local pri = PRIORITY[name]
  if not pri then return end
  channels[name] = {
    left = clamp01(tonumber(left) or 0),
    right = clamp01(tonumber(right) or 0),
    frames = math.max(1, holdFrames or 1),
    priority = pri,
  }
end

function DeckRumble.pulse(name, left, right, holdFrames)
  DeckRumble.setChannel(name, left, right, holdFrames or 6)
end

function DeckRumble.clearChannel(name) channels[name] = nil end

function DeckRumble.hasActive(minPriority)
  minPriority = minPriority or 0
  for _, ch in pairs(channels) do
    if ch.frames > 0 and ch.priority >= minPriority then return true end
  end
  return false
end

function DeckRumble.channelActive(name)
  local ch = channels[name]
  return ch ~= nil and ch.frames > 0
end

function DeckRumble.stopAll()
  channels = {}
  if vibrating then
    stopMotors()
    vibrating = false
  end
  lastLeft, lastRight = 0, 0
  DeckRumble.lastLeft, DeckRumble.lastRight = 0, 0
end

-- for the tests, and for anything that wants to know what is holding
function DeckRumble.channels() return channels end

-- ------- the mixer
--
-- Highest priority wins outright; ties take the louder motor of each side.
-- Once per frame.
function DeckRumble.tick()
  local ok, Settings = pcall(function() return V.require("Settings") end)
  if not ok or not Settings or not Settings.ownRumbleOn
      or not Settings.ownRumbleOn() then
    if vibrating then DeckRumble.stopAll() end
    return
  end

  local bestPri, bestL, bestR = -1, 0, 0
  for name, ch in pairs(channels) do
    if ch.frames > 0 then
      if ch.priority > bestPri then
        bestPri, bestL, bestR = ch.priority, ch.left, ch.right
      elseif ch.priority == bestPri then
        if ch.left > bestL then bestL = ch.left end
        if ch.right > bestR then bestR = ch.right end
      end
      ch.frames = ch.frames - 1
      if ch.frames <= 0 then channels[name] = nil end
    else
      channels[name] = nil
    end
  end

  if bestPri < 0 or (bestL <= 0 and bestR <= 0) then
    if vibrating then
      stopMotors()
      vibrating = false
      lastLeft, lastRight = 0, 0
      DeckRumble.lastLeft, DeckRumble.lastRight = 0, 0
    end
    return
  end

  local l = shaped(bestL)
  local r = shaped(bestR)
  applyMotors(l, r)
  vibrating = true
  lastLeft, lastRight = l, r
  DeckRumble.lastLeft, DeckRumble.lastRight = l, r
end

-- A pulse the player can feel from the options page, at the strength a firm
-- in-game hit would arrive at with the current row -- so the test says
-- something about the setting rather than always saturating.
DeckRumble.TEST_BASE = 0.6

function DeckRumble.test()
  DeckRumble.pulse("impact", DeckRumble.TEST_BASE, DeckRumble.TEST_BASE, 24)
  return shaped(DeckRumble.TEST_BASE)
end

-- What the options page shows.
--   NO PAD   nothing connected that reports vibration support
--   READY    ours is running
--   OFF      the row is off, and whatever else is installed owns the motor
-- What the RUMBLE page shows, most-actionable answer first.
--   DIRECT   the strong HID route is open and in use
--   STOCK    running, but on the gentle kernel path (the STOCK rung)
--   NO HID   the strong route could not be opened; falling back to kernel
--   NO PAD   nothing to vibrate at all
--   OFF      the row is off
function DeckRumble.status()
  local ok, Settings = pcall(function() return V.require("Settings") end)
  local on = ok and Settings and Settings.ownRumbleOn and Settings.ownRumbleOn()
  if not on then return "OFF" end
  local direct = ok and Settings.rumbleDirect and Settings.rumbleDirect()
  if not direct then
    return DeckRumble.pad() and "STOCK" or "NO PAD"
  end
  local okH, H = pcall(V.require, "DeckHaptics")
  if okH and H and H.available() then return "DIRECT" end
  return DeckRumble.pad() and "NO HID" or "NO PAD"
end

return DeckRumble
