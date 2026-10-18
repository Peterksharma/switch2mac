# Nintendo Switch 2 Controllers over Bluetooth LE — Protocol Notes

A practical reference for talking to Nintendo Switch 2 controllers (Pro
Controller 2, Joy-Con 2 L/R, and the NSO GameCube pad) over Bluetooth Low
Energy from a host that is **not** a Switch console.

This document covers connection, the command protocol, the input report
layout, motion/environmental sensors, rumble, LEDs, and pairing. It focuses on
what has been verified in practice, and calls out the platform quirks that
matter on macOS in particular.

> **Scope note.** NFC/amiibo is intentionally omitted here — that work is
> still in progress and will be published separately once it is fully worked
> out. Controller audio is covered in §10 to the extent it is currently
> understood (the wire framing is verified on real hardware; the codec is
> not yet identified). Everything else below is implemented and observed on
> real hardware.

Prior community reverse-engineering that this builds on is credited at the
end. Byte offsets are into the decrypted input report / command payloads.

---

## 1. Identification and discovery

Switch 2 controllers advertise over BLE with Nintendo's manufacturer data.

| Field | Value |
|---|---|
| BLE manufacturer company id | `0x0553` |
| USB/BLE vendor id | `0x057E` (Nintendo) |
| Pro Controller 2 PID | `0x2069` |
| Joy-Con 2 (Right) PID | `0x2066` |
| Joy-Con 2 (Left) PID | `0x2067` |
| NSO GameCube PID | `0x2073` |

**Manufacturer-data layout** (bytes after the 2-byte company id):

| Offset | Size | Meaning |
|---|---|---|
| 3 | 2 (LE) | vendor id (`0x057E`) |
| 5 | 2 (LE) | product id |
| 10 | 6 (LE) | reconnect host address; `0` = pairing mode (Sync held) |

