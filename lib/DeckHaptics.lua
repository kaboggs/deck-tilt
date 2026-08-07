-- Drive the Deck's haptic actuators directly, over raw HID.
--
-- ------- why not love.joystick.setVibration
--
-- Because on this hardware it does nothing, while reporting that it worked.
-- Measured on a Steam Deck, LOVE 11.5:
--
--   joysticks: 1
--   name = "Microsoft X-Box 360 pad 0"      <- Steam Input's VIRTUAL pad
--   isVibrationSupported = true
--   setVibration(1, 1, 2.0) -> returned true
--   getVibration -> 0 / 0                   <- nothing stuck
--
-- The Deck has no rumble motors. It has two LRA actuators behind the
-- trackpads, and they are not exposed as force feedback at all: in
-- /proc/bus/input/devices the real `Valve Software Steam Controller` nodes
-- report FF=none, and the only FF-capable device in the system is that
-- virtual X360 pad, whose FF_RUMBLE the kernel emulates by asking the
-- actuators for a gentle buzz. Even at 0xFFFF/0xFFFF that emulation is barely
-- perceptible -- which is the real reason the rumble in this game has always
-- felt minimal, and no multiplier anywhere in any mod could have fixed it.
-- Scaling zero, or scaling something already at its emulated ceiling, is
-- still nothing.
--
-- ------- what this does instead
--
-- The same trick this mod already uses for the gyro: go to the device. The
-- Steam Controller protocol has a haptic command, and /dev/hidraw3 accepts
-- it (measured -- hidraw0 and hidraw1 time out; only the node carrying the
-- input reports answers):
--
--   feature report, 65 bytes: [0x00] 0x8f 0x07 side hi_us(16) lo_us(16) count(16)
--
-- `hi_us` and `lo_us` are MICROSECONDS the actuator is driven and released;
-- `count` is how many times to repeat. There is NO amplitude field. The drive
-- voltage is fixed, so "make it louder" is not a number you can send -- which
-- is worth stating plainly, because it is the obvious thing to look for.
--
-- ------- so where does the range come from
--
-- From three levers, all measured on hardware rather than guessed:
--
--   1. FREQUENCY. An LRA is a resonant mass on a spring and it is far
--      stronger near resonance than away from it. 1e6/(hi+lo) is the drive
--      frequency; the first sweep of this used hi=65535 by mistake, which is
--      about 14 Hz, and felt like a slow flutter. Swept properly at 50% duty
--      the useful band is around 200 Hz.
--
--   2. DUTY. hi/(hi+lo). More time driven is more energy into the mass. 50%
--      is the baseline; up near 95% is noticeably harder. It cannot reach
--      100% -- that is DC, and a stationary actuator makes no vibration.
--
--   3. STACKING. The kernel's FF_RUMBLE emulation drives the SAME actuators
--      by another route, and running both at once adds to it rather than
--      replacing it. Free on top of the above.
--
-- Plus CONTINUITY: re-triggering before the previous train ends keeps the
-- mass excited instead of letting it ring down between bursts, which reads
-- as a stronger effect for the same drive.
--
-- ------- and the honest ceiling
--
-- All four together is the most this hardware can do. There is no gain, so
-- the top of the ladder is a physical limit and not a number this mod chose.
-- The ladder is wide because the BOTTOM is very quiet, not because the top
-- goes somewhere new.

local V = ...

local DeckHaptics = {}

-- ------- FFI
--
-- pcall'd all the way down, exactly like Imu: a non-LuaJIT host must leave
-- this inert rather than erroring out of the mod's load.
local ffi
local haveFfi = false
do
  local ok, mod = pcall(require, "ffi")
  if ok and mod then
    ffi = mod
    pcall(function()
      ffi.cdef [[
        int open(const char *pathname, int flags);
        int close(int fd);
        int ioctl(int fd, unsigned long request, ...);
      ]]
    end)
    haveFfi = pcall(function() return ffi.C.ioctl end)
  end
end

local bit = haveFfi and require("bit") or nil

local O_RDWR = 2

-- HIDIOCSFEATURE(len) = _IOC(_IOC_WRITE|_IOC_READ, 'H', 0x06, len)
--
-- Built with ARITHMETIC, not bit.lshift, and that is not a style choice.
-- LuaJIT's bit library works in signed 32-bit: bit.lshift(3, 30) is
-- 0xC0000000 read as -1073741824, and passing a negative through the
-- `unsigned long` parameter sign-extends it to 0xFFFFFFFFC0000000. The ioctl
-- then fails with EINVAL on every node and the whole module reports NO HID
-- while the device is sitting there working -- which is exactly what it did
-- on the first run of this. Plain multiplication keeps it a positive double,
-- which converts to the right unsigned long.
local function HIDIOCSFEATURE(len)
  return 3 * 1073741824 + len * 65536 + 0x48 * 256 + 0x06
