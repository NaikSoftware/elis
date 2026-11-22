import elisctlKit

/// The phone relay's Mac transports: the Network framework listener and the Core Bluetooth radio.
public enum MacTransports {
    public static func register() {
        MobileTransports.tls = NetworkTLSIdentity.self
        MobileTransports.radio = CoreBluetoothRadio.self
    }
}
