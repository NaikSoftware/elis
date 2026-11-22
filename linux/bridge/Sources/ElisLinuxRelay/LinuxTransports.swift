import elisctlKit

/// The phone relay's Linux transports: the OpenSSL listener and the BlueZ radio.
public enum LinuxTransports {
    public static func register() {
        MobileTransports.tls = OpenSSLIdentity.self
        MobileTransports.radio = BlueZRadio.self
    }
}
