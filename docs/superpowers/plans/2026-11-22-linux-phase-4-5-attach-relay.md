# Linux Phases 4–5: `session.attach` and the relay mux

Status: plan, 2026-11-22, on master `cb005f69`.
It supersedes three lines of the roadmap:
- "the relay is a C++ port … not reopened";
- D3's "line for line";
- Phase 6's OpenSSL Noise.

## Route: B, the Swift relay on Linux

Evidence:
- Apple frameworks appear in three relay files only:
  - `MobileCommands.swift`: Network, Security, CoreImage, SystemConfiguration, CryptoKit.
  - `BleLink.swift`: CryptoKit, Compression.
  - `MobileBluetooth.swift`: CoreBluetooth.
- The mux core imports only Foundation and ElisCore: PhoneSession, PhoneLink{Session,Terminal,Claim,Events,LineStream,Pty,Forward}, Presenter and PhoneCommands, about 2,900 lines.
  It is gated `#if os(macOS)` only for `Darwin.` qualifiers, NOSIGPIPE, `POSIX_SPAWN_CLOEXEC_DEFAULT` and Darwin ioctl numbers.
- `MobileRelay.accept(any PhoneTransportConnection)` is already the transport seam; Bluetooth uses it.
- 11 of the 13 gated `elisctlKitTests` relay files use no Apple framework. The other two, MobileCommandsTests and MobileTestSupport, use Network.
- The C++ relay is 300 lines of the pre-mux protocol.

| | A: C++ port | B: Swift relay |
|---|---|---|
| Files | ~10 new C++ files, bridge wrappers over the codec | ~12 Swift files edited, 2 Linux-only C targets, CMake |
| Mac risk | none | Mac relay files edited; only macOS CI proves them |
| New deps | none (OpenSSL in Phase 6) | system libssl (Qt already loads it), swift-crypto (Linux only) |
| Single-sourced | codec and scheduler | all but the TLS listener and the radio |
| Tests reused | vector files | 13 relay test files run on Linux CI |
| Phase 6 | Noise, framing and caps ported again | BleLink shared through swift-crypto; only the BlueZ radio is new |

Shape:
- TLS lives in the Swift process. `send(_:completion:)` must mean "the bytes left for the phone": the stall, credit and overflow rules rest on it. A C++ TLS front proxying plaintext would complete early.
- The Swift `elisctl` ships as `libexec/elis/elisctl`, as zmx does.
  C++ `elisctl mobile …` and `session attach` exec it with the same argv and an explicit `ELIS_STATE_DIR`.
  The two sides disagree on the state directory: `paths.h` gives `~/.local/share/elis`, `ControlResolve` on Linux `~/.local/state/elis`.
  Replacing the whole C++ CLI is a separate decision.
- Linux `session.attach` omits `origin`. Pages stay out of the migration, so the relay refuses a `present` OPEN with `Elis is too old to show pages`.

## Task 0 (mechanical)

Record master's failing CI jobs.
Every gate below means "no new failures against that list" plus the named tests.
Tasks 5.2–5.4 land as separate PRs, so a new macOS failure names one change.

## Phase 4 — `session.attach`

| # | Task | Kind | Gate |
|---|---|---|---|
| 4.1 | ElisBridge `elis_session_attach`: endpoint, daemon, paneID, claim → `ControlAttach.viewer/claimer`; `LiveReset.isOutdated` for `predatesZmxBuild`, so Linux records the zmx build time | judgement | test_core: viewer, claim plus nonce, outdated refusal |
| 4.2 | `control.cpp` handler in the order and with the texts of `ControlServer+Attach.swift`: `--pane`/`paneID` (`unknown pane id`), `session has no split pane`, `session not realized`, `<t> is not a Live session`, the predates text | judgement | test_core per refusal |
| 4.3 | CMake builds the `elisctl` product (`-c release -static-stdlib`), installs it to libexec; C++ `session attach` execs it | mechanical | smoke.sh: `session attach --json` on a throwaway state dir |
| 4.4 | `phone.cpp` reads relay stderr through a bridge wrapper over `PhoneRelayLine.stderr` and counts with `PhoneViewers`. This feeds tree `surfaces[].phoneViewers`/`phoneLead`; events `phone.attached|detached|claimed|released` plus `tree.changed`, with their human lines (`ip=-`) and `hooks.conf` names. A relay exit resets every viewer | judgement | test_core: parse, counts, reset; `hooks list` |
| 4.5 | The pane cover says "In use on your phone" while the phone leads (`paneleadcover.cpp`) | mechanical | test_ui |
| 4.6 | PARITY, README, skill `linux.md` | mechanical | — |

