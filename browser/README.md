# The browser bridge

Use Switch 2 controllers in **web games** — Xbox Cloud Gaming
(xbox.com/play), GeForce NOW, Amazon Luna, any page that uses the
Gamepad API — today, without waiting for Apple's virtual-HID approval.

Browsers only see gamepads that macOS knows about, and a Switch 2
controller over Bluetooth LE is not a HID device macOS can pair with
(that is why it never appears in System Settings → Bluetooth). Until the
app can create system-wide virtual controllers, this bridge does for the
browser what the SDL bridge does for emulators:

```
Controller ──BLE──> menu-bar app ──ws://127.0.0.1:24810──> extension ──> navigator.getGamepads()
                                <──────── rumble ─────────────────── vibrationActuator
```

| File | What it is |
|---|---|
| `extension/manifest.json` | Manifest V3 extension for Chrome, Edge, Brave, Arc, Vivaldi, Opera — any Chromium browser. |
| `extension/background.js` | Service worker that owns the WebSocket to the app (auto-reconnects). Lives in the extension, so Chrome's *Local Network Access* permission (Chrome 138+) never prompts or blocks. |
| `extension/bridge.js` | Content script relaying messages between the service worker and the page. |
| `extension/shim.js` | Wraps `navigator.getGamepads()` with standard-mapping virtual gamepads and forwards rumble. |

## Install (about a minute)

1. Run the menu-bar app (v0.4+ / this branch). The log shows
   `browser bridge on ws://127.0.0.1:24810`.
2. In your Chromium browser open `chrome://extensions`
   (`edge://extensions`, `brave://extensions`, …), switch on
   **Developer mode**, click **Load unpacked**, and choose this
   `browser/extension` folder.
3. Open <https://hardwaretester.com/gamepad>, press a button on the
   controller: it appears as *Pro Controller 2 (STANDARD GAMEPAD …)*
   with the standard layout.
4. Open <https://www.xbox.com/play> and play. Rumble works.

Safari is not supported: it blocks `ws://` connections from `https://`
pages and cannot load unpacked extensions.

## Layout

Buttons are mapped **by position** so on-screen Xbox prompts match your
thumb: the bottom face button (Switch **B**) is standard index 0 (Xbox
**A**), the right one (Switch **A**) is index 1 (Xbox **B**), and so on.
If you prefer label mapping (Switch A → Xbox A), set `NINTENDO_LABELS`
to `true` at the top of `shim.js` and reload the extension.

| Standard index | Xbox name | Switch 2 control |
|---|---|---|
| 0 / 1 / 2 / 3 | A / B / X / Y | B / A / Y / X |
| 4 / 5 | LB / RB | L / R |
| 6 / 7 | LT / RT | ZL / ZR (analog on the GameCube pad) |
| 8 / 9 | View / Menu | − / + |
| 10 / 11 | LS / RS | stick clicks |
| 12–15 | D-pad | D-pad |
| 16 | Xbox | Home |
| 17 | Share | Capture |
| 18 / 19 / 20 | — | C / GL / GR |

Button remapping in the app's dashboard applies before the bridge, so
custom layouts carry over.

## Adding a site

The extension only injects into the sites listed in `manifest.json`
(`matches`). Add a pattern for another game site, then reload the
extension. Multiple tabs may be connected at once; each gets the same
controllers.

## Protocol

JSON text frames on `ws://127.0.0.1:24810`, loopback only:

```
hub → page   {"t":"hello","v":1}
             {"t":"connected","slot":0,"model":"Pro Controller 2","name":"…"}
             {"t":"name","slot":0,"name":"…"}
             {"t":"state","slot":0,"seq":123,"b":<buttons u32>,
              "lx":…,"ly":…,"rx":…,"ry":…,"lt":0-255,"rt":0-255}   (+y = up)
             {"t":"disconnected","slot":0}
             {"t":"ping"}                                   every 15 s
page → hub   {"t":"rumble","slot":0,"strong":0…1,"weak":0…1}
```

`b` uses the app's `Switch2.Buttons` bit layout
(`Sources/FinallyTheControllerWorks/Protocol/Switch2Protocol.swift`).
New clients get `hello` plus a `connected` per active player. Anything
that speaks WebSocket can subscribe — the extension is just the
reference client.
