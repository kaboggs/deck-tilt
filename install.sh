#!/usr/bin/env bash
#
# Install Deck Tilt into a host engine.
#
# Usage: ./install.sh                  # find the engine, then install
#        ./install.sh <engine-dir>     # install into this engine
#        ./install.sh --uninstall      # remove the mod
#        ./install.sh --help
#
# <engine-dir> is the directory that holds `game/` and `love/`.
#
# The script copies a fixed list of files.  It never copies a file that the
# list does not name, so a .git directory or an editor backup stays behind.

set -euo pipefail

MOD_ID="DECK_TILT"
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# Every file the mod needs, and nothing else.  The verify step reads the same
# list, so a file added here is checked automatically.
FILES=(
  manifest.json main.lua LICENSE NOTICE.md README.md install.sh
  lib/AxisMap.lua lib/DeckSprite.lua lib/GbcLight.lua lib/GyroMenu.lua
  lib/HelpScreen.lua lib/Imu.lua lib/Motion.lua lib/Overlay.lua lib/Setting.lua
  lib/Settings.lua
  tests/deck_tilt_test.lua
  docs/axis-map.gif docs/world-light.gif docs/axis-map.png
  docs/help-page.png docs/sd-gyro-menu.png
)

say()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# A directory is a host engine when it has a mods directory to install into
# and the render module this mod hooks.  Both must be present: the first
# alone matches any LOVE game, and the second is what makes the mod do
# anything at all.
is_engine() {
  [ -d "$1/game/mods" ] && [ -f "$1/game/src/render/GBCFX.lua" ]
}

# Walk up from the source directory.  This is the case the script exists for:
# the archive was unpacked somewhere inside the engine tree, so the engine is
# a parent.
find_upward() {
  local d="$SRC"
  while [ "$d" != "/" ]; do
    if is_engine "$d"; then printf '%s\n' "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Fall back to a bounded search of the places a Deck keeps games.  Bounded and
# timed, because an unbounded find over a full disc is not worth the wait.
find_nearby() {
  local roots=("$HOME" /run/media/*/ ) hit
  hit="$(timeout 20 find "${roots[@]}" -maxdepth 5 -type d -name mods \
         -path '*/game/mods' 2>/dev/null | head -20 || true)"
  [ -n "$hit" ] || return 1
  while IFS= read -r m; do
    local root; root="$(dirname "$(dirname "$m")")"
    is_engine "$root" && printf '%s\n' "$root"
  done <<<"$hit" | sort -u
}

manifest_id() {
  [ -f "$1/manifest.json" ] || return 1
  sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/manifest.json" | head -1
}

version_of() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1/manifest.json" | head -1
}

# ---- arguments

TARGET=""
ACTION="install"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)   usage ;;
    --uninstall) ACTION="uninstall" ;;
    -*)          fail "unknown option: $1" ;;
    *)           [ -z "$TARGET" ] || fail "give one engine directory, not two"
                 TARGET="$1" ;;
  esac
  shift
done

# ---- check the source is complete before touching anything

for f in "${FILES[@]}"; do
  [ -f "$SRC/$f" ] || fail "$f is missing from $SRC -- the download is incomplete."
done

# ---- resolve the engine

if [ -n "$TARGET" ]; then
  TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" || fail "no such directory: $TARGET"
  is_engine "$TARGET" || fail "$TARGET is not a host engine.
It must contain game/mods and game/src/render/GBCFX.lua."
else
  if TARGET="$(find_upward)"; then
    say "Engine found above this directory."
  else
    say "Looking for the engine. This takes a few seconds."
    found="$(find_nearby || true)"
    count="$(printf '%s' "$found" | grep -c . || true)"
    if [ "$count" = "0" ]; then
      fail "no host engine found.
Give the path as an argument:
    $0 /path/to/engine
The engine directory holds game/ and love/."
    elif [ "$count" != "1" ]; then
      say "More than one engine found:"
      printf '    %s\n' $found
      fail "choose one and give it as an argument:
    $0 <one-of-the-above>"
    fi
    TARGET="$found"
  fi
