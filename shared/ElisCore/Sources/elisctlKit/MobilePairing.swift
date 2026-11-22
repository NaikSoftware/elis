#if !canImport(Musl)
#if os(macOS)
import CoreImage
import CryptoKit
import Security
import SystemConfiguration
#else
import CQRCode
import Crypto
#endif
import Foundation
import ElisCore

// MARK: - pairing

/// The pairing secret, the certificate the phone pins, and the link carrying both.
enum MobilePairing {
    static func directory(environment env: [String: String]) -> String {
        let state = env["ELIS_STATE_DIR"] ?? ControlResolve.defaultStateDirectory(environment: env)
        return (state as NSString).appendingPathComponent("mobile")
    }

    /// The directory holds the key and the token: refuse it unless only this user can enter it.
    static func ensurePrivateDirectory(_ dir: String) throws {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard chmod(dir, 0o700) == 0, stat(dir, &info) == 0, info.st_uid == getuid() else {
            throw MobileError("cannot make \(dir) private to you")
        }
    }

    /// Read on every request, so `mobile reset` cuts off phones holding the old token at once.
    static func currentToken(in dir: String) -> String? {
        if case let .token(token) = readToken(in: dir) { return token }
        return nil
    }

    enum TokenRead: Equatable {
        case token(String)
        /// Missing, unreadable or not a token: no phone holds a valid pairing.
        case absent
        /// A read error that says nothing about the file, such as running out of descriptors.
        case unavailable
    }

    static func readToken(in dir: String) -> TokenRead {
        let fd = open(dir + "/token", O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return isTransient(errno) ? .unavailable : .absent }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &bytes, bytes.count)
        guard count >= 0 else { return isTransient(errno) ? .unavailable : .absent }
        let token = String(decoding: bytes[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32, token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return .absent }
        return .token(token)
    }

    /// EACCES is not here: a token file nobody can read was changed on purpose, so it revokes.
    static func isTransient(_ code: Int32) -> Bool { [EMFILE, ENFILE, EINTR, EAGAIN].contains(code) }

