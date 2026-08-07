-- Everything that makes the console vibrate, wired to this mod's own driver.
--
-- ------- this is a PORT, and it is deliberately faithful
--
-- The point of owning a rumble implementation here is the response curve in
-- lib/DeckRumble -- being able to reach the top of the motor with the quiet
-- effects while a hard hit is still louder than a cursor tick. That is an
-- argument about the MIXER. It is not an argument that CONTROLLER_RUMBLE
-- chose its events or its strengths badly, and it did not: the channel model,
-- the descending cascade on a hit taken, the lub-dub heartbeat under 20% HP,
-- the SFX table -- all of that is good work and all of it is reproduced here
-- at the same numbers.
--
-- So the authored strengths below are that mod's, on purpose. Changing them
-- while also changing the mixer would make it impossible to tell which of the
-- two was responsible for how the result feels. The curve is the variable;
-- everything else is held still.
--
-- Credit where due: CONTROLLER_RUMBLE by masterwebx (MIT), whose event
-- coverage and tuning this follows.
--
-- ------- why a port at all rather than a dependency
--
-- The user's requirement was to be able to switch the other mod off. With
-- both enabled the two would drive the motor from two mixers and the louder
-- would win at random, so pairing the features is what makes turning it off
-- lossless rather than a downgrade.
--
-- OWN RUMBLE ships OFF. With it off nothing here runs and the other mod is
-- untouched -- which is the only safe default while both are installed.

local V = ...

local RumbleEvents = {}

local R -- the driver, resolved lazily so load order cannot bite
local function drv()
  R = R or V.require("DeckRumble")
  return R
end

-- ------- the gates
--
-- Each mirrors a category the other mod also exposes, so a player moving
-- across finds the same switches. All of them are false while OWN RUMBLE is
-- off, which is what keeps this inert by default.
local function S()
  local ok, s = pcall(function() return V.require("Settings") end)
  return ok and s or nil
end
local function on()
  local s = S()
  return s and s.ownRumbleOn and s.ownRumbleOn() or false
end
local function gate(name)
  local s = S()
  if not on() then return false end
  if not (s and s.rumbleCategory) then return true end
  local ok, v = pcall(s.rumbleCategory, name)
  return ok and v or false
end
local function battleFxOn() return gate("battlefx") end
local function storyOn()    return gate("story") end
local function ambientOn()  return gate("ambient") end
local function menusOn()    return gate("menus") end

-- ------- the clock and the delayed queue
--
-- Several effects are a SEQUENCE rather than a pulse -- a hit taken descends
-- through three, an evolution swells and settles -- and a queue on the game's
-- own logic clock is how those are expressed without a coroutine per effect.
local TIME = 0
local queue = {}

local function now() return TIME end

local function enqueue(delay, left, right, frames, channel)
  queue[#queue + 1] = {
    at = now() + (delay or 0),
    left = left, right = right,
    frames = frames or 6,
    channel = channel or "impact",
  }
end
RumbleEvents.enqueue = enqueue

-- ------- the low-HP heartbeat
local heartbeat = { active = false, nextAt = 0, battle = nil }

local function playerHpRatio(battle)
  if not battle or not battle.player or not battle.player.mon then return 1 end
  local mon = battle.player.mon
  -- Gen 1 mons store max HP on stats.hp, not maxHP.
  local max = (mon.stats and mon.stats.hp) or mon.maxHP or mon.maxHp or 0
  if max <= 0 then return 1 end
  return (mon.hp or 0) / max
end

local function refreshHeartbeat(battle)
  if not ambientOn() then heartbeat.active = false return end
  if not battle then
    heartbeat.active, heartbeat.battle = false, nil
    return
  end
  heartbeat.battle = battle
  local ratio = playerHpRatio(battle)
  heartbeat.active = ratio > 0 and ratio <= 0.20
end

local function resetBattle()
  heartbeat.active, heartbeat.battle, heartbeat.nextAt = false, nil, 0
  drv().clearChannel("ambient")
end

