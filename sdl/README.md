# The SDL bridge (S2UDP)

Since v0.2.0 the app presents controllers as system-wide HID gamepads,
so most games need nothing from this folder. It stays useful for two
things the generic virtual pad cannot carry: **rumble** and **motion**.
An SDL3 program launched against this library gets both, straight from
the app's UDP streams.

| File | What it is |
|---|---|
| `libSDL3.0.dylib` | SDL 3.4.14 with our added **S2UDP joystick backend** — reads the menu-bar app's UDP controller streams and presents them as normal SDL gamepads, rumble included. Apple Silicon (arm64) only. |
| `sdl3-3.4.14-s2udp.patch` | The complete source patch against SDL `release-3.4.14` (commit `147a8ee`), for provenance and for anyone who wants to rebuild or port it. |
| `make-gopher64-both.sh` | Assembles **Gopher64-Both.app** from an installed Gopher64 + this dylib (details below). |

## How it works

The menu-bar app broadcasts each connected controller on
`udp://127.0.0.1:24800–24803` (one port per player). The patched SDL
adds a joystick backend that subscribes to those ports:

- State packets (bridge → SDL, 44 bytes LE): magic `S2B1`, sequence,
  buttons, stick floats, triggers, battery, gyro, accel.
- Rumble packets (SDL → bridge, 6 bytes): magic `S2R1`, strong, weak —
  so game rumble reaches the real controller.
- Controllers hot-plug in SDL as their UDP streams start and stop.
- Escape hatch: set `SDL_S2UDP_DISABLE=1` to turn the backend off.

## Using it with Gopher64

Gopher64 statically links SDL, but SDL ships an official override hook
(`SDL3_DYNAMIC_API`) that redirects every SDL call into an external
dylib. The script wraps that up:

```sh
./sdl/make-gopher64-both.sh
```

It copies your installed `/Applications/Gopher64.app` to
`~/Applications/Gopher64-Both.app`, drops the dylib into the bundle's
`Frameworks/`, sets `SDL3_DYNAMIC_API` via `LSEnvironment`, and
re-signs the copy ad-hoc (required: hardened-runtime library validation
would otherwise reject the outside dylib). Your original Gopher64 app
is never touched. Launch **Gopher64-Both** from Finder — the
`LSEnvironment` injection only applies to Finder/`open` launches.

## Using it with any other SDL3 app

```sh
SDL3_DYNAMIC_API=/path/to/libSDL3.0.dylib ./the-game
```

Works for any program whose statically-linked SDL3 is at or below the
3.4.14 ABI. For bundled `.app`s, replicate what the script does
(Frameworks/ + LSEnvironment + ad-hoc re-sign).

## License

Based on **SDL 3.4.14** (`release-3.4.14`, commit `147a8ee`) by Sam
Lantinga and the SDL contributors, under the
[zlib license](https://github.com/libsdl-org/SDL/blob/main/LICENSE.txt).
This build is **modified** — it adds the S2UDP joystick backend and
macOS wired-USB handling for Switch 2 pads — and is **not an official
SDL build**. The full modification is `sdl3-3.4.14-s2udp.patch`.