    /// 32 random bytes, base64url without padding.
    static func loadToken(in dir: String, fresh: Bool = false) throws -> String {
        if !fresh, let token = currentToken(in: dir) { return token }
        var raw = [UInt8](repeating: 0, count: 32)
        #if os(macOS)
        guard SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw) == errSecSuccess else { throw MobileError("no random bytes") }
        #else
        raw = raw.map { _ in UInt8.random(in: .min ... .max) } // SystemRandomNumberGenerator, a CSPRNG
        #endif
        let token = Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try writePrivate(dir + "/token", Data((token + "\n").utf8))
        return token
    }

    /// Created owner-only and renamed into place, so a reader sees the old token or the new one, never a torn file.
    private static func writePrivate(_ path: String, _ data: Data) throws {
        let temporary = path + ".tmp"
        unlink(temporary)
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MobileError("cannot write \(path)") }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        close(fd)
        guard written == data.count, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw MobileError("cannot write \(path)")
        }
    }

    /// A self-signed P-256 certificate; the phone pins its SHA-256 at pairing, so no CA is involved.
    static func ensureCertificate(in dir: String) throws {
        let cert = dir + "/cert.pem", key = dir + "/key.pem"
        if FileManager.default.fileExists(atPath: cert), FileManager.default.fileExists(atPath: key) { return }
        // CryptoKit makes the key: LibreSSL drops a leading zero byte of the scalar (about 1 key in 256), which
        // CryptoKit then refuses to read, and its default explicit EC parameters crash SecIdentityCreate
        try writePrivate(key, Data(P256.Signing.PrivateKey().pemRepresentation.utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-new", "-key", key, "-days", "3650", "-subj", "/CN=elis", "-out", cert]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            unlink(cert)
            unlink(key)
            throw MobileError("cannot create a certificate with openssl: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// The registered listener's identity for the certificate and key, and the lowercase hex SHA-256 of the certificate DER.
    static func identity(in dir: String) throws -> (any PhoneTLSIdentity, String) {
        guard let tls = MobileTransports.tls else { throw MobileError("this elisctl has no TLS listener") }
        let unreadable = MobileError("the certificate in \(dir) is unreadable; delete cert.pem and key.pem to make a new one")
        guard let certPEM = try? String(contentsOfFile: dir + "/cert.pem", encoding: .utf8) else { throw unreadable }
        let base64 = certPEM.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64),
              let identity = tls.init(certificate: dir + "/cert.pem", key: dir + "/key.pem") else { throw unreadable }
        return (identity, SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }

    static func sameSecret(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        var diff = UInt8(a.count == b.count ? 0 : 1)
        for i in 0..<max(a.count, b.count) {
            diff |= (i < a.count ? a[i] : 0) ^ (i < b.count ? b[i] : 0)
        }
        return diff == 0
    }

    /// `elis://pair?h=HOST&p=PORT&t=TOKEN&f=SHA256HEX&n=NAME[&b=1]`; a nil host leaves out `h` and `p`. Only unreserved
    /// characters pass unencoded: the phone decodes a bare `+` as a space.
    static func pairLink(host: String?, port: UInt16, token: String, fingerprint: String, name: String, bluetooth: Bool = false) -> String {
        var unreserved = CharacterSet.alphanumerics.intersection(.init(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        unreserved.insert(charactersIn: "-._~")
        let encode = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let address = host.map { "h=\(encode($0))&p=\(port)&" } ?? ""
        return "elis://pair?\(address)t=\(encode(token))&f=\(encode(fingerprint))&n=\(encode(name))" + (bluetooth ? "&b=1" : "")
    }

    /// The short Bonjour name ("Nicks-MacBook"), which is what the phone lists the pairing under.
    static func hostName() -> String {
        #if os(macOS)
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty { return name }
        let name = ProcessInfo.processInfo.hostName
        return name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        #else
        var name = [CChar](repeating: 0, count: 256)
        let host = gethostname(&name, name.count) == 0
            ? String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ProcessInfo.processInfo.hostName
        return String(host.prefix { $0 != "." })
        #endif
    }

    /// Up, non-loopback, non-link-local IPv4 addresses; the first one goes in the QR code.
    static func lanAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var found: [(name: String, address: String)] = []
        for entry in sequence(first: head, next: { $0?.pointee.ifa_next }) {
            guard let entry, entry.pointee.ifa_flags & UInt32(IFF_UP) != 0, let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET, &sin.sin_addr, &host, socklen_t(host.count))
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if address.hasPrefix("127.") || address.hasPrefix("169.254.") { continue }
            found.append((String(cString: entry.pointee.ifa_name), address))
        }
        return orderedLAN(found)
    }

    /// Container and VM bridges and VPN tunnels go after physical interfaces; duplicates keep their first place.
    static func orderedLAN(_ interfaces: [(name: String, address: String)]) -> [String] {
        #if os(macOS)
        let virtual = ["bridge", "vmnet", "utun", "vboxnet"]
        #else
        let virtual = ["bridge", "vmnet", "utun", "vboxnet", "docker", "br-", "virbr", "veth", "lxc", "lxd", "podman", "cni"]
        #endif
        let isVirtual = { (name: String) in virtual.contains { name.hasPrefix($0) } }
        var seen = Set<String>()
        return (interfaces.filter { !isVirtual($0.name) } + interfaces.filter { isVirtual($0.name) })
            .map(\.address).filter { seen.insert($0).inserted }
    }

    #if os(macOS)
    /// The QR modules, top row first, without a quiet zone.
    static func qrMatrix(_ text: String) throws -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw MobileError("no QR generator") }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { throw MobileError("cannot encode the link as a QR code") }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [UInt8](repeating: 255, count: width * height)
        CIContext(options: [.useSoftwareRenderer: true])
            .render(image, toBitmap: &pixels, rowBytes: width, bounds: extent, format: .L8, colorSpace: nil)
        let rows = (0..<height).map { y in (0..<width).map { pixels[y * width + $0] < 128 } }
        // the generator adds its own margin; the finder patterns make the first and last rows and columns dark
        let used = rows.indices.filter { rows[$0].contains(true) }
        let columns = (0..<width).filter { x in rows.contains { $0[x] } }
        guard let top = used.first, let bottom = used.last, let left = columns.first, let right = columns.last else {
            throw MobileError("empty QR code")
        }
        return rows[top...bottom].map { Array($0[left...right]) }
    }
    #else
    static func qrMatrix(_ text: String) throws -> [[Bool]] {
        // 3918 is qrcodegen_BUFFER_LEN_MAX, a macro Swift does not import
        var code = [UInt8](repeating: 0, count: 3918), scratch = code
        guard qrcodegen_encodeText(text, &scratch, &code, qrcodegen_Ecc_LOW, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
                                   qrcodegen_Mask_AUTO, true) else { throw MobileError("cannot encode the link as a QR code") }
        let size = qrcodegen_getSize(code)
        return (0..<size).map { y in (0..<size).map { x in qrcodegen_getModule(code, x, y) } }
    }
    #endif

    /// Half-block rows with explicit black and white, so the code scans on dark and light themes alike.
    static func qrRows(_ matrix: [[Bool]]) -> [String] {
        let border = 2, size = matrix.count, span = size + 2 * border
        let dark = { (x: Int, y: Int) -> Bool in
            let row = y - border, column = x - border
            return row >= 0 && row < size && column >= 0 && column < size && matrix[row][column]
        }
        return stride(from: 0, to: span, by: 2).map { y in
            (0..<span).map { x in "\u{1b}[\(dark(x, y) ? 30 : 97);\(dark(x, y + 1) ? 40 : 107)m▀" }.joined() + "\u{1b}[0m"
        }
    }
}
#endif
