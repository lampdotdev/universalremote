Kind: companion, a remote for the household's TVs and speakers.
Look: Apple's TV remote: pure black, flat graphite round keys, white SF Symbols, a big rounded touch surface with a
clickpad ring, VOL and CH pills, Siri's colors swirling on the mic while it listens. Dark in light mode too: it's an
object. App keys are the device's own icons where it shares them, else a colored tile with the app's name.

# Universal Remote

One remote for whatever the house has: a Samsung TV, a Roku, a Sonos speaker, and more as Lamp adds them. Tap it,
use the Mac's keyboard, or talk to it ("open Netflix", "volume up five", "search YouTube for cat videos"). Siri and
Shortcuts can press its buttons, open apps or take a spoken request. Nothing needs a key or an account.

- **Your devices**: the name at the top is a menu of the devices found, with Your Devices… to look again. Nothing is
  looked for at launch: with nothing found, the remote opens on Your Devices, which says why it looks before the
  system asks about the local network (Look Around). Devices that answer but can't be controlled yet are listed
  under Not supported yet, with Add with Lamp: it copies a request for that device and opens the chat to paste it.
- **The example TV**: tries every key with nothing sent; the line under the remote says what each press would do.
- **A TV or a Roku**: the touch surface (swipe or tap, or the arrows round its ring), Back, Home, the mic,
  play/pause, VOL and CH, rewind, mute, source, settings, fast-forward, the apps, typing into the TV's search box
  (the keyboard key), and power. Each shows only where the device can do it: a Roku player has no power, volume or
  channels; a Roku TV does.
- **A Sonos speaker**: what's playing with its artwork, previous, play/pause, next, and a volume slider.
- **Voice**: on-device speech recognition, then LampAI: a quick decision for a one-press command, an app or another
  device, and a JSON plan of steps for anything more ("turn it up a lot and open YouTube").
- Mac keys: arrows, Return (OK), Escape or Delete (Back), Space (play), and the Remote menu's shortcuts.

## How it controls each device

Each kind of device is one file behind one protocol, `DeviceController` (Device.swift): what it can do (`abilities`:
`.navigate`, `.apps`, `.text`, `.volume`, `.channels`, `.source`, `.settings`, `.power`, `.speaker`) and how
(`send(key:times:)`, `appList()`, `open(app)`, `send(text:)`, `togglePower()`, `turnOn()`, `icon(for:)`, `wake()`,
`state`). The screen asks `hub.can(...)`, never which kind a device is. A new kind is one more file and one more case
in `HomeDevice.Kind`, `DeviceHub.controller(for:)` and `DeviceHub.search()`.

- **Samsung TV** (SamsungTV.swift, `TVRemote`): the TV's own remote channel, a WebSocket on 8002 (secure, with a
  token the TV hands back after the person chooses Allow on it, kept with the TV) or 8001. Keys are
  `ms.remote.control` clicks, apps open through `http://<tv>:8001/api/v2/applications/<id>` (else `ed.apps.launch`),
  the installed apps and their icons come from `ed.installedApp.get` and `ed.apps.icon`, and typing is
  `SendInputString`. Its certificate is trusted for its own address only (`LocalTrust`). Turning it on is Wake-on-LAN
  to its Wi-Fi address, which needs Power On with Mobile on the TV.
- **Roku** (Roku.swift, `RokuDevice`): Lamp's `LampRoku` block. Control by mobile apps must be Enabled on the Roku.
- **Sonos** (Sonos.swift, `SonosDevice`): its local UPnP control on port 1400: AVTransport (play, pause, next,
  previous, what's playing) and RenderingControl (volume, mute).
- **Example TV** (ExampleTV.swift): says what each press would do.

Finding them (`DeviceHub.search`): `LampNetwork.requestAccess()`, then `LampNetwork.find(bonjour: ["_sonos._tcp"])`. A
device that answered SSDP for `roku:ecp` is a Roku (`LampRoku.at`), one made by Samsung that answers on 8001 a Samsung
TV (`TVRemote.info(at:)`), one made by Sonos or advertising `_sonos._tcp` a Sonos; anything else with a maker or model
is Not supported yet (routers left out). capabilities.json has the app's own local network reason and the Sonos
Bonjour type.

## Putting it on the iPhone

The iPhone remote is this app made for both the Mac and the iPhone (`make_app_for` with
`{"devices": ["mac", "iphone"], "made": "native"}`; the TVs, Rokus and speakers it controls aren't devices it's put
on), one code: the views already keep what's the Mac's (`.commands`, `onKeyPress`, the window's size, opening
the chat) under `#if os(macOS)`. It talks to the devices itself, without the Mac. On an iPhone, LampNetwork finds
devices with SSDP sent to each address (a Samsung TV and a Roku answer it) and with the Bonjour types in
capabilities.json (a Sonos answers only that), so a new kind of device that's found by Bonjour adds its type there.
Voice and Siri work there as they are; the haptic on every press is already in `ContentView`.

## Code

- `App.swift`: the window and the Remote menu (Mac).
- `ContentView.swift`: the remote's face, the header's device menu and state, the Mac's keys.
- `RemoteButtons.swift`: `RemoteColors`, the key styles, `TouchSurface`, `PillRocker`, `SiriMicKey`, `AppTile`.
- `DeviceHub.swift`: the devices (LampStore `devices`, `selectedDevice`, `rokus`), choosing one, finding them, and
  routing keys, apps and words to the chosen one's controller.
- `Device.swift`: `HomeDevice`, `Ability`, `DeviceState`, `DeviceController`.
- `SamsungTV.swift`, `Roku.swift`, `Sonos.swift`, `ExampleTV.swift`: one kind each.
- `DevicesSheet.swift`: Your Devices (found, look again, not supported yet, the example TV).
- `SpeakerView.swift`: a speaker's face. `KeyboardSheet.swift`: typing on the TV.
- `VoiceListener.swift`, `VoiceCommands.swift`: listening and turning speech into presses. `Intents.swift`: Siri.

## Easy to change

- Another kind of device: a controller file as above. The device-control skill says how to work one out.
- The keys: `ContentView` (which keys, and the abilities they need) and `TVKey` in SamsungTV.swift.
- The look: `RemoteColors` and the key styles in RemoteButtons.swift.
- The apps on the keys: `TVApp.popular` and `DeviceHub.refreshApps`.
- What voice understands: `VoiceCommands.quick` and its plan prompt.
- A button that does several things (bedtime: open an app, wait, turn down the volume, power off later): a method on
  `DeviceHub` built from `send`, so the steps go in order to whichever device is chosen.
- A kids' mode: a list of allowed apps and a switch that shows only those keys and hides settings and source, kept in
  LampStore.
