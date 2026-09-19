# Finally the Controller Works

Use Nintendo Switch 2 controllers on your Mac — Pro Controller 2,
Joy-Con 2 (solo or as a linked pair), and the NSO GameCube pad — over
Bluetooth, up to four at once. A native menu-bar app: launch it, press a
button on your controller, play. The first of its kind.

**Status: beta.** The release build is Developer ID-signed, notarized,
and your controllers show up as ordinary game controllers to every app
on the Mac — no per-game setup, no bridge, no relaunch tricks.

## System-wide controllers

Each connected controller becomes a real HID gamepad on the Mac
(CoreHID virtual devices, macOS 15+), so anything that reads a game
controller reads yours: Steam, emulators, browser games, native ports.
This is what the `com.apple.developer.hid.virtual.device` entitlement
buys, and **Apple has granted it** to this app — releases from v0.2.0
carry it in an embedded provisioning profile.

The older UDP path is still there and still runs alongside it: the app
publishes controller state on `udp://127.0.0.1:24800-24803` (one port
per player), and the patched SDL build in [`sdl/`](sdl/) reads it. You
no longer need it for normal use — keep it for SDL programs you want to
drive directly, or as a fallback if a game's own HID handling misreads
the virtual pad.

## Install

1. Download the `.dmg` from the
   [Releases page](https://github.com/Peterksharma/switch2mac/releases),
   open it, and drag **Finally the Controller Works** into Applications.
   Keep it there: macOS runs apps launched from Downloads out of a
   temporary read-only copy, where they can't install their own updates.
2. Launch it — it lives in the menu bar (game-controller icon).
3. Pair: hold the **Sync** button on the controller (next to the USB-C
   port) until the player LEDs sweep. After that first pairing, just
   press any button to reconnect.
4. Grant Bluetooth permission when macOS asks. That's the only required
   permission; Notifications and Accessibility are optional extras.

Requires macOS 15 (Sequoia) or later, on Apple Silicon.

The app auto-updates from this repository's releases (every update is
signature-verified before install).

## Using it with games and emulators

Start the app, connect a controller, launch the game. It appears in the
game's controller list like any USB pad — Gopher64, other emulators,
Steam titles, anything that speaks HID.

Two things the virtual pad does not carry: rumble (generic HID gamepads
have no standard rumble report on macOS) and motion. For those in an
SDL-based program, launch it against the patched SDL build in
[`sdl/`](sdl/), which reads the UDP feed and passes rumble back to the
controller — see [`sdl/README.md`](sdl/README.md) for the one-line
launch method.

## Features

**Working now, in the beta UI**

- System-wide virtual game controllers (CoreHID): every connected
  controller is a normal HID gamepad to every app on the Mac
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
- Signed auto-updates, first-run tour, settings import/export, live
  log with BLE gap diagnostics, launch-at-login

**Built, but hidden until they're polished**

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
  ./scripts/build-app.sh                  # full build incl. virtual gamepads
```

Output: `build/Finally the Controller Works.app`. Swift 6 toolchain,
macOS 15+ target, no external dependencies.

The virtual-gamepad path is entitlement-gated, so the full build needs a
Developer ID provisioning profile carrying
`com.apple.developer.hid.virtual.device`, saved as
`signing/FinallyTheControllerWorks.provisionprofile` (or pointed at with
`PROVISIONING_PROFILE=`). `./scripts/check-profile.sh` verifies a profile
— entitlement, App ID, team, expiry, certificate — before it gets
anywhere near a release; `./scripts/notarize.sh` builds, notarizes,
staples, and writes the appcast. An ad-hoc build still runs everything
else, with games served by the UDP/SDL path.

## Architecture

```
Controller ──BLE──> BridgeEngine ──> ControllerSession (per slot)
                       │  handshake, keep-alive, decode, rumble
                       ▼
              ControllerOutputSink protocol
               ├── VirtualHIDSink (CoreHID; system-wide gamepads)
               └── UDPHub        (SDL-compat, ports 24800-24803)
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