end

local REPORT = 65 -- report id byte + 64
local CMD_HAPTIC = 0x8f

-- ------- the tuning, all measured
--
-- 200 Hz: swept 60/90/125/160/200/250/320 at 50% duty on hardware. The band
-- around 200 is where it stops being a hum and starts being a knock.
DeckHaptics.FREQ_HZ = 200

-- Duty at the quietest and loudest rungs.
--
-- The floor was 0.35 on the assumption that below about a third the actuator
-- barely leaves its rest position. That was a guess and it was wrong: 35%
-- duty at resonance is a real, clearly audible buzz, so EVERY low rung
-- arrived at roughly the same strength and the bottom of the ladder had no
-- quiet end at all. Reported from hardware as "low and very low are still a
-- bit strong", which is exactly what a floor that high produces.
--
-- 0.08 gives the quiet rungs somewhere to actually be. The ceiling is
-- unchanged -- 100% is DC and silent, so 0.95 stays the top.
DeckHaptics.DUTY_MIN = 0.08
DeckHaptics.DUTY_MAX = 0.95

-- Above this strength the kernel FF path is stacked underneath as well.
-- Not from zero: at low strengths the point is a light tick, and adding a
-- second driver to a tick makes every quiet effect the same as a loud one.
DeckHaptics.STACK_FROM = 0.55

local fd = nil
local node = nil
local failed = false

DeckHaptics.NODES = { "/dev/hidraw3", "/dev/hidraw2", "/dev/hidraw1",
                      "/dev/hidraw0", "/dev/hidraw4" }

-- Which node answers. Measured: only the one carrying the input reports
-- accepts the command; the others time out at the ioctl. So this is a probe
-- rather than a guess, done once.
local function openDevice()
  if fd or failed or not haveFfi then return fd end
  for _, path in ipairs(DeckHaptics.NODES) do
    local h = ffi.C.open(path, O_RDWR)
    if h >= 0 then
      -- ------- the probe, and the count=0 trap
      --
      -- A single 2-microsecond pulse: well-formed, so it proves the device
      -- understands the command, and far too short and too fast to be felt.
      --
      -- count MUST NOT BE ZERO. Zero does not mean "play nothing" -- it means
      -- REPEAT FOREVER, and the first version of this probe used it. The
      -- result was a Deck that buzzed continuously from the moment anything
      -- asked whether haptics were available, with no game running and
      -- nothing to switch off. `stop()` used count=0 too, so the one function
      -- meant to end a train was starting an endless one.
      --
      -- An all-zeroes body is separately rejected, which is why hi and lo are
      -- 1 rather than 0.
      local buf = ffi.new("unsigned char[?]", REPORT)
      buf[0] = 0; buf[1] = CMD_HAPTIC; buf[2] = 0x07; buf[3] = 0
      buf[4] = 0x01; buf[5] = 0x00 -- hi = 1us
      buf[6] = 0x01; buf[7] = 0x00 -- lo = 1us
      buf[8] = 0x01; buf[9] = 0x00 -- count = 1: finite, and imperceptible
      local okIoctl = ffi.C.ioctl(h, HIDIOCSFEATURE(REPORT), buf)
      if okIoctl >= 0 then
        fd, node = h, path
        return fd
      end
      ffi.C.close(h)
    end
  end
  failed = true
  return nil
end

-- One pulse train on one pad. side 0 = right, 1 = left.
function DeckHaptics.raw(side, hi_us, lo_us, count)
  local h = openDevice()
  if not h then return false end
  local buf = ffi.new("unsigned char[?]", REPORT)
  buf[0] = 0
  buf[1] = CMD_HAPTIC
  buf[2] = 0x07
  buf[3] = side
  buf[4] = bit.band(hi_us, 0xFF);          buf[5] = bit.band(bit.rshift(hi_us, 8), 0xFF)
  buf[6] = bit.band(lo_us, 0xFF);          buf[7] = bit.band(bit.rshift(lo_us, 8), 0xFF)
  -- Zero means REPEAT FOREVER on this device, not "play nothing", so it is
  -- clamped here as well as at both call sites. A caller computing a count
  -- from a very short duration can reach zero by rounding, and the symptom
  -- -- a console that will not stop buzzing -- gives no clue where it came
  -- from.
  count = math.floor(tonumber(count) or 1)
  if count < 1 then count = 1 end
  if count > 0xFFFF then count = 0xFFFF end
  buf[8] = bit.band(count, 0xFF);          buf[9] = bit.band(bit.rshift(count, 8), 0xFF)
  return ffi.C.ioctl(h, HIDIOCSFEATURE(REPORT), buf) >= 0