fi

DEST="$TARGET/game/mods/$MOD_ID"
say "Engine:  $TARGET"
say "Mod:     $DEST"

# ---- uninstall
#
# Only ever removes a directory that identifies itself as this mod.  A path
# that does not is left alone, because a wrong delete here costs a save file.

if [ "$ACTION" = "uninstall" ]; then
  [ -d "$DEST" ] || { say "Not installed. Nothing to do."; exit 0; }
  got="$(manifest_id "$DEST" || true)"
  [ "$got" = "$MOD_ID" ] || fail "$DEST does not identify itself as $MOD_ID.
Refusing to remove it. Remove it by hand if you are sure."
  rm -rf -- "$DEST"
  say "Removed. Start the game again."
  exit 0
fi

# ---- refuse to overwrite something that is not this mod

if [ -d "$DEST" ]; then
  got="$(manifest_id "$DEST" || true)"
  if [ -z "$got" ]; then
    fail "$DEST exists and has no manifest.json.
Refusing to write over it. Move it away, then run this again."
  elif [ "$got" != "$MOD_ID" ]; then
    fail "$DEST holds a different mod ($got).
Refusing to write over it."
  fi
  say "Updating version $(version_of "$DEST") to $(version_of "$SRC")."
fi

# Already in place: the archive was unpacked straight into mods/DECK_TILT.
# Verify and stop, rather than copy a directory onto itself.
if [ "$SRC" = "$DEST" ]; then
  say "Already in the right place. Nothing to copy."
else
  mkdir -p "$DEST/lib" "$DEST/tests" "$DEST/docs"
  for f in "${FILES[@]}"; do
    cp -f -- "$SRC/$f" "$DEST/$f"
  done
  chmod +x "$DEST/install.sh"
fi

# ---- verify what actually landed

missing=0
for f in "${FILES[@]}"; do
  [ -f "$DEST/$f" ] || { say "missing after copy: $f"; missing=1; }
done
[ "$missing" = "0" ] || fail "the copy is incomplete. Check the permissions on $DEST."

# Run the mod's own tests, but only when both parts they need are present: a
# system Lua, and the engine's test harness.  Neither is needed to play, so a
# missing one is a skip and not a warning.  Output is captured rather than
# streamed, because a stack trace printed at the end of a successful install
# reads as a failed install.
if command -v lua5.4 >/dev/null 2>&1 && [ -d "$TARGET/game/tests/modkit" ]; then
  say "Running the tests."
  if out="$( cd "$TARGET/game" && DECK_TILT_MOD_PATH="mods/$MOD_ID" \
             lua5.4 "mods/$MOD_ID/tests/deck_tilt_test.lua" 2>&1 )"; then
    printf '    %s\n' "$(printf '%s' "$out" | tail -1)"
  else
    say "    The tests did not pass. The mod is installed. Please report this"
    say "    with the output of:"
    say "      cd $TARGET/game && lua5.4 mods/$MOD_ID/tests/deck_tilt_test.lua"
  fi
fi

say ""
say "Installed version $(version_of "$DEST")."
say ""
say "Next:"
say "  1. Start the game."
say "  2. Turn the gyro on. Push STEAM, open the controller settings for this"
say "     game, and set Gyro Behavior to a value that is not Off."
say "  3. Bind a rear button, in the same controller settings. Open Edit"
say "     Layout, then Back Grip Buttons, then L4, and set it to Left Ctrl."
say "     That button centres the light where you hold the console. It is"
say "     not necessary, but the mod is much easier to use with it."
say "  4. Set GBC FX to level 3 or level 4 in OPTIONS."
say "  5. Open OPTIONS, then SD-GYRO. The SENSOR row must read LIVE."
say ""
say "The engine enables a new mod by itself. To check this, open MODS in the"
say "start menu. That row shows an action, not a condition: it reads DISABLE"
say "when the mod is on. Push A once only."
