# Install by hand

Use `./install.sh` if you can. This page is for when you cannot.

Copy these files into `game/mods/DECK_TILT/` in the engine, keeping the
folders:

```
manifest.json  main.lua  LICENSE  NOTICE.md  README.md  install.sh
lib/*.lua
tests/deck_tilt_test.lua
docs/*
```

Copy nothing else. A `.git` folder or an editor backup does not belong in the
mod.

Start the game. The mod loads itself. Open `OPTIONS` and look for `SD-GYRO` as
the first row.

## Check it worked

```
cd <engine>/game
lua5.4 mods/DECK_TILT/tests/deck_tilt_test.lua
```

The last line says how many checks passed. Every one should pass.

## Remove it

Delete `game/mods/DECK_TILT/`. Nothing else is touched: the mod writes only to
its own folder and to its own settings.

## If a setting is left behind

Removing a mod leaves its entry in `game/options.lua`. It is harmless. The
game ignores settings for a mod that is not installed.
