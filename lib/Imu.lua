-- The Steam Deck's accelerometer, read straight off the controller's HID
-- device.
--
-- Nothing in the stack below us offers this.  LOVE 11.5 has no love.sensor
-- (that arrived in 12), the bundled SDL2 predates the STEAMDECK hidapi
-- driver, and SDL2 on Linux has no sensor backend at all.  The Deck's IMU
-- is also not an iio or evdev device -- /sys/bus/iio/devices holds only the
-- two ambient light sensors.  What there IS is /dev/hidraw*, where the
-- controller (Valve 28DE:1205) streams a 64-byte state report at 250 Hz,
-- and which udev ACLs to the console user.  So we read it ourselves.
--
-- Deliberately NOT a love.thread: a blocking read on a device that stops
-- reporting would hang LOVE's shutdown when the Thread's destructor joins
-- it.  Instead the fds are opened O_NONBLOCK and drained from the render
-- path, which costs a handful of read() calls that return EAGAIN.  There
-- is no wait anywhere in here, so nothing this module does can stall a
-- frame or block quitting.
--
-- The controller exposes three interfaces and only one carries the state
-- report, so all of them are opened and drained until one produces a report
-- we recognise; that one is kept and the rest are closed.  Racing them is
-- both simpler than probing in sequence and correct on the first frame,
-- where a per-candidate timeout would spend seconds deciding.
--
-- Report layout (the SDL "SteamDeckStatePacket" shape, byte offsets):
--     0  header 01 00 09 40
--     4  packet counter
--     8  buttons (64 bits)
--    16  left pad X,Y      20  right pad X,Y
--    24  ACCEL X,Y,Z       30  gyro X,Y,Z        36  orientation quat
--    44  raw triggers      48  sticks            56  pad pressures
-- 16384 counts = 1 g.
--
-- The IMU block is only written while Steam Input's active configuration
-- asks for gyro; otherwise offsets 24..43 arrive as hard zeroes and every
-- other field stays live.  That is a state worth naming rather than
-- treating as a failure, so it gets its own status ("ASLEEP") and the mod
-- falls back to stock rendering until it clears.

local V = ...

local Imu = {}

-- ------- libc, via LuaJIT's FFI
--
-- pcall'd all the way down: a non-LuaJIT host, or another mod that already
-- declared these symbols, must leave the mod inert rather than erroring out
-- of the whole load.

local ffi
local haveFfi = false
do
  local ok, mod = pcall(require, "ffi")
  if ok and mod then
    ffi = mod
    pcall(function()
      ffi.cdef [[
        int open(const char *pathname, int flags);
        long read(int fd, void *buf, unsigned long count);
        int close(int fd);
      ]]
    end)
    -- confirm the declarations actually landed (a redefinition error above
    -- is survivable if the symbols were already present, fatal if not)
    haveFfi = pcall(function() return ffi.C.close end)
  end
end

local O_RDONLY, O_NONBLOCK = 0, 2048 -- Linux; O_NONBLOCK is 0o4000

local REPORT = 64
local ACCEL_OFF = 24
local GYRO_OFF = 30

-- Gyro counts to radians/sec.  The Deck reports angular rate at the same
-- 16-bit scale as the accelerometer; this constant is approximate and only
-- sets the feel of the twist axis, which is integrated and leaked anyway.
-- Raw counts.  The scale lives in Motion, where it was measured; an earlier
-- 1/16.4 here came from an unrelated datasheet.
--
-- No bias constant: measured at rest it was rx +4.0 in one session and -1.0
-- in the next, so any fixed value is wrong half the time.  At 0.02 deg/s per
-- count a 4-count bias is 0.08 deg/s, which the accelerometer correction
-- absorbs long before it is visible.

-- Smallest accelerometer magnitude, in raw counts, that counts as a real
-- reading.  Only a floor against noise, NOT a scale: the vector is
-- normalised, so counts-per-g never has to be known.  Low enough to clear
-- the least sensitive plausible range (a +-16 g chip puts 1 g at ~2048
-- counts) with room to spare.
local MIN_COUNTS = 400

-- The magnitude error at which a sample is trusted about a third as much.
-- Generous, because the measured swing while tilting by hand is enormous --
-- 245% of the median -- so a tight value would distrust nearly everything.
local SHAKE_TOL = 0.45

