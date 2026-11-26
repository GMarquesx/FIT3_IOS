# Elo: a Galaxy Fit3 on an iPhone

**I bought a Samsung Galaxy Fit3 without noticing it only works with Android. I have an iPhone.**
Instead of returning it, I reverse-engineered the band's Bluetooth protocol and wrote my own iOS app for it.

Elo talks to the band directly over Bluetooth LE, speaking Samsung's own protocol. It does what the official
app does on Android: notifications, heart rate, steps, SpO₂, music control, watch faces and widgets. It also
writes everything to Apple Health.

<!-- Demo: add a short screen recording or GIF here, e.g. docs/media/demo.gif -->

## What it does

| | |
|---|---|
| **Notifications** | Forwards WhatsApp/Messages/Instagram notifications (via an iOS Shortcuts automation) with a short buzz, a cooldown and a sleep mode |
| **Health sync** | Answers the band's health handshake like Samsung Health would, receives its sync data (heart-rate history with per-minute bins; steps, SpO₂ and calories go through the same path) and acknowledges each batch |
| **Apple Health** | Writes steps, distance, active energy, heart rate and SpO₂ with `HKMetadataKeySyncIdentifier`, so re-syncs replace samples instead of duplicating them |
| **Music** | The band's music screen shows the current Apple Music track; play/pause and skip on the band control the Music app |
| **Watch faces and widgets** | Lists the installed faces and switches them; turns widgets on and off, reorders and restores them |
| **Live heart rate** | On demand or on a schedule (15/30/60 min), to save battery on the band and on the phone |
| **Developer console** | Every frame in and out, with labels, filters and `.jsonl` export. This was the main reverse-engineering tool |

The UI is SwiftUI, in English and Portuguese, with an interactive 3D model of the band rendered with plain
`projectionEffect` transforms.

## How the protocol was figured out

There's no public documentation, so this was done the same way you'd approach unknown hardware in a lab:
observe first, form a hypothesis, test it on the device, and only then look for confirmation.

```mermaid
flowchart LR
    A[BLE sniffer on the PC<br/>Python + bleak] --> B[Frame format<br/>LEN · CRC16 · payload · CRC16]
    B --> C[Hand-crafted frames<br/>sent one by one]
    C --> D[Channels that answer<br/>time, battery, buzz, notifications]
    D --> E[Static analysis of the<br/>official Android plugin]
    E --> F[Full channel map,<br/>health, music, faces]
    F --> G[iOS app replays the<br/>handshakes and parses the data]
```

1. **Sniffing.** A Python BLE explorer (`tools/fit3_sniffer.py`) subscribed to every characteristic and logged
   every byte. The band speaks Samsung Accessory Protocol (SAP) over a custom GATT service.
2. **Frame format.** The frames turned out to be `LEN (2) | CRC16(LEN) | PAYLOAD | CRC16(PAYLOAD)`, with
   CRC-16/ARC. The payload is `dir 40 | channel channel | command | data`. Responses set bit 6 of the command.
3. **Testing frames by hand.** Each guess was sent to the band and checked against its reaction. That's how
   time sync, battery, the "find my band" buzz, notifications and the band's language were decoded.
4. **Reading the official plugin.** Decompiling the Android plugin gave the real names behind the numbers:
   SAP channels are service IDs, health uses a tag/value format, and timestamps count seconds since **1990**,
   not 1970. Every finding was still confirmed against a live capture before it went into the app.
5. **Closing the loop.** The band only syncs health data after a capability exchange with "Samsung Health".
   Elo now answers that exchange, reassembles fragmented SAP messages and acknowledges each sync.

Full notes are in [`PROTOCOLO.md`](PROTOCOLO.md) (Portuguese).

### Protocol at a glance

```
Frame     00 08 C6 01 | 01 40 0A 0A 03 E0 0E 29 | AF DC
          LEN   CRC     dir   ch ch cmd data       CRC
```

| Channel | Service | Used for |
|---|---|---|
| `0x01` | OOBE | Time sync, device info, setup |
| `0x06` | Watch faces | List, switch, reorder |
| `0x07` | Notifications | Title, body, app, icons |
| `0x09` | Music | Track info, playback state, buttons, volume |
| `0x0A` | Health | Handshake, capability, sync data, large data |
| `0x0B` | Settings | Battery, language |
| `0x0F` | Widgets | List and set order |
| `0x1F` | Find | Buzz |

## Tech stack

- **iOS app:** Swift, SwiftUI (iOS 17), CoreBluetooth with state restoration, HealthKit, App Intents
  (Shortcuts actions), MediaPlayer, CoreLocation (workout routes)
- **Tooling:** Python + bleak (BLE sniffer and frame codec), jadx (static analysis), Android HCI snoop parsing
- **Build:** XcodeGen and GitHub Actions on macOS. CI produces an unsigned `.ipa` with the HealthKit
  entitlement embedded, then it's sideloaded with a free Apple ID

## Repository

```
ios/            Elo, the iOS app (SwiftUI)
  Elo/          Sources, localization, fonts, assets
  project.yml   XcodeGen project
tools/          BLE sniffer and frame codec (Python)
  history/      Earlier sniffer versions, kept to show how the decoding evolved
android/        Helpers to pull and parse an Android Bluetooth HCI log
PROTOCOLO.md    Protocol notes
```

## Building

The app is built in CI (`.github/workflows/ios.yml`). Download the `.ipa` from the latest run and sideload it,
for example with Impactor (keep "Only Register Main Bundle" checked so the HealthKit entitlement survives).

To build locally on a Mac: `brew install xcodegen`, run `cd ios && xcodegen`, then open `Elo.xcodeproj`.

## Disclaimer

Personal, educational project. Not affiliated with or endorsed by Samsung or Apple. No Samsung code or
binaries are included in this repository.

---

Made by **Gabriel Marques**, a validation engineer in automotive electronics who likes building things that
talk to hardware. [LinkedIn](https://www.linkedin.com/in/) · [GitHub](https://github.com/GMarquesx)