end

-- ------- strength -> drive
--
-- Pure, and separate from the write, so the mapping can be tested headlessly.
-- Returns hi_us, lo_us, count, stack.
function DeckHaptics.driveFor(strength, seconds, freqHz)
  local s = tonumber(strength) or 0
  if s < 0 then s = 0 elseif s > 1 then s = 1 end
  local secs = tonumber(seconds) or 0.1
  local f = tonumber(freqHz) or DeckHaptics.FREQ_HZ
  if f < 20 then f = 20 elseif f > 500 then f = 500 end

  local period = math.floor(1000000 / f)
  local duty = DeckHaptics.DUTY_MIN
             + (DeckHaptics.DUTY_MAX - DeckHaptics.DUTY_MIN) * s
  local hi = math.floor(period * duty)
  if hi < 1 then hi = 1 end
  local lo = period - hi
  if lo < 1 then lo = 1 end

  local count = math.floor(secs * 1000000 / period)
  if count < 1 then count = 1 end
  if count > 0xFFFF then count = 0xFFFF end

  return hi, lo, count, (s >= DeckHaptics.STACK_FROM)
end

-- Play at `strength` (0..1) for `seconds`, on both pads.
--
-- Returns whether it reached the device, and whether the caller should also
-- run the kernel FF path underneath -- which this module deliberately does
-- NOT do itself, because that path belongs to love.joystick and this one has
-- no business owning both.
function DeckHaptics.play(strength, seconds, freqHz)
  local hi, lo, count, stack = DeckHaptics.driveFor(strength, seconds, freqHz)
  if (tonumber(strength) or 0) <= 0 then return false, false end
  local okR = DeckHaptics.raw(0, hi, lo, count)
  local okL = DeckHaptics.raw(1, hi, lo, count)
  return (okR or okL), stack
end

-- Both pads, each at its own strength.
--
-- The channel model carries a LEFT and a RIGHT amplitude and they differ on
-- purpose -- a hit taken is heavier on the left, a horizontal shake on the
-- right. There is no amplitude field to send, but there are two pads and each
-- takes its own duty, so the asymmetry survives as a difference in drive
-- rather than being flattened into one number.
--
-- side 0 is the RIGHT pad and side 1 the LEFT, per Valve's numbering.
function DeckHaptics.playSides(left, right, seconds, freqHz)
  local l = tonumber(left) or 0
  local r = tonumber(right) or 0
  if l <= 0 and r <= 0 then return false, false end
  local anyOk, stack = false, false
  if r > 0 then
    local hi, lo, count, st = DeckHaptics.driveFor(r, seconds, freqHz)
    anyOk = DeckHaptics.raw(0, hi, lo, count) or anyOk
    stack = stack or st
  end
  if l > 0 then
    local hi, lo, count, st = DeckHaptics.driveFor(l, seconds, freqHz)
    anyOk = DeckHaptics.raw(1, hi, lo, count) or anyOk
    stack = stack or st
  end
  return anyOk, stack
end

-- Cancel whatever is playing.
--
-- A new train supersedes the one in flight, so the way to stop the actuator
-- is to give it a train that finishes immediately: one pulse, two
-- microseconds long, which is over before it can move the mass.
--
-- NOT count=0. That is the bug this function used to BE: zero repeats
-- forever, so `stop()` was the thing starting an endless buzz. If this ever
-- needs changing, that is the trap to remember.
function DeckHaptics.stop()
  DeckHaptics.raw(0, 1, 1, 1)
  DeckHaptics.raw(1, 1, 1, 1)
end

function DeckHaptics.available()
  return openDevice() ~= nil
end

function DeckHaptics.device() return node end

function DeckHaptics.status()
  if not haveFfi then return "NO FFI" end
  if DeckHaptics.available() then return "DIRECT" end
  return "NO HID"
end

function DeckHaptics.close()
  if fd then ffi.C.close(fd) fd, node = nil, nil end
end

return DeckHaptics
