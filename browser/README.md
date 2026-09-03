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
pages and cannot load unpacked extensions. Firefox is not supported
either (different extension packaging); Chrome, Edge, Brave, Arc,
Vivaldi and Opera all work.

Verified on xbox.com/play with a Pro Controller 2: sticks, buttons,
triggers and rumble.

## If nothing shows up

Work down the list; each step depends on the one before.

1. **Is the app running with the bridge?** Open the dashboard log and
   look for `browser bridge on ws://127.0.0.1:24810`. If it says the
   port is busy, another copy of the app is running — quit it.
2. **Is the controller connected?** The menu-bar icon fills in and the
   dashboard shows the player. If not, press any button (paired) or
   hold Sync next to the USB-C port (new controller).
3. **Is the extension loaded and enabled?** `chrome://extensions` must
   list *Finally the Controller Works — Browser Bridge* with the toggle
   on, no red error badge. After editing any file in `extension/`,
   click its reload icon.
4. **Is the site in the list?** The extension only runs on the sites in
   `manifest.json` → `matches`. Add yours and reload the extension.
5. **Reload the game tab.** The shim installs when the page loads; a tab
   that was open before the extension loaded never gets it.
6. **Still nothing?** Open <https://hardwaretester.com/gamepad> — it is
   in the list — and press a button. If the pad appears there but not
   in the game, the game is the problem (some sites ignore gamepads
   that connect after the page loaded: reload with the controller
   already on). If it does not appear there either, open the tab's
   DevTools console and look for `ftcw` errors, then file an issue with
   that output.

The service worker's own console (`chrome://extensions` → *Inspect
views: service worker*) shows the WebSocket state if you need to go
deeper.

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
| 18 / 19 / 20 | — | C / GL / GR (only with `EXTRA_BUTTONS = true` in `shim.js`) |

Button remapping in the app's dashboard applies before the bridge, so
custom layouts carry over.

## Identity (persona)

Sites read the vendor id out of `gamepad.id` and choose glyphs and
vendor-specific handling from it. By default the pad keeps its real
identity (*Pro Controller 2 … Vendor: 057e*). `PERSONA_DEFAULT` in
`shim.js` switches every site to an *Xbox Wireless Controller* identity,
and a single site can be overridden from its DevTools console with
`localStorage.ftcwPersona = 'xbox'` (or `'nintendo'`; remove the key to
reset), then a reload. GeForce NOW sends an "is Xbox" flag to its servers
with every input packet, so try the Xbox identity there if sticks feel
off.

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
