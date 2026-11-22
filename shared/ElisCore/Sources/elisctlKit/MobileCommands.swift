#if !canImport(Musl)
import ArgumentParser
import Foundation
#if os(macOS)
import Network
#else
import Glibc
#endif
import ElisCore

// MARK: - mobile

/// Mobile runs the TLS and Bluetooth relay elis Mobile connects to. The phone sends the same `{cmd, target, args}` lines
/// elisctl sends, plus an `id` echoed on the answer; each line is forwarded to the control socket.
struct Mobile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Let Elis Mobile drive this Mac over the network or Bluetooth.",
        subcommands: [Serve.self, Reset.self]
    )

    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Serve the pairing link and relay Elis Mobile's requests until stopped.",
            discussion: """
            Prints a QR code and the pairing links, then relays every authenticated phone's requests to the control \
            socket. Anyone with the link controls your terminals; `elisctl mobile reset` revokes it. The token, key \
            and certificate live in <state dir>/mobile; --socket changes only where requests go.
            """)
        @Option(name: .long, help: "TCP port to listen on, 1024...65535.")
        var port: UInt16 = 8765
        @Option(name: .long, help: "IP address to listen on (default: all interfaces).")
        var bind: String?
        @Option(name: .long, help: "Host name or address the phone should dial (default: this Mac's LAN addresses).")
        var host: String?
        @Flag(name: .customLong("no-qr"), help: "Print the links without the QR code.")
        var noQR = false
        @Option(name: .long, help: "Override the control socket path requests are forwarded to.")
        var socket: String?
        @Flag(inversion: .prefixedNo, help: "Offer Bluetooth (BLE L2CAP) to Elis Mobile.")
        var bluetooth = true

        func validate() throws {
            if !PhoneDesktopState.portRange.contains(Int(port)) { throw ValidationError(PhoneDesktopState.portError) }
            #if os(macOS)
            if let bind, IPv4Address(bind) == nil, IPv6Address(bind) == nil { throw ValidationError("--bind takes an IP address") }
            #else
            if let bind, TLSPhoneListener.socketAddress(bind, port: port) == nil { throw ValidationError("--bind takes an IP address") }
            #endif
        }

        func run() throws {
            let env = ProcessInfo.processInfo.environment
            let dir = MobilePairing.directory(environment: env)
            let relay: MobileRelay
            let token: String
            let fingerprint: String
            let listening: UInt16
            do {
                try MobilePairing.ensurePrivateDirectory(dir)
                token = try MobilePairing.loadToken(in: dir)
                try MobilePairing.ensureCertificate(in: dir)
                let identity: PhoneTLSIdentity
                (identity, fingerprint) = try MobilePairing.identity(in: dir)
                let socketPath = socket ?? ControlResolve.socketPath(stateDir: env["ELIS_STATE_DIR"],
                                                                     appSupport: ControlResolve.defaultStateDirectory(environment: env))
                relay = MobileRelay(identity: identity, port: port, bind: bind, mobileDir: dir, socketPath: socketPath,
                                    hostName: MobilePairing.hostName())
                relay.onFailure = { quit(1) }
                listening = try relay.start()
            } catch {
                FileHandle.standardError.write(Data("elisctl: \(error)\n".utf8))
                throw ExitCode.failure
            }

            #if os(macOS)
            let radio = bluetooth ? MobileBluetooth(relay: relay, token: token, status: Self.bluetoothStatus) : nil
            if radio == nil { Self.bluetoothStatus("off (disabled)") }
            let offered = radio?.start() ?? false
            #else
            // shortcut: Linux offers no Bluetooth until it has a BlueZ radio
            let radio: AnyObject? = nil
            Self.bluetoothStatus(bluetooth ? "off (unsupported)" : "off (disabled)")
            let offered = false
            #endif
            var lan: [String?] = host.map { [$0] } ?? MobilePairing.lanAddresses()
            if lan.isEmpty {
                // a Bluetooth phone needs no host; without Bluetooth only this Mac can use the link
                if !offered { FileHandle.standardError.write(Data("elisctl: no LAN address; the link works on this Mac only\n".utf8)) }
                lan = [offered ? nil : "127.0.0.1"]
            }
            let name = MobilePairing.hostName()
            let links = lan.map {
                MobilePairing.pairLink(host: $0, port: listening, token: token, fingerprint: fingerprint, name: name, bluetooth: offered)
            }
            if !noQR, let matrix = try? MobilePairing.qrMatrix(links[0]) {
                MobilePairing.qrRows(matrix).forEach { print($0) }
            }
            print("\nScan the code in Elis Mobile, or paste the link:")
            links.forEach { print($0) }
            print("\nListening on \(bind ?? "*"):\(listening). Anyone with the link controls your terminals; "
                + "`elisctl mobile reset` revokes it. Ctrl+C stops.")
            #if os(macOS)
            fflush(stdout)
            #else
            fflush(nil) // Glibc's stdout is a mutable global Swift 6 refuses
            #endif

            var sources: [any DispatchSourceProtocol] = []
            for stop in [SIGINT, SIGTERM, SIGHUP] {
                signal(stop, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: stop, queue: .main)
                source.setEventHandler {
                    relay.releaseAllGrids() // a stopped relay gives grids back; a dead parent took the sessions with it
                    quit(0)
                }
                source.resume()
                sources.append(source)
            }
            // a crashed app must not leave the port bound: its child is reparented to launchd, or to a Linux subreaper
            let parent = getppid()
            let orphanable = parent != 1
            let watch = DispatchSource.makeTimerSource(queue: .main)
            watch.schedule(deadline: .now() + 2, repeating: 2)
            watch.setEventHandler {
                if orphanable, getppid() != parent { quit(0) }
                // a reset by hand leaves the printed code dead
                if case let .token(now) = MobilePairing.readToken(in: dir), !MobilePairing.sameSecret(now, token) {
                    FileHandle.standardError.write(Data("elisctl: \(PhoneRelayLine.pairingReset)\n".utf8))
                    relay.releaseAllGrids()
                    quit(1)
                }
            }
            watch.resume()
            sources.append(watch)
            withExtendedLifetime((relay, radio, sources)) { dispatchMain() }
        }

        @Sendable static func bluetoothStatus(_ status: String) {
            FileHandle.standardError.write(Data("elisctl: bluetooth: \(status)\n".utf8))
        }
    }

    struct Reset: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Revoke the pairing: write a new token, which disconnects every paired phone.")

        func run() throws {
            let dir = MobilePairing.directory(environment: ProcessInfo.processInfo.environment)
            do {
                try MobilePairing.ensurePrivateDirectory(dir)
                _ = try MobilePairing.loadToken(in: dir, fresh: true)
            } catch {
                FileHandle.standardError.write(Data("elisctl: \(error)\n".utf8))
                throw ExitCode.failure
            }
            print("Pairing revoked: paired phones are disconnected. Restart `elisctl mobile serve` for the new code.")
        }
    }
}

/// `exit` inside a command names ParsableCommand's own.
private func quit(_ code: Int32) -> Never {
    #if os(macOS)
    Darwin.exit(code)
    #else
    Glibc.exit(code)
    #endif
}

struct MobileError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