The reconnect field is how you distinguish a controller advertising to *pair*
(held Sync, field is zero) from one advertising to *wake* toward a specific
already-bonded host (field is that host's Bluetooth address).

---

## 2. GATT characteristics

All interaction happens over a proprietary GATT service. The characteristics
of interest:

| Purpose | UUID |
|---|---|
| Input report (notify) | `ab7de9be-89fe-49ad-828f-118f09df7fd2` |
| Command write | `649d4ac9-8eb7-4e6c-af44-1ea54fe5f005` |
| Command response (notify) | `c765a961-d9d8-4d36-a20a-5315b111836a` |
| Vibration — Pro / GameCube | `cc483f51-9258-427d-a939-630c31f72b05` |
| Vibration — Joy-Con R | `fa19b0fb-cd1f-46a7-84a1-bbb09e00c149` |
| Vibration — Joy-Con L | `289326cb-a471-485d-a8f4-240c14f18241` |

**No SMP pairing.** The controller drops any link that attempts Bluetooth
SMP pairing/bonding. Connect without encryption; none of the characteristics
above demand it. "Bonding" is done at the application layer instead (§8).

All controller writes use **Write Without Response**.

---

## 3. Command protocol

Commands are framed with a shared 8-byte header ("the 0x91 protocol"):

```
byte 0 : command id
byte 1 : 0x91
byte 2 : 0x01           (transport: 0x01 = Bluetooth, 0x00 = USB)
byte 3 : subcommand id
byte 4 : 0x00
byte 5 : payload length
byte 6 : 0x00
byte 7 : 0x00
byte 8+: payload
```

Responses arrive on the command-response characteristic; the reply echoes the
command id at byte 0 and `0x01` at byte 1 on success, with the response
payload starting at byte 8.

Commands used here:

| Command | Sub | Purpose |
|---|---|---|
| `0x02` | `0x04` | Memory read |
| `0x09` | `0x07` | Set player LEDs |
| `0x0A` | `0x02` | Play built-in vibration preset |
| `0x0C` | `0x02` | Set feature mask |
| `0x0C` | `0x04` | Enable features |
| `0x15` | `0x01`/`0x04`/`0x02`/`0x03` | Pairing (set host MAC / LTK1 / LTK2 / finish) |

### Memory read

Payload: `len(1) 0x7e 0x00 0x00 addr(4 LE)`. Max read length `0x4F`. The
response echoes `len` at byte 0 and `addr` at bytes 4..8, with data from byte 8.

Useful addresses:

| Address | Contents |
|---|---|
| `0x00013000` | Controller info block (serial, VID/PID, colors) |
| `0x000130A8` / `0x000130E8` | Factory stick 1 / stick 2 calibration |
| `0x001FC042` / `0x001FC062` | User stick 1 / stick 2 calibration (`0xFFFFFF` if unset) |

### Feature mask

Two writes (set mask `0x0C/0x02`, then enable `0x0C/0x04`), each with a 4-byte
payload `flags 00 00 00`:

| Bit | Feature |
|---|---|
| `0x01` | Buttons |
| `0x02` | Sticks |
| `0x04` | Motion (IMU) |
| `0x10` | Optical mouse sensor (Joy-Con 2 only) |
| `0x20` | Battery current field |
| `0x80` | Magnetometer |

Practical masks: `0xB7` on Joy-Cons (buttons+sticks+motion+mouse+battery+mag),
`0xA7` on Pro/GameCube (no mouse bit). Note: `0xFF` induces phantom ZL/ZR bits
on Joy-Cons — enable specific bits, not all of them.

---

## 4. Connect handshake

The order that works reliably:

1. Connect (no SMP).
2. Subscribe to the command-response characteristic. **Must precede any
   command** — replies are correlated here.
3. Read the controller info block (identity: serial, PID, colors).
4. Read stick calibration (§6).
5. Set player LEDs.
6. Set + enable the feature mask (§3).
7. Subscribe to the input-report characteristic.

After this the controller streams input reports as notifications.

---

## 5. Input report

63–64 byte reports on the input characteristic. Offsets:

| Offset | Size | Field |
|---|---|---|
| `0x00` | 4 (LE) | timestamp |
| `0x04` | 4 (LE) | button bitmask (§5.1) |
| `0x0A` | 3 | left stick (packed 12-bit pair) |
| `0x0D` | 3 | right stick (packed 12-bit pair) |
| `0x10` | 2 (LE) | mouse X (absolute, wraps mod 2¹⁶) — Joy-Con 2 |
| `0x12` | 2 (LE) | mouse Y (absolute) — Joy-Con 2 |
| `0x14` | 2 (LE) | mouse surface quality ("roughness") |
| `0x16` | 2 (LE) | mouse lift distance (0 = no surface) |
| `0x19` | 6 | magnetometer X/Y/Z (3× i16 LE) |
| `0x1F` | 2 (LE) | battery voltage (mV) — see §5.2 |
| `0x21` | 1 | charge state (`0x00` on battery, Pro Controller 2) |
| `0x22` | 2 (LE, signed) | battery current (+ = charging; feature `0x20`) |
| `0x2E` | 2 (signed) | IMU die temperature (raw) |
| `0x30` | 6 | accelerometer X/Y/Z (3× i16 LE) |
| `0x36` | 6 | gyroscope X/Y/Z (3× i16 LE) |
| `0x3C` | 1 | left analog trigger (GameCube) |
| `0x3D` | 1 | right analog trigger (GameCube) |

Stick decode: three bytes → one little-endian 24-bit value; low 12 bits = X,
high 12 bits = Y, each 0–4095.

Temperature: `°C ≈ 25 + raw / 127`.
Magnetometer: AKM AK09919, ≈ `0.15 µT` per LSB (large hard-iron offset;
calibrate with a figure-8 min/max per device).

### 5.1 Button bitmask (32-bit LE)

```
0x00000001 Y        0x00000800 L-stick     0x00080000 D-Left
0x00000002 X        0x00001000 Home        0x00100000 SL (L)
0x00000004 B        0x00002000 Capture     0x00200000 SR (L)
0x00000008 A        0x00004000 C           0x00400000 L
0x00000010 SR (R)   0x00010000 D-Down      0x00800000 ZL
0x00000020 SL (R)   0x00020000 D-Up        0x01000000 GR
0x00000040 R        0x00040000 D-Right      0x02000000 GL
0x00000080 ZR       0x00000100 Minus       0x00000200 Plus
0x00000400 R-stick
```

ZL/ZR are digital bits on every model except the NSO GameCube pad, which
reports true analog triggers at `0x3C`/`0x3D`.

### 5.2 Battery level (Pro Controller 2)

The voltage field is not a usable charge estimate on Pro Controller 2: a
fully charged pad reads ~3.68 V on battery and ~3.70 V on the charger, so a
3.30–4.15 V linear map shows ~44% when the console shows full.

The firmware's own estimate is the Power Info byte at offset 1 of report
`0x09` (characteristic `7492866C-EC3E-4619-8258-32755FFCC0F8`):
bit 0 external power, bit 1 charging, bits 2–5 level. Observed on a full
pad: `0x20` unplugged (level 8), `0x23` on the charger (level 8, external
power, charging).

Constraints (measured on macOS): the characteristic is notify-only (a read
returns *Read Not Permitted*), and subscribing to it suspends the `0x05`
stream until it is unsubscribed. A one-packet subscribe/unsubscribe takes
~140 ms and pauses `0x05` for ≤ ~150 ms, about the size of ordinary BLE
gaps. The app samples it once during the handshake and then every 15 minutes
while the controller is idle.

---

## 6. Stick calibration

Calibration block (11 bytes): center X/Y, max X/Y, min X/Y, each a packed
12-bit pair (same encoding as the live sticks). Read the *user* slot first;
if its first three bytes are `0xFFFFFF` it is unset — fall back to the
*factory* slot.

Apply per axis: `signed = raw − center`; positive side scales by `max`,
negative side by `min`, clamped to ±1.

### Joy-Con quirk (worth knowing)

A single Joy-Con has **one** physical stick, but which report *field* it lands
in depends on handedness: the **left** unit reports its stick in the first
stick field (`0x0A`), the **right** unit in the second field (`0x0D`).
However, **both** store that stick's calibration in the *stick-1* slots — a
Joy-Con has no stick-2 calibration. So for the right Joy-Con you must read the
stick data from field 2 but calibrate it with the stick-1 calibration. Using
the (empty) stick-2 calibration on a right Joy-Con yields a stuck/dead axis.

---

## 7. Rumble and LEDs

**Player LEDs** — command `0x09/0x07`, payload `pattern 00 00 00`, where
`pattern` is a 4-bit mask of the four LEDs. Console-style player patterns:
P1 `0x01`, P2 `0x03`, P3 `0x07`, P4 `0x0F`, and so on.

**HD rumble** (Pro / Joy-Con — a linear voice-coil actuator) — write a motor
packet to the model's vibration characteristic. A packet carries a 1-byte
header (`0x50 + sequence`) followed by three identical 5-byte sub-frame
samples so the actuator runs continuously rather than pulsing; the Pro takes
two such blocks (left + right motors). Each 5-byte sample packs low/high
frequency and amplitude fields. Re-send at ~60 Hz to sustain an effect.

The NSO GameCube pad has **no** HD actuator (writing its motor characteristic
powers it off); it plays built-in presets via command `0x0A/0x02` instead.

---

## 8. Application-layer bonding

Because SMP is off, "remembering" a host is done with command `0x15`:

1. `0x15/0x01` — set host address (payload `00 02` + host MAC (LE) twice).
2. `0x15/0x04` — LTK half 1 (a fixed 17-byte key, `0x00` prefix).
3. `0x15/0x02` — LTK half 2 (fixed).
4. `0x15/0x03` — finish (`0x00`).

Afterward the controller stores the host address and will advertise to *wake*
toward it (§1) when a button is pressed — no re-pairing needed.

---

## 9. Platform note: the macOS keep-alive requirement

This appears to be undocumented elsewhere and is important for any
CoreBluetooth-based host.

On macOS, a connected Switch 2 controller's link is **silently terminated
≈10–17 seconds after the host's last write** to it, even while input reports
are still streaming inbound. Linux and Windows hosts do not exhibit this. The
practical fix is a **1 Hz keep-alive write** — re-issuing a harmless command
(e.g. re-setting the player LEDs) once per second holds the link open
indefinitely. Verified over multi-minute sessions with zero drops once the
keep-alive is in place, versus a hard drop at ~15 s without it.

A secondary macOS note: CoreBluetooth negotiates the connection interval
itself and gives the host no control over it, which caps the inbound report
rate near ~66 Hz (versus higher rates reachable on platforms that can request
tighter parameters).

---

## 10. Headset audio (Pro Controller 2, firmware 2.0+)

The Pro Controller 2's 3.5 mm jack is reachable over BLE through a dedicated
pair of characteristics — **separate from the rumble lane** (writing audio
does not officially drive the actuators, and rumble packets do not carry
audio):

| Direction | Characteristic | Properties |
|---|---|---|
| Host → jack (playback) | `CC483F51-9258-427D-A939-630C31F72B06` | write-no-response |
| Jack mic → host (capture) | `7492866C-EC3E-4619-8258-32755FFCC0F9` | read, notify |

Streaming is preceded by command `0x17/0x02` with payload
`80 BB 00 00 02 F0 00` = **48000 Hz (u32 LE), `0x02` (channels/mode), 240
samples per frame (u16 LE)** — i.e. nominal 5 ms frames. The controller ACKs
with an empty payload.

### Input notifications (verified on hardware)

Enabling notifications on the input characteristic yields 112-byte packets at
~28–33 Hz, each a miniature input report plus two embedded, length-prefixed
regions:

```
offset  content
 0      u8 sequence (+1 per packet — gaps are real losses)
 1      0x20 (report type)
 2–4    buttons (bitmask, as §5)
 5–10   left + right stick, packed 12-bit pairs
13      jack state: 0x00 nothing, 0x05 headphones, 0x07 headset (mic);
        bit 3 = this report carries an audio frame (alternates)
14      audio frame length (observed 0x32 = 50)
15–64   the audio frame; when idle: f8 ff fe + 47 zero bytes
65      telemetry length (observed 0x28 = 40, rarely 0x04)
66–105  packed motion/telemetry records: a 12-bit tick counter
        (1.25 ms units) + repeated ~88-bit records of slow sensor
        channels — NOT audio (a common mis-read: it is high-entropy)
```

**The codec of live audio frames is the open question.** 50-byte frames
against the configured 240-sample/5 ms PCM rate imply ~10:1 compression;
raw PCM, µ-law, IMA/DSP-ADPCM, Opus, and LC3 have all been ruled out
empirically against real captures. The DSP firmware blob in controller flash
(`MT3616A0`, MediaTek) suggests a vendor codec.

Two practical warnings, both verified: while input-characteristic capture is
enabled the controller **stops sending regular input reports** (buttons and
sticks freeze for the whole window), and the mic lane only produces non-idle
frames when a headset with a microphone is actually present.

### The USB shortcut

Over USB-C the same controller enumerates as a plain **USB Audio Class 1.0**
device — 48 kHz 16-bit stereo out to the jack, mono mic in, with standard
mute/volume controls — driverless on every OS. For "play audio through the
controller" as a feature (rather than as protocol research), USB is the
paved road; it also provides reference recordings for cracking the BLE codec
by known-plaintext comparison.

### Rumble addendum (cross-verified against console USB captures)

The §7 packet layout holds; two details worth recording: the 9-bit frequency
fields carry **direct Hz** (idle frame `E1 00 10 1E 00` = 225 Hz low band),
and the sequence nibble in the `0x50|seq` header must increment per packet —
the controller silently de-duplicates packets whose sequence has not
advanced. The console re-sends at ~5 ms; ~20–50 ms suffices to sustain a
steady tone.

---

## Credits

Protocol groundwork by the open-source community, including
ndeadly's Switch 2 controller research, the Nadeflore/Switch2Connect protocol
code, coffincolors' Joy-Con 2 mouse driver, trevlars' Linux bridge, and
darthcloud's BlueRetro. The macOS-specific findings (§6 right-Joy-Con
calibration split, §9 keep-alive requirement and interval note) and the
CoreBluetooth implementation are contributions of this project.
