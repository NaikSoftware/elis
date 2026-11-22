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

Out of scope: the Qt Connect a Phone dialog's Bluetooth row, which follows Phase 5b's exec of the Swift relay.

Done when the Pixel's installed app opens a session on a Linux relay with no Wi-Fi route to it.