-- how long the IMU block may stay zeroed before we call the sensor asleep,
-- and how long a dead scan waits before looking for the device again
local SLEEP_TIMEOUT = 1.5
local RESCAN_PERIOD = 2.0

-- reads drained per frame.  250 Hz against a 60 fps frame is ~4 reports, so
-- this is pure headroom for a stalled frame; the loop exits on the first
-- EAGAIN anyway.
local MAX_DRAIN = 64

-- ------- state
--
-- status is the single value the options row reports and the light mapping
-- gates on:
--   "NO FFI"  LuaJIT FFI unavailable -- mod inert
--   "NO DEV"  no Steam controller HID node we can read
--   "SEEK"    open, waiting for a report we recognise
--   "ASLEEP"  reports arriving, IMU block zeroed (enable gyro in Steam Input)
--   "LIVE"    real acceleration

Imu.status = haveFfi and "SEEK" or "NO FFI"
Imu.path = nil
Imu.x, Imu.y, Imu.z = 0, 0, 0 -- last good gravity DIRECTION (unit vector)

-- Angular rate about each axis, and a leaky integral of the Z rate.
--
-- The gyro is here because the accelerometer physically cannot see one
-- rotation: twisting the console about the screen normal leaves gravity
-- pointing exactly where it was.  Spin a Deck flat on a table and the
-- accelerometer reads the same vector throughout.  So gravity gives two
-- degrees of freedom and the gyro supplies the third.
--
-- Rate is integrated into `twist` rather than used raw, because a rate
-- controls a VELOCITY -- the light would slide while you turn and stop dead
-- when you stop -- whereas an angle controls a POSITION, which is what the
-- other axes give.  The integral leaks back to zero (LEAK below) since gyro
-- integration drifts without an absolute reference, and there is none for
-- this axis by definition.
Imu.rx, Imu.ry, Imu.rz = 0, 0, 0
Imu.twist = 0
Imu.rejectShake = true
Imu.trust = 1

local open = {}      -- { {path=, fd=}, ... } candidates still being raced
local chosen = nil   -- the one that spoke
local buf = haveFfi and ffi.new("uint8_t[?]", 256) or nil
-- Three separate clocks, and they must stay separate.  zeroClock measures
-- how long the IMU block has been all zeroes while the device is otherwise
-- talking; silentClock measures how long the device has produced no reports
-- at all.  Sharing one counter between them means an IMU that has been
-- asleep for a while is already over the teardown threshold, so the first
-- frame that happens to drain no reports rips the device down and reports
-- NO DEV on hardware that is plainly present.
local zeroClock, silentClock, rescanClock = 0, 0, 0
local magAvg       -- slow average of raw magnitude, for shake rejection
local debugClock, debugOn = 0, os.getenv("DECK_TILT_DEBUG") == "1"

-- DECK_TILT_FAKE=1 synthesises a slowly circling tilt in place of the
-- sensor.  It exists because the interesting half of this mod only runs
-- when the IMU is awake, and the IMU is asleep on any Deck whose Steam
-- Input configuration has not asked for gyro -- which is most of them, and
-- was this one.  Without it the light path could only be tested by the one
-- person with the right controller profile.  It is also the quickest way to
-- see what the effect actually looks like before deciding whether to go
-- turn gyro on.
local fakeOn = os.getenv("DECK_TILT_FAKE") == "1"
local fakeT0 -- first-poll timestamp; declared here so the wave stays local

local function debugf(fmt, ...)
  if not debugOn then return end
  io.write("[DECK_TILT] ", string.format(fmt, ...), "\n")
  io.stdout:flush()
end

-- ------- device discovery
--
-- Plain io, not love.filesystem: the latter is confined to the game and save
-- directories and cannot see /sys or /dev.  Probing a fixed range of node
-- numbers rather than listing the directory keeps this free of popen -- a
-- graphics mod has no business spawning processes.

