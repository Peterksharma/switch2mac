# Finally the Controller Works

Use Nintendo Switch 2 controllers on your Mac — Pro Controller 2,
Joy-Con 2 (solo or as a linked pair), and the NSO GameCube pad — over
Bluetooth, up to four at once. A native menu-bar app: launch it, press a
button on your controller, play. The first of its kind.

**Status: beta.** The release build is Developer ID-signed and works
today. One honest caveat, explained below: until Apple approves the
app's driver entitlement, games can't see the controllers *directly* —
you use the provided SDL bridge for that (Gopher64 works now).

## The plan, and the Apple wait

The goal is for every controller to appear to macOS as a normal game
controller that any app can use (CoreHID virtual gamepads, macOS 15+).
That requires the `com.apple.developer.hid.virtual.device` entitlement,
which is **currently waiting on Apple's approval**. Until it arrives:

- Everything in the dashboard works: connection, battery, sensors,
  calibration, rumble, LEDs, button remapping, Joy-Con mouse mode.
- **To use controllers in a game or emulator**, the app publishes
  controller state over local UDP (`udp://127.0.0.1:24800-24803`, one
  port per player), and a patched build of SDL with an `SDL_S2UDP`
  joystick backend picks it up. Any SDL-based program launched with
  that library sees real game controllers — including rumble flowing
  back to the controller.

Once Apple's approval lands, the SDL step disappears and controllers
will just show up system-wide.

## Install

1. Download the latest release from the
   [Releases page](https://github.com/Peterksharma/switch2mac/releases),
   unzip, and drag **Finally the Controller Works.app** to Applications.
2. Launch it — it lives in the menu bar (game-controller icon).
3. Pair: hold the **Sync** button on the controller (next to the USB-C
   port) until the player LEDs sweep. After that first pairing, just
   press any button to reconnect.
4. Grant Bluetooth permission when macOS asks. That's the only required
   permission; Notifications and Accessibility are optional extras.

The app auto-updates from this repository's releases (every update is
signature-verified before install).

## Using it with Gopher64 (N64 emulator)

Gopher64 is SDL-based, so it works through the bridge today:

1. Get the patched SDL library from this repo: [`sdl/`](sdl/).
2. Launch Gopher64 with the patched library (see `sdl/README.md` for
   the exact launch command).
3. Start the menu-bar app, connect your controller, and it appears in
   Gopher64 as a standard game controller — sticks, buttons, and rumble.

The same recipe works for any SDL3-based emulator or game — see
[`sdl/README.md`](sdl/README.md) for the general one-line launch method.

## Using it with RetroArch

RetroArch on macOS doesn't use SDL for input, so the bridge above can't
reach it. Instead the app can feed RetroArch's built-in **Network
Gamepad** directly — no extra library, nothing to patch:

1. In RetroArch: **Settings → Network → Network Gamepad** → on. Leave
   the base port at 55400, and turn on **Network Gamepad User 1** (and
   2–4 for more players). Restart RetroArch.
2. In the menu-bar app's dashboard, open **Configuration** and turn on
   **Network gamepad output (RetroArch)**.
3. Load a game. Your controller drives the RetroPad for player 1
   directly (no "bind all" step needed) — sticks, D-pad, A/B/X/Y,
   L/R/ZL/ZR, stick clicks, +/−.

Caveats: RetroArch's network protocol is one-way (no rumble), and Home,
Capture, C, GL and GR have no RetroPad equivalent (use the app's
button remapper for those). RetroArch listens on all interfaces with no
authentication, so only enable its network gamepad on a network you
trust.

Looking ahead: RetroArch gained an SDL3 joypad driver upstream in
mid-2026, but the official macOS builds aren't compiled with it yet. If
that changes, the SDL bridge above will work with RetroArch too — with
rumble — by launching it with the patched `libSDL3` like any other SDL3
app, and the network gamepad becomes the fallback rather than the only
route.

## Features

**Working now, in the beta UI**

- Bluetooth connection for up to 4 controllers (Pro Controller 2,
  Joy-Con 2 L/R and linked pairs, NSO GameCube pad), auto-reconnecting
  on any button press once paired
- The 1 Hz keep-alive write that stops macOS silently dropping the link
  ~15 s in (empirically discovered; Linux/Windows don't need it)
- Live dashboard: input test, battery percentage with charge state,
  hidden-sensor readouts (temperature, voltage trend, runtime estimate)
- Motion instruments: attitude bubble, gyro bars, tilt-compensated
  compass
- Stick calibration (factory + user recenter), per-stick deadzones,
  axis inversion, trigger thresholds
- Rumble with per-controller intensity, player-LED patterns
- **Find My Controller** — LED chase + rumble pulse + Bluetooth
  proximity meter
- Button remapping per controller
- Joy-Con 2 **mouse mode** (the optical sensor, used flat on the desk)
- UDP/SDL bridge for games and emulators, with game rumble passthrough
- RetroArch network-gamepad output (no SDL needed; off by default)
- Signed auto-updates, first-run tour, settings import/export, live
  log with BLE gap diagnostics, launch-at-login

**Built, but hidden until they're polished (or until Apple approval)**

- Virtual system-wide game controllers (CoreHID) — blocked on the
  entitlement above
- Keyboard mapping (controller buttons → keystrokes, per-app profiles)
- Air-gesture macros, Reaction Draft party game, Sensor Challenges
- Protocol experiments: NFC/amiibo reading, controller-audio research

## Research

The protocol knowledge behind this app — including original
reverse-engineering of the Switch 2 controller BLE protocol and the
ongoing controller-audio investigation — is published in
[`research/`](research/). Start with
[research/README.md](research/README.md).

## Building from source

```sh
./scripts/build-app.sh                    # ad-hoc: everything except virtual HID
SIGN_IDENTITY="Developer ID Application: …" \
PROVISIONING_PROFILE=path/to.provisionprofile \
  ./scripts/build-app.sh                  # full build incl. virtual gamepads
```

Output: `build/Finally the Controller Works.app`. Swift 6 toolchain,
macOS 15+ target, no external dependencies.

## Architecture

```
Controller ──BLE──> BridgeEngine ──> ControllerSession (per slot)
                       │  handshake, keep-alive, decode, rumble
                       ▼
              ControllerOutputSink protocol
               ├── VirtualHIDSink (CoreHID; entitlement-gated)
               ├── UDPHub        (SDL-compat, ports 24800-24803)
               └── NetworkGamepadSink (network gamepad / RetroArch, 55400-55403)
```

- `Protocol/Switch2Protocol.swift` — the wire protocol, transport-free.
- `Bluetooth/` — CoreBluetooth engine + per-controller session state machine.
- `Output/` — the sinks.
- `UI/` — SwiftUI dashboard (status cards + live log) and menu bar.

## Support

If this saved your controller from a drawer:
[Buy me a coffee ☕](https://buymeacoffee.com/peterksharma)

Issues and captures (especially audio-related — see the research docs)
are very welcome.

## Credits

Protocol research: ndeadly/switch2_controller_research,
trevlars/switch2-controllers-linux (MIT), Nadeflore/switch2-controllers,
and the wider Switch 2 RE community.
macOS keep-alive discovery, CoreBluetooth port, and the research in
[`research/`](research/): this project.
