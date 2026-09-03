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

- **To use controllers in a web game** — Xbox Cloud Gaming, GeForce NOW,
  Luna — the app also serves controller state on
  `ws://127.0.0.1:24810`, and a small browser extension in
  [`browser/`](browser/) presents them to the page as standard
  gamepads, rumble included. Chromium browsers only.

Once Apple's approval lands, the SDL and browser steps become optional
and controllers will just show up system-wide.

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

## Using it with Xbox Cloud Gaming (or any web game)

Verified on xbox.com/play. Chromium browsers only (Chrome, Edge, Brave,
Arc, Vivaldi, Opera); Safari and Firefox cannot run this bridge.

1. Get the extension folder: clone this repo, or download the ZIP from
   GitHub (**Code → Download ZIP**) and unpack it. You need the
   [`browser/extension`](browser/extension) folder.
2. In the browser open `chrome://extensions` (`edge://extensions`,
   `brave://extensions`, …), turn on **Developer mode** (top right),
   click **Load unpacked** and pick that `browser/extension` folder.
3. Start the menu-bar app and press a button on the controller so it
   connects.
4. Open <https://www.xbox.com/play> and play: the controller is a
   standard gamepad, with rumble. Xbox prompts match the physical
   positions (Switch B is where Xbox A is).

Button table, adding other game sites, troubleshooting and the wire
protocol are in [`browser/README.md`](browser/README.md).

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
- WebSocket/browser bridge for web games (Xbox Cloud Gaming, GeForce NOW),
  with rumble passthrough
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
               └── WebSocketHub  (browser extension, ws://127.0.0.1:24810)
```

- `Protocol/Switch2Protocol.swift` — the wire protocol, transport-free.
- `Bluetooth/` — CoreBluetooth engine + per-controller session state machine.
- `Output/` — the two sinks.
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