Done when, on a throwaway state dir, `elisctl session attach` mirrors a Live pane and `--claim` takes its lead, with the Qt pane covered.

## Phase 5 — relay mux

| # | Task | Kind | Gate |
|---|---|---|---|
| 5.1 | `Package.swift` `#if os(Linux)`, as for swift-markdown: swift-crypto; `CElisTLS` over system OpenSSL (accept, read, write); `CQRCode` (Nayuki's C qrcodegen). `hostSubcommands` gains Mobile and Phone on Linux | judgement | Linux and macOS `swift build` |
| 5.2 | Un-gate the mux core: `#if canImport(Darwin)` for close/read/write; ignore SIGPIPE and use MSG_NOSIGNAL where NOSIGPIPE was | mechanical | both builds |
| 5.3 | PhoneLinkPty on Linux: TIOCSWINSZ 0x5414, FIONREAD 0x541B; a close-range file action instead of `CLOEXEC_DEFAULT`; check SETSID and SIGWINCH | judgement | PhoneLinkPtyTests, ClaimTests on Linux |
| 5.4 | Split `MobileCommands.swift`: portable `MobilePairing` (token, link, LAN, gethostname on Linux, QR rows) and `MobileRelay`; a per-platform listener (NWListener unchanged on Mac; OpenSSL with keepalive 30/10/3 on Linux); `SystemRandomNumberGenerator`; `import Crypto` on Linux | judgement | MobileCommandsTests on Linux; macOS no new failures |
| 5.5 | Un-gate the relay test files; the Linux `swift test` job runs them under the watchdog | mechanical | ubuntu `swift test` |
| 5.6 | Delete the C++ serve/reset; `mobile` execs the helper; the dialog keeps its qrcodegen | mechanical | smoke.sh, Connect a Phone |
| 5.7 | `mobile/integration_test/term_relay_test.dart`: pair, open `phone-target`, Term shows a red cell from `printf '\e[31mRED\e[0m'`, lead on open (`phoneLead` true), typed text lands, a desktop key takes the lead back (`the computer took the lead back`), a prompt card from the coloured grid | judgement | `flutter analyze --no-pub`, `flutter test --no-pub`, e2e |
| 5.8 | PARITY, READMEs, `linux.md`, the specs' "Linux keeps the text view" | mechanical | — |

Every task also runs `cmake --build build`, `ctest --test-dir build` and `scripts/smoke.sh` in `linux/`.

Phone e2e:
1. Build the APK first: android-x64, one Gradle build at a time.
2. Run an offscreen `build/elis` on a short throwaway `ELIS_STATE_DIR`, never the default socket, with a Live session named `phone-target`.
3. Start `build/elisctl mobile serve --bind 127.0.0.1 --host 10.0.2.2 --no-qr`. The emulator reaches host loopback as 10.0.2.2.
4. Run `flutter test integration_test/app_test.dart` and `term_relay_test.dart` with `-d emulator-5554 --dart-define=PAIR_LINK=<link>`.
5. Stop the emulator, app and relay by pid.

Done as the roadmap says: Term in colour, lead taken on open, typing, lead given back.

## Phase 6 — stub

- BleLink un-gated: `Crypto` on Linux, raw DEFLATE through a Linux-only zlib module, checked against `ble-vectors.json`.
- `MobileBluetooth` splits into a shared part (UUID rotation, `bluetooth.lock`, busy cap, `BlePhoneLink` framing) and a radio: CoreBluetooth on the Mac, BlueZ on Linux.
- A BlueZ spike comes first: D-Bus advertising plus an LE L2CAP CoC socket through a C shim.
