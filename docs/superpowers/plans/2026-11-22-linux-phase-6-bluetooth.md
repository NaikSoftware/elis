# Linux Phase 6: the phone's Bluetooth link

Status: plan, 2026-11-22, on master `ec05a1c4` (PR #73: the Swift relay on Linux).
Fills the stub at the end of `2026-11-22-linux-phase-4-5-attach-relay.md`.

## Shape

The wire is the Mac's, byte for byte, so one phone app talks to both: the rotating service UUID, the PSM
characteristic (2 bytes little-endian), an unencrypted LE L2CAP CoC channel, Noise NNpsk0, u16 frames, raw DEFLATE.

- `BleLink.swift` builds on Linux: `Crypto` (swift-crypto) for CryptoKit, a Linux-only `CZlib` system module for
  Compression's raw DEFLATE (one-shot `Z_FINISH`, window bits -15). `ble-vectors.json` checks it.
- `MobileBluetooth.swift` keeps everything above the radio: `bluetooth.lock`, the busy cap, UUID rotation and the
  30 s retry, `off(reason)`, and `BlePhoneLink`'s handshake and sealing over a byte pipe.
- The radio and the pipe are per platform:
  - Mac (`MobileBluetooth+CoreBluetooth.swift`): the CBPeripheralManager delegate and the NSStream pipe, moved
    unchanged. macOS "Build app" CI is their proof.
  - Linux (`MobileBluetooth+BlueZ.swift` over `CElisBlueZ`, sd-bus): an LE advertisement (`Type=peripheral`,
    `ServiceUUIDs` only) and a GATT application with the PSM characteristic, registered asynchronously because
    BlueZ calls back `GetManagedObjects` before it replies; an `AF_BLUETOOTH` `SOCK_SEQPACKET` socket bound to
    PSM 0 (dynamic), `BT_SECURITY_LOW`; `Adapter1.Powered` watched. Sends are chunked to `BT_SNDMTU`.
  - States map to the Mac's: no bluetoothd or adapter `off (unsupported)`, Powered false `off (powered off)`,
    which drops the links and publishes again when it powers on.

## Tasks

| # | Task | Gate |
|---|---|---|
| 1 | BleLink on Linux, `CZlib`; un-gate `BleLinkTests` | vectors pass on Linux |
| 2 | Spike: `CElisBlueZ` advertises a throwaway token's UUID, serves the PSM, listens | `ActiveInstances` 1, PSM in 0x80–0xFF |
| 3 | Split MobileBluetooth (moves only on the Mac); BlueZ radio and socket pipe; wire `mobile serve`; 16 KiB BLE window | Linux and macOS builds |
| 4 | Un-gate `MobileBluetoothTests` over a `SOCK_SEQPACKET` socketpair; the two NSStream stall tests stay Mac-only | Linux `swift test` |
| 5 | CI and README deps (`libsystemd-dev`, `zlib1g-dev`); PARITY, `linux.md` | — |
| 6 | Pixel: a host-less `b=1` pairing to a throwaway relay opens a session | relay logs `phone connected from bt:…` |

Every task also runs `swift build`, the relay tests, `cmake --build build`, `ctest --test-dir build` and `scripts/smoke.sh`.

Done when the Pixel's installed app opens a session on a Linux relay with no Wi-Fi route to it.

## Measured (2026-11-22)

Pixel 10 Pro XL against this machine's Intel AX201, which also serves a Bluetooth mouse and keyboard; a host-less `b=1`
link, so Bluetooth only. The Mac's numbers are the spike's in the spec, a raw L2CAP echo with no Noise, DEFLATE or relay.

- Connect, 8 cold launches: app launch to the relay's `phone connected from bt:` 5.0–7.7 s. From `connectGatt`: LE link
  +2.6 s every time, GATT discovery +1.3 s, L2CAP open +0.1 s, handshake and auth +0.14 s, so about 4 s to L2CAP open
  against the Mac's 1.3–1.45 s from scan start. The steady 2.6 s to the LE link is the gap to look at (BlueZ's default
  advertising interval is the first suspect). Serve reports `advertising` 10 ms after it starts.
- Throughput: the relay's sends saturate the socket (`EAGAIN`) at 16–20 KB/s of sealed, compressed frames, against the
  Mac's 62–65 KB/s raw. End to end, 40 KB of base64 text printed in a Live pane open in Term view reached the phone's
  screen in 18.5–18.8 s, 2.2 KB/s, measured while the idle traffic below filled the link.
- Idle traffic, fixed (PR fix/relay-idle-term-traffic). The relay's own terminal path is quiet: a test client holding a
  watch and a claim on an idle pane received about 22 B/s. The bytes were the phone's history view of a main-screen
  Live pane, which re-read `session text --lines 2000` every 700 ms while the watch channel streamed, each answer the
  whole history; the phone's code is shared, so a Mac relay forwards the same reads. On Linux `events.read` also
  refused the relay's upper-case cursor run, so channel 1 sent `{"gap":true}` every 1.25 s and the phone re-read
  `tree`. Re-measured on one throwaway `b=1` pairing, the relay's sends on the L2CAP socket counted by strace; before
  the fix they stalled (`EAGAIN`) at about 3 KB/s behind the queued history answers:

  | | before | after |
  |---|---|---|
  | session list | 0.76 KB/s | 0.11 KB/s |
  | Term view, idle shell, no history | 0.94 KB/s | 0.12 KB/s |
  | Term view, idle shell, 40 KB of history | 3.4 KB/s, the link full | 0.12 KB/s |
  | 40 KB printed into a cleared pane, to the phone's screen | not there after 10 min | 5.0–5.2 s |

  Before, a history read slower than the phone's 15 s call timeout was dropped by the phone and sent anyway, so with
  more history the screen stopped updating while the link stayed full. Each read still sends the whole history;
  reading only what changed is left for later.
