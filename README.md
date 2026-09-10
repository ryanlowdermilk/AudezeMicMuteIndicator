# Mic Mute Indicator

A tiny Windows tray app that shows whether the **hardware mute switch** on an Audeze Maxwell
headset is on or off. Green means the mic is live, red means it is muted, gray means the
headset is not connected.

There is also an optional always-on-top overlay you can park on a second monitor, which is
the point of the whole thing: while you are in a fullscreen game you cannot see the tray, and
you want to know at a glance whether your mic is hot.

<!-- Add a screenshot here once you have one. -->

## Why this is harder than it sounds

The Maxwell's mute switch is **invisible to Windows**. It is not a normal mute button. On this
hardware:

| Detection method | Result |
| --- | --- |
| Core Audio endpoint mute flag (`IAudioEndpointVolume::GetMute`) | Never changes |
| HID input reports (Consumer, Telephony, and vendor collections) | Nothing is ever sent |
| HID feature reports on the vendor collection | None readable |

So there is no flag to query and no event to subscribe to. Audeze's firmware changelog mentions
syncing the switch to the Windows system mic mute, but that did not hold on the unit this was
developed against.

What the switch *does* do is make the firmware substitute **exact digital silence**.

## How it detects the switch

The app opens a shared-mode WASAPI capture stream on the Maxwell mic and looks at whether audio
data is arriving at all. Not how loud it is — whether it exists.

Measured over roughly four and a half minutes of live capture:

| State | Peak level | Samples exactly `0.0` | Windows entirely zero |
| --- | --- | --- | --- |
| Live, talking | up to 0.878662 | ~25% | 0 |
| Live, silent room | pinned at 0.000061 | ~25% | 0 |
| **Hardware muted** | **0.000000** | **100%** | **all of them** |

A live microphone is an analog capsule feeding an ADC, so it always dithers. Its noise floor sat
pinned at `0.000061`, which is exactly 1 LSB (`2/32768`), and across 1089 measurement windows it
never once reached zero. A muted mic is a different mechanism entirely: the firmware emits
literal zeros. These are not "quiet" and "quieter" — they are "data" and "no data".

That means **no amplitude threshold is involved**. A threshold would be actively dangerous here:
sit still in a quiet room and any reasonable threshold would falsely report you as muted while
your mic was hot.

One subtlety makes the rule precise. About a quarter of the individual samples in live speech are
exactly zero, because waveforms cross zero constantly. So the test cannot be "any sample is zero":

> A window counts as **muted** only if **every** sample in it is exactly `0.0`.
> If **any** sample is non-zero, the mic is **live**.

### Failure is biased on purpose

The two possible mistakes are not equally bad:

- Falsely showing **live** when muted — you talk, nobody hears you. Annoying.
- Falsely showing **muted** when live — you say something private believing you are safe. **Dangerous.**

So the logic is asymmetric:

```
any non-zero sample        -> LIVE immediately
400 ms of all-zero samples -> MUTED
stream stalls 3 s / device gone -> DISCONNECTED, retry every 2 s
```

The app defaults to **live** at startup, on reconnect, and under any uncertainty. It only claims
you are muted when it has positive evidence. The 400 ms debounce guards against startup and
reconnect glitches; it can only ever *delay* a muted indication, never cause a false one.

## Privacy

These apps hold an open microphone stream, so it is fair to be suspicious of them. To be explicit:

- **Audio is never recorded, stored, decoded, or transmitted.**
- Samples are read into an in-memory buffer, scanned for a single non-zero value, and overwritten
  by the next packet. Nothing derived from the audio leaves the process except a single
  three-state value: live, muted, or disconnected.
- The **tray app** contains no network APIs, no file I/O, no registry access, and no process
  spawning. Verify by grepping [src/MicMuteIndicator.cs](src/MicMuteIndicator.cs) for
  `System.Net`, `HttpClient`, `Socket`, or `File.`.
- The **Stream Deck plugin** opens exactly one network connection: a WebSocket to
  `ws://127.0.0.1:<port>`, which is how the Stream Deck SDK requires plugins to communicate with
  the Stream Deck application. It is loopback only, it is initiated by Stream Deck itself via
  command-line arguments, and the only thing sent over it is a rendered PNG of a colored key.
  There is no outbound internet traffic.

Two consequences you should know about:

1. Windows will show your microphone as permanently in use, and these apps will appear under
   **Settings → Privacy & security → Microphone**. That is unavoidable, because sampling the
   stream is the only way this hardware exposes the switch.
