// Run: swiftc apple/Routi/Models/RelayAddress.swift apple/tests/RelayAddressTests.swift -o /tmp/routi-relay-address-tests && /tmp/routi-relay-address-tests
import Foundation

@main struct RelayAddressTests {
    static func main() {
        precondition(RelayAddress.normalize(RelayAddress.defaultValue) == RelayAddress.defaultValue)
        precondition(RelayAddress.normalize("  WSS://CONNECT.ROUTIBOT.COM/\n") == RelayAddress.defaultValue)
        precondition(RelayAddress.normalize("wss://relay.example.com:9443") == "wss://relay.example.com:9443")
        precondition(RelayAddress.normalize("wss://[::1]:9443/") == "wss://[::1]:9443")
        for invalid in ["", "connect.routibot.com", "ws://relay.example.com", "https://relay.example.com",
                        "wss://", "wss://relay example.com", "wss://relay.example.com/path",
                        "wss://user:password@relay.example.com", "wss://relay.example.com?token=secret",
                        "wss://relay.example.com#fragment", "wss://relay.example.com:0", "wss://relay.example.com:65536"] {
            precondition(RelayAddress.normalize(invalid) == nil, "Accepted invalid address: \(invalid)")
        }
        print("Relay address validation passed")
    }
}