local function scan()
  for i = 0, 15 do
    local f = io.open(("/sys/class/hidraw/hidraw%d/device/uevent"):format(i), "r")
    if f then
      local text = f:read("*a") or ""
      f:close()
      -- HID_ID=0003:000028DE:00001205 -- Valve, Steam Controller/Deck
      if text:find("28DE", 1, true) and text:find("1205", 1, true) then
        local path = ("/dev/hidraw%d"):format(i)
        local fd = ffi.C.open(path, O_RDONLY + O_NONBLOCK)
        if fd >= 0 then
          open[#open + 1] = { path = path, fd = fd }
        end
      end
    end
  end
  debugf("scan found %d candidate node(s)", #open)
  return #open > 0
end

local function closeAll()
  for _, c in ipairs(open) do ffi.C.close(c.fd) end
  open, chosen = {}, nil
  Imu.path = nil
end

-- Keep `keep` and close everything else.
local function latch(keep)
  for _, c in ipairs(open) do
    if c ~= keep then ffi.C.close(c.fd) end
  end
  open, chosen = { keep }, keep
  Imu.path = keep.path
  debugf("state reports on %s", keep.path)
end

-- ------- report parsing

local function int16(offset)
  local v = buf[offset] + buf[offset + 1] * 256
  if v >= 32768 then v = v - 65536 end
  return v
end

local function headerOk()
  return buf[0] == 0x01 and buf[1] == 0x00
     and buf[2] == 0x09 and buf[3] == 0x40
end

-- Drain one candidate.  Returns sawReport, live.
local function drain(c)
  local sawReport, live = false, false
  for _ = 1, MAX_DRAIN do
    local n = tonumber(ffi.C.read(c.fd, buf, 128))
    if n ~= REPORT then break end -- EAGAIN (-1) or a short/foreign report
    if headerOk() then
      sawReport = true
      local ax, ay, az = int16(ACCEL_OFF), int16(ACCEL_OFF + 2), int16(ACCEL_OFF + 4)
      if ax ~= 0 or ay ~= 0 or az ~= 0 then
        local mag = math.sqrt(ax * ax + ay * ay + az * az)
        -- A report too weak to have a direction in it is noise, not a
        -- posture.  This is the only magnitude test left, and it is
        -- deliberately loose -- see below.
        -- Weight each sample by how much it can be trusted, rather than
        -- accepting or discarding it.
        --
        -- An accelerometer reads gravity PLUS whatever the hands are doing.
        -- Measured on this device while tilting by hand, the magnitude swings
        -- through 245% of its median -- so a reading close to 1g is rare and
        -- a hard threshold throws away nearly everything.  That is what the
        -- first attempt did: it froze the estimate while it discarded, then
        -- jumped when one got through, which reads as the whole thing
        -- stuttering.
        --
        -- A continuous weight has no such edge.  Disturbed samples still
        -- move the estimate, just less, so it slows down under shaking
        -- instead of stopping and lurching.
        magAvg = magAvg and (magAvg + (mag - magAvg) * 0.01) or mag
        local off = magAvg > 0 and math.abs(mag - magAvg) / magAvg or 0
        local trust = math.exp(-(off / SHAKE_TOL) ^ 2)
        if not Imu.rejectShake then trust = 1 end
        Imu.trust = trust
        if mag >= MIN_COUNTS then

          -- NORMALISE, rather than divide by a counts-per-g constant.
          --
          -- What the mapping actually wants is which way down is relative
          -- to the screen: a direction, not a force.  Dividing by a fixed
          -- scale made the whole thing hostage to the chip's configured
          -- full-scale range, and that assumption was wrong -- gravity was
          -- arriving at about 0.37 of the assumed 16384 counts per g, so
          -- every real tilt came out under half its true size and the
          -- light could not be pushed past mid-screen no matter how far
          -- the console was turned.
          --
          -- A unit vector has no such dependency: whatever range the
          -- accelerometer is set to, a 30-degree tilt moves this by
          -- sin(30) = 0.5 on the axis that matters.
          Imu.x, Imu.y, Imu.z = ax / mag, ay / mag, az / mag
          Imu.counts = mag -- raw magnitude, for diagnostics only
          Imu.rx = int16(GYRO_OFF)
          Imu.ry = int16(GYRO_OFF + 2)
          Imu.rz = int16(GYRO_OFF + 4)
          live = true
        end
      end
    end
  end
  return sawReport, live
end

-- ------- the per-frame poll
--
-- Returns the gravity vector in g, or nil when there is nothing to trust.
-- Everything that can go wrong here degrades to nil and a status string;
-- no path errors.

-- `demo` forces the synthetic sweep for this call, so the MOTION row can
-- select it at runtime.  DECK_TILT_FAKE=1 still forces it globally, which is
-- what the headless tests and the launcher flag use.
function Imu.poll(dt, demo)
  dt = tonumber(dt) or 0

  if fakeOn or demo then
    local t = (love and love.timer and love.timer.getTime
               and love.timer.getTime()) or 0
    -- Measured from the FIRST poll, not from an arbitrary absolute clock, so
    -- the wave starts at zero. On HOLD the neutral pins to the first sample,
    -- and pinning it to a random point mid-swing biases the whole sweep --
    -- which made this mode look like it could not reach the frame edges when
    -- the mapping was fine.
    fakeT0 = fakeT0 or t
    local e = t - fakeT0
    -- Swings about a realistic RESTING hold rather than about flat, and
    -- with a negative Z like a real console held screen-up, so the demo
    -- exercises the same tangent range a pair of hands would.  Two
    -- incommensurate rates trace a figure rather than a circle.
    Imu.x = 0.55 * math.sin(e * 0.9)
    Imu.y = -0.52 + 0.48 * math.sin(e * 0.61)
    Imu.z = -math.sqrt(math.max(0.04, 1 - Imu.x * Imu.x - Imu.y * Imu.y))
    Imu.status = "FAKE"
    return Imu.x, Imu.y, Imu.z
  end

  if not haveFfi then return nil end

  if #open == 0 then
    -- Re-scan periodically rather than never: the controller can enumerate
    -- late, and a Deck woken from sleep comes back on a fresh node.
    rescanClock = rescanClock + dt
    if Imu.status ~= "NO DEV" or rescanClock > RESCAN_PERIOD then
      rescanClock = 0
      if not scan() then
        Imu.status = "NO DEV"
        return nil
      end
      Imu.status = "SEEK"
    else
      return nil
    end
  end

  local sawReport, live = false, false
  if chosen then
    sawReport, live = drain(chosen)
    if not sawReport then
      -- The node we settled on went quiet: it may have been unplugged or
      -- re-enumerated. Drop everything and start the search again.  Note
      -- this is its OWN clock -- a sleeping IMU is not a missing device.
      silentClock = silentClock + dt
      if silentClock > RESCAN_PERIOD then
        debugf("%s went silent, rescanning", tostring(Imu.path))
        closeAll()
        Imu.twist = 0
        Imu.status, silentClock, zeroClock = "NO DEV", 0, 0
      end
      return nil
    end
    silentClock = 0
  else
    -- Race the candidates; the first to produce a report we recognise wins.
    for _, c in ipairs(open) do
      local saw, isLive = drain(c)
      if saw then
        latch(c)
        sawReport, live = saw, isLive
        break
      end
    end
    if not sawReport then return nil end
  end

  if live then
    -- Leaky integral of the twist rate.  TAU is short enough that a held
    -- twist decays rather than parking the light at an edge forever, which
    -- is the only sane behaviour for an axis with no absolute reference.
    local LEAK = 2.5
    Imu.twist = (Imu.twist + Imu.rz * dt) * math.exp(-dt / LEAK)
    if Imu.twist > 2 then Imu.twist = 2 elseif Imu.twist < -2 then Imu.twist = -2 end
    Imu.status, zeroClock = "LIVE", 0
    if debugOn then
      debugClock = debugClock + dt
      if debugClock > 0.5 then
        debugClock = 0
        debugf("LIVE dir=(%+.3f %+.3f %+.3f) |raw|=%d counts",
          Imu.x, Imu.y, Imu.z, math.floor(Imu.counts or 0))
      end
    end
    return Imu.x, Imu.y, Imu.z
  end

  -- The device is talking, the IMU block is not.  Steam gates it on the
  -- active controller configuration asking for gyro.
  zeroClock = zeroClock + dt
  if zeroClock > SLEEP_TIMEOUT then
    Imu.status = "ASLEEP"
    Imu.twist = 0
    if debugOn then
      debugClock = debugClock + dt
      if debugClock > 2.0 then
        debugClock = 0
        debugf("reports on %s but the accel block is zero"
          .. " -- enable gyro in Steam Input for this game", tostring(Imu.path))
      end
    end
  end
  return nil
end

-- Whether the last poll produced acceleration worth steering by.
function Imu.isLive()
  return Imu.status == "LIVE" or Imu.status == "FAKE"
end

-- Drop the twist integral.  Called when the light mapping resets, and
-- whenever the device stops reporting: an integral with no absolute
-- reference cannot be trusted across a gap it did not observe.
function Imu.resetTwist()
  Imu.twist = 0
end

function Imu.shutdown()
  if haveFfi then closeAll() end
end

return Imu