-- ------- per-frame
function RumbleEvents.tick(dt)
  TIME = TIME + (dt or 0)
  if not on() then
    if #queue > 0 then queue = {} end
    return
  end
  local Rumble = drv()

  if #queue > 0 then
    local keep, t = {}, now()
    for _, item in ipairs(queue) do
      if item.at <= t then
        Rumble.setChannel(item.channel, item.left, item.right, item.frames)
      else
        keep[#keep + 1] = item
      end
    end
    queue = keep
  end

  -- stats.hp can change mid-turn, so this is re-read rather than latched
  if heartbeat.battle then refreshHeartbeat(heartbeat.battle) end

  if heartbeat.active and ambientOn() then
    if now() >= heartbeat.nextAt then
      local ratio = playerHpRatio(heartbeat.battle)
      -- faster and harder the further under 20% it goes
      heartbeat.nextAt = now() + (0.55 + ratio * 1.0)
      local soft = Rumble.hasActive(80)
      local beat = soft and 0.16
        or (0.34 + (0.20 - math.min(0.20, ratio)) * 1.2)
      Rumble.setChannel("ambient", beat, beat * 0.65, 6)
      enqueue(0.11, beat * 0.7, beat * 0.85, 5, "ambient") -- the "dub"
    end
  end

  Rumble.tick()
end

-- ------- screen-shake sync, the faithful layer
--
-- The engine already advances a Gen 1 screen shake; this reads it rather than
-- inventing a parallel one, so the motor and the picture cannot disagree.
local function syncBattleFx(fx)
  local Rumble = drv()
  if not battleFxOn() or not fx then
    Rumble.clearChannel("shake")
    return
  end
  local sx, sy = math.abs(fx.shakeX or 0), math.abs(fx.shakeY or 0)
  local hud = math.abs(fx.hudShakeX or 0)
  local strength = math.max(sx, sy) / 8
  if strength <= 0 and (fx.shake or 0) > 0 then strength = 0.35 end
  if strength <= 0 and hud > 0 then
    strength = (hud / 2) * 0.35
  elseif strength <= 0 and fx.hudShakeProg then
    strength = 0.2
  end
  if strength <= 0 then Rumble.clearChannel("shake") return end
  if strength > 1 then strength = 1 end
  -- heavier left on a vertical shake (damage), right on a horizontal one
  if sy >= sx then
    Rumble.setChannel("shake", strength, strength * 0.75, 2)
  else
    Rumble.setChannel("shake", strength * 0.75, strength, 2)
  end
end

-- ------- menus
local lastConfirmAt = 0
local CONFIRM_GAP = 0.04 -- debounce: a wrap and an SFX must not double-fire

local function pulseMove()
  if not menusOn() then return end
  local Rumble = drv()
  if Rumble.hasActive(80) then return end -- never tick over a real effect
  Rumble.pulse("ambient", 0.1, 0.12, 2)
end

local function pulseConfirm()
  if not menusOn() then return end
  local t = now()
  if (t - lastConfirmAt) < CONFIRM_GAP then return end
  lastConfirmAt = t
  local Rumble = drv()
  if Rumble.hasActive(100) then return end
  Rumble.pulse("story", 0.2, 0.24, 4)
end

local function anyPressed(input, buttons)
  for i = 1, #buttons do
    if input:wasPressed(buttons[i]) then return true end
  end
  return false
end

local function wrapCursorMenu(cls, confirmButtons)
  if not cls or type(cls.update) ~= "function" then return end
  local prev = cls.update
  function cls:update(dt)
    local input = self.game and self.game.input
    local before = self.index
    local confirmed = input and anyPressed(input, confirmButtons)
    prev(self, dt)
    if not input then return end
    if before ~= nil and self.index ~= nil and self.index ~= before then
      pulseMove()
    elseif confirmed then
      pulseConfirm()
    end
  end
end

-- ------- HP
local function pulseLose(ratio, amount)
  local danger = 1 - ratio
  local strength = math.min(1,
    0.22 + danger * 0.55 + math.min(0.25, (amount or 0.05) * 2))
  drv().setChannel("impact", strength, strength * 0.55, 3)
end

local function pulseGain(ratio, amount)
  local strength = math.min(0.85,
    0.2 + (1 - ratio) * 0.3 + math.min(0.25, (amount or 0.05) * 1.8))
  drv().setChannel("story", strength * 0.5, strength, 4)
end
RumbleEvents.pulseLose, RumbleEvents.pulseGain = pulseLose, pulseGain

-- ------- the SFX table
--
-- Sounds the engine emits that deserve a feel of their own: items, field
-- moves, slots, the surfing minigame. Kept as a table rather than a chain of
-- ifs so a new sound is one line.
local function pulse(channel, left, right, frames, allowed)
  if not allowed() then return end
  drv().pulse(channel, left, right, frames or 6)
end
local function later(delay, left, right, frames, channel, allowed)
  if not allowed() then return end
  enqueue(delay, left, right, frames, channel)
end

local SFX = {
  Get_Item1 = function()
    pulse("story", 0.28, 0.4, 9, storyOn)
    later(0.1, 0.18, 0.3, 6, "story", storyOn)
  end,
  Get_Item2 = function()
    pulse("story", 0.3, 0.42, 9, storyOn)
    later(0.1, 0.2, 0.32, 6, "story", storyOn)
  end,
  Get_Key_Item = function()
    pulse("story", 0.38, 0.5, 12, storyOn)
    later(0.12, 0.25, 0.4, 8, "story", storyOn)
  end,
  Dex_Page_Added = function()
    pulse("story", 0.22, 0.34, 8, storyOn)
    later(0.08, 0.16, 0.26, 5, "story", storyOn)
  end,
  Pokedex_Rating   = function() pulse("story", 0.2, 0.3, 10, storyOn) end,
  Ledge            = function() pulse("story", 0.35, 0.28, 7, storyOn) end,
  Ledge_Jump       = function() pulse("story", 0.3, 0.24, 5, storyOn) end,
  Cut              = function() pulse("story", 0.32, 0.4, 7, storyOn) end,
  Fly = function()
    pulse("story", 0.25, 0.38, 10, storyOn)
    later(0.15, 0.18, 0.28, 8, "story", storyOn)
  end,
  Teleport_Exit1   = function() pulse("story", 0.28, 0.35, 8, storyOn) end,
  Teleport_Enter1  = function() pulse("story", 0.22, 0.32, 8, storyOn) end,
  Push_Boulder = function()
    pulse("story", 0.55, 0.4, 12, storyOn)
    later(0.1, 0.35, 0.25, 8, "story", storyOn)
  end,
  Slots_Stop_Wheel = function() pulse("story", 0.22, 0.3, 5, storyOn) end,
  Slots_New_Spin   = function() pulse("story", 0.16, 0.22, 4, storyOn) end,
  Slots_Reward = function()
    pulse("story", 0.4, 0.5, 12, storyOn)
    later(0.12, 0.28, 0.38, 8, "story", storyOn)
  end,
  Faint_Fall       = function() pulse("story", 0.45, 0.35, 10, storyOn) end,
  Caught_Mon       = function() pulse("story", 0.35, 0.48, 10, storyOn) end,
}
RumbleEvents.SFX = SFX

-- ------- installation
function RumbleEvents.install(mod)
  local Rumble = drv()

  -- ---- the faithful shake layer
  local okB, BattleState = pcall(require, "src.battle.BattleState")
  if okB and BattleState then
    local prevUpdateFx = BattleState.updateFx
    if prevUpdateFx then
      function BattleState:updateFx(...)
        prevUpdateFx(self, ...)
        if on() then syncBattleFx(self.fx) end
      end
    end
    -- ball wobbles: AnimPlayer emits SFX_TINK at the start of each shake
    local prevAnim = BattleState.applyAnimEffect
    if prevAnim then
      function BattleState:applyAnimEffect(ev)
        prevAnim(self, ev)
        if not battleFxOn() then return end
        if not (ev and ev.effect == "SFX_TINK") then return end
        Rumble.pulse("impact", 0.32, 0.42, 5)
        enqueue(0.05, 0.18, 0.28, 4, "impact")
      end
    end
    -- battle menus
    local prevUpdate = BattleState.update
    if prevUpdate then
      function BattleState:update(dt)
        local input = self.game and self.game.input
        local phase = self.phase
        local beforeMenu, beforeMove = self.menuIndex, self.moveIndex
        local confirmed = input and anyPressed(input, { "a", "b", "select" })
        prevUpdate(self, dt)
        if not input then return end
        if phase ~= "menu" and phase ~= "moveSelect" then return end
        if (beforeMenu and self.menuIndex ~= beforeMenu)
            or (beforeMove and self.moveIndex ~= beforeMove) then
          pulseMove()
        end
        if confirmed then pulseConfirm() end
      end
    end
  end

  local okE, ElevatorShake = pcall(require, "src.world.ElevatorShake")
  if okE and ElevatorShake and ElevatorShake.update then
    local prevElevator = ElevatorShake.update
    function ElevatorShake:update(...)
      prevElevator(self, ...)
      if not battleFxOn() then return end
      if self.phase == "shake" then
        if (self.offset or 0) < 0 then
          Rumble.setChannel("shake", 0.28, 0.18, 2)
        else
          Rumble.setChannel("shake", 0.18, 0.28, 2)
        end
      end
    end
  end

  -- ---- menus
  for _, spec in ipairs({
    { "src.ui.Menu",        { "a", "b" } },
    { "src.ui.ListMenu",    { "a", "b", "select" } },
    { "src.ui.ChoiceBox",   { "a", "b" } },
    -- left/right cycle a value without moving the cursor row
    { "src.ui.OptionsMenu", { "a", "b", "left", "right" } },
  }) do
    local okC, cls = pcall(require, spec[1])
    if okC then wrapCursorMenu(cls, spec[2]) end
  end

  -- ---- battle
  mod.events:on("battle.started", function(payload)
    refreshHeartbeat(payload and payload.battle)
    if not battleFxOn() then return end
    local kind = payload and payload.kind
    if kind == "trainer" or kind == "link" then
      Rumble.pulse("impact", 0.45, 0.55, 10)
    else
      Rumble.pulse("impact", 0.28, 0.32, 7)
    end
  end)

  mod.events:on("battle.ended", function()
    if not on() then return end
    resetBattle()
    Rumble.clearChannel("impact")
    Rumble.clearChannel("ambient")
  end)

  mod.events:on("battle.damage_dealt", function(payload)
    if not battleFxOn() then
      refreshHeartbeat(payload and payload.battle)
      return
    end
    local target = payload and payload.target
    local toPlayer = target and target.isPlayer
    local base = toPlayer and 0.42 or 0.28
    local typeMult = (payload and payload.typeMult) or 10
    if typeMult > 10 then base = base * 1.35
    elseif typeMult < 10 then base = base * 0.7 end
    if payload and payload.crit then base = base * 1.45 end
    if toPlayer then
      -- a hit TAKEN descends: heavy, then lighter, then gone
      local heavy = math.min(1, base)
      Rumble.pulse("impact", heavy, heavy * 0.55, 8)
      enqueue(0.07, heavy * 0.7, heavy * 0.4, 6, "impact")
      enqueue(0.14, heavy * 0.4, heavy * 0.25, 5, "impact")
    else
      Rumble.pulse("impact", math.min(1, base * 0.85), math.min(1, base), 7)
      if payload and payload.crit then
        enqueue(0.06, math.min(1, base * 0.7), math.min(1, base * 0.85), 5,
                "impact")
      end
    end
    refreshHeartbeat(payload and payload.battle)
  end)

  mod.events:on("battle.fainted", function(payload)
    if not battleFxOn() then return end
    local battler = payload and payload.battler
    if battler and battler.isPlayer then
      Rumble.pulse("impact", 0.85, 0.75, 18)
      enqueue(0.1, 0.4, 0.35, 10, "impact")
    else
      Rumble.pulse("impact", 0.55, 0.65, 12)
    end
    refreshHeartbeat(payload and payload.battle)
  end)

  mod.events:on("battle.status_inflicted", function(payload)
    if not battleFxOn() then return end
    local heavy = payload and payload.target and payload.target.isPlayer
    Rumble.pulse("impact", heavy and 0.35 or 0.22, heavy and 0.28 or 0.2, 8)
  end)

  mod.events:on("battle.ball_thrown", function(payload)
    if not battleFxOn() then return end
    Rumble.pulse("impact", 0.22, 0.3, 6)
    if payload and payload.caught and storyOn() then
      enqueue(0.9, 0.4, 0.45, 10, "story")
    end
  end)

  mod.events:on("battle.move_used", function(payload)
    if not battleFxOn() then return end
    local battle = payload and payload.battle
    if not battle then return end
    -- only a click when animations are off, because no shake will play
    local animsOn = true
    if battle.animationsOn then
      local okA, isOn = pcall(battle.animationsOn, battle)
      if okA then animsOn = isOn end
    end
    if animsOn then return end
    if Rumble.channelActive("shake") then return end
    Rumble.pulse("impact", 0.12, 0.14, 3)
  end)

  mod.events:on("battle.exp_gained", function(payload)
    if not storyOn() then return end
    local strength = 0.14 + math.min(0.35, ((payload and payload.gained) or 0) / 400)
    Rumble.pulse("impact", strength * 0.7, strength, 6)
  end)

  for _, name in ipairs({ "battle.battler_switched", "battle.turn_started" }) do
    mod.events:on(name, function(payload)
      refreshHeartbeat(payload and payload.battle)
    end)
  end

  -- ---- story
  mod.events:on("pokemon.caught", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.4, 0.5, 12)
    enqueue(0.12, 0.3, 0.35, 8, "story")
  end)

  mod.events:on("pokemon.level_up", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.25, 0.35, 6)
    enqueue(0.08, 0.35, 0.45, 8, "story")
  end)

  mod.events:on("pokemon.evolved", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.35, 0.4, 10)
    enqueue(0.15, 0.5, 0.55, 16, "story")
    enqueue(0.35, 0.3, 0.35, 10, "story")
  end)

  mod.events:on("pokemon.move_learned", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.18, 0.22, 5)
  end)

  mod.events:on("pokemon.received", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.35, 0.45, 10)
  end)

  mod.events:on("trade.completed", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.4, 0.5, 12)
  end)

  mod.events:on("link.connected", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.3, 0.38, 8)
  end)

  mod.events:on("link.ended", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.22, 0.18, 7)
  end)

  -- ---- world
  mod.events:on("world.trainer_engaged", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.5, 0.55, 12)
  end)

  mod.events:on("world.blacked_out", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.9, 0.85, 24)
    enqueue(0.2, 0.5, 0.45, 16, "story")
    enqueue(0.4, 0.25, 0.2, 12, "story")
  end)

  mod.events:on("world.stepped", function()
    if not ambientOn() then return end
    if Rumble.hasActive(80) then return end
    Rumble.pulse("ambient", 0.08, 0.1, 2)
  end)

  mod.events:on("world.boulder_moved", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.4, 0.35, 10)
  end)

  mod.events:on("player.warped", function()
    if not storyOn() then return end
    Rumble.pulse("story", 0.2, 0.28, 7)
  end)

  -- ---- HP
  --
  -- Read off the SHOWN hp rather than the real value, so the grind tracks the
  -- bar draining on screen instead of firing once when the number changes.
  local lastHealAt = -1
  local function healFanfare()
    if not battleFxOn() then return end
    if lastHealAt >= 0 and (now() - lastHealAt) < 0.4 then return end
    lastHealAt = now()
    Rumble.pulse("story", 0.25, 0.42, 10)
    enqueue(0.08, 0.32, 0.5, 9, "story")
    enqueue(0.18, 0.2, 0.35, 7, "story")
  end

  local function shownRatio(battler)
    if not battler or not battler.mon then return 1 end
    local max = (battler.mon.stats and battler.mon.stats.hp) or 0
    if max <= 0 then return 1 end
    return math.max(0, math.min(1, (battler.shownHP or battler.mon.hp or 0) / max))
  end

  if okB and BattleState and BattleState.stepHPDrain then
    local prevDrain = BattleState.stepHPDrain
    function BattleState:stepHPDrain(...)
      local beforeP = self.player and self.player.shownHP
      local beforeE = self.enemy and self.enemy.shownHP
      local busy = prevDrain(self, ...)
      refreshHeartbeat(self)
      if not battleFxOn() then return busy end
      local function track(battler, before)
        if not battler or before == nil or battler.shownHP == nil then return end
        local after = battler.shownHP
        if after == before then return end
        local max = (battler.mon.stats and battler.mon.stats.hp) or 1
        local amount = math.abs(after - before) / math.max(1, max)
        local ratio = shownRatio(battler)
        if after < before then
          if battler.isPlayer then pulseLose(ratio, amount)
          else Rumble.setChannel("impact", 0.12, 0.18, 2) end
        elseif battler.isPlayer then
          pulseGain(ratio, amount)
        end
      end
      track(self.player, beforeP)
      track(self.enemy, beforeE)
      return busy
    end
  end

  local okP, PartyMenu = pcall(require, "src.ui.PartyMenu")
  if okP and PartyMenu and PartyMenu.update then
    local prevPartyUpdate = PartyMenu.update
    function PartyMenu:update(dt)
      local heal = self.heal
      local before = heal and heal.shown
      prevPartyUpdate(self, dt)
      heal = self.heal
      if not battleFxOn() then return end
      if heal and before ~= nil and heal.shown and heal.shown > before then
        local max = (heal.mon.stats and heal.mon.stats.hp) or 1
        local ratio = math.max(0, math.min(1, heal.shown / math.max(1, max)))
        pulseGain(ratio, (heal.shown - before) / math.max(1, max))
      elseif before ~= nil and not heal then
        healFanfare()
      end
    end
  end

  local okPk, Pokemon = pcall(require, "src.pokemon.Pokemon")
  if okPk and Pokemon and Pokemon.heal then
    local prevHeal = Pokemon.heal
    function Pokemon.heal(mon)
      local before = mon and mon.hp
      prevHeal(mon)
      if not mon or before == nil then return end
      healFanfare()
    end
  end

  -- ---- sounds
  mod.events:on("sound.played", function(payload)
    if on() then
      local n = payload and payload.name
      if n == "Heal_HP" or n == "Heal_Ailment" then
        healFanfare()
      elseif n == "Healing_Machine" and battleFxOn() then
        Rumble.pulse("story", 0.22, 0.34, 6) -- each ball lights on the machine
      elseif n == "Poisoned" and battleFxOn() then
        Rumble.pulse("impact", 0.3, 0.2, 6)
      end
    end
  end)

  mod.events:on("sound.played", function(payload)
    if not on() then return end
    local name = payload and payload.name
    if type(name) ~= "string" then return end

    local fn = SFX[name]
    if fn then fn() return end

    -- menu beeps from UIs that do not go through the wrappers above
    if name == "Press_AB" or name == "Swap" then pulseConfirm() return end

    -- Ball_Poof belongs to the catch when a battle owns it, and to the
    -- surfing minigame's finish when one does not
    if name == "Ball_Poof" then
      if battleFxOn() then Rumble.pulse("impact", 0.2, 0.28, 5)
      elseif storyOn() then Rumble.pulse("story", 0.2, 0.28, 5) end
      return
    end

    -- Yellow's voiced Pikachu PCM clips
    if name:match("^PIKACHU_PCM_") and storyOn() then
      Rumble.pulse("story", 0.28, 0.4, 8)
      enqueue(0.1, 0.18, 0.3, 6, "story")
    end
  end)
end

return RumbleEvents