2. A *software* mute on the same endpoint also zeroes the stream, so it reads as muted too.
   That is arguably correct: what you want to know is "am I transmitting", not "which control
   caused it".

## Build

Requires nothing but Windows. It targets .NET Framework 4.8, which is built into Windows 10 and
11, and compiles with the C# compiler already present in `%WINDIR%\Microsoft.NET`.

```powershell
.\build.ps1
```

Produces a single self-contained `MicMuteIndicator.exe` of about 23 KB.

## Usage

Run `MicMuteIndicator.exe`. It has no window and no installer.

- A colored dot appears in the system tray. Windows 11 hides new tray icons by default, so you
  may need to click the `^` chevron and drag it onto the visible tray.
- Right-click the icon → **Show overlay on screen** for the on-monitor light. Drag it anywhere
  with the left mouse button; right-click it for the same menu.
- Right-click → **Exit** to quit.

The overlay is a per-pixel-alpha layered window, so it has no rectangular background — just a
rounded pill with a soft drop shadow that floats cleanly over Discord, games, or anything else.

| Overlay option | Effect |
| --- | --- |
| **Compact (dot only)** | Drops the text and shows just a glowing orb |
| **Click-through (uncheck to move it)** | The mouse passes straight through to the app underneath. Uncheck it to drag the overlay, then re-check it. |
| **Size** | Small / Medium / Large, scaling everything including the font |

Settings are not persisted; the overlay returns to its defaults on restart.

## Stream Deck plugin

An optional Stream Deck plugin turns a key into a full-bleed green/red mic indicator, which is
considerably easier to see mid-game than a tray icon.

```powershell
cd streamdeck
.\build.ps1
.\install.ps1
```

Then restart Stream Deck, and drag **Mic Mute Indicator** (in the *Audeze Mic Mute* category)
onto any key. Pressing the key does nothing by design — it is a pure indicator, and no software
can move a physical switch.

The plugin runs its own detection, so it works whether or not the tray app is running. Both can
coexist because WASAPI shared mode allows multiple capture streams. `streamdeck/build.ps1`
compiles `src/MicMuteIndicator.cs` alongside the plugin source and uses `/main:` to select the
entry point, so there is exactly one copy of the detection logic and the two cannot drift apart.

If Stream Deck is running elevated, `install.ps1` cannot restart it for you and will tell you to
quit and relaunch it yourself. Plugin load failures are logged to
`%APPDATA%\Elgato\StreamDeck\logs`.

| Color | Meaning |
| --- | --- |
| Green | Mic is live |
| Red | Hardware mute switch is on |
| Gray | Headset not connected |

## Diagnostic scripts

These are the tools used to work out how the switch behaves. They are included because they are
useful for adapting this to other headsets.

| Script | Purpose |
| --- | --- |
| `Test-MuteDetection.ps1` | Guided four-phase test that alternates the switch and prints a verdict on which detection method works |
| `Test-MicCapture.ps1` | Opens a real capture stream and shows live sample levels |
| `Test-MicMute.ps1` | Watches the Core Audio mute flag on every capture endpoint |
| `Dump-AudezeHid.ps1` | Dumps raw HID input reports from the dongle |

If you are adapting this, start with `Test-MuteDetection.ps1`. It will tell you whether your
headset is detectable via the endpoint mute flag, audio levels, or not at all.

**Note on `Test-MuteDetection.ps1`: you must keep talking during the muted phases.** An idle
live mic and a muted mic look identical if you are silent. Talking through the mute is the only
thing that separates them.

## Limitations

- Verified against an **Audeze Maxwell 2 on the 2.4 GHz USB dongle**. Other connection modes and
  other headsets are untested.
- The device is matched by the name substring `"Maxwell"`, in `MicMonitor("Maxwell")` in
  [src/MicMuteIndicator.cs](src/MicMuteIndicator.cs). Change it for a different headset.
- The digital-silence behavior is firmware-specific. A firmware update could change it, and other
  vendors may behave differently.
- If another application opens the mic in **exclusive mode**, this app's stream drops and the
  indicator goes gray rather than showing a stale state.
- The dongle re-enumerates when the headset wakes, so reconnection takes up to a couple of seconds.

## Disclaimer

This is a personal project. It is not affiliated with, endorsed by, or supported by Microsoft or
Audeze. "Audeze" and "Maxwell" are trademarks of their respective owner and are used here only to
describe hardware compatibility.

## License

[MIT](LICENSE)
