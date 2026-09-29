import CoreBluetooth
import Foundation

enum BitchatBluetoothAvailability: Equatable, Sendable {
    case unknown
    case resetting
    case poweredOn
    case poweredOff
    case unauthorized
    case unsupported
}

struct BitchatBluetoothPresentation: Equatable, Sendable {
    let availability: BitchatBluetoothAvailability
    let title: String
    let message: String
    let systemImageName: String
    let isBlocking: Bool

    var isAvailable: Bool {
        availability == .poweredOn
    }

    var shouldShowBanner: Bool {
        switch availability {
        case .poweredOn:
            return false
        case .unknown, .resetting, .poweredOff, .unauthorized, .unsupported:
            return true
        }
    }

    var canOpenSettings: Bool {
        availability == .unauthorized
    }

    var actionTitle: String? {
        if canOpenSettings { "Open App Settings" } else { nil }
    }

    static func make(from state: CBManagerState) -> BitchatBluetoothPresentation {
        switch state {
        case .poweredOn:
            return BitchatBluetoothPresentation(
                availability: .poweredOn,
                title: "Bluetooth Ready",
                message: "Nearby mesh discovery is active.",
                systemImageName: "dot.radiowaves.left.and.right",
                isBlocking: false
            )
        case .poweredOff:
            return BitchatBluetoothPresentation(
                availability: .poweredOff,
                title: "Bluetooth Is Off",
                message: "BTChat needs Bluetooth to work. Open Settings → Bluetooth and turn on Bluetooth to find nearby people and send messages and photos.",
                systemImageName: "antenna.radiowaves.left.and.right.slash",
                isBlocking: true
            )
        case .unauthorized:
            return BitchatBluetoothPresentation(
                availability: .unauthorized,
                title: "Bluetooth Permission Needed",
                message: "Allow Halls to use Bluetooth. Tap Open App Settings, then enable Bluetooth access to use BTChat.",
                systemImageName: "hand.raised",
                isBlocking: true
            )
        case .unsupported:
            return BitchatBluetoothPresentation(
                availability: .unsupported,
                title: "Bluetooth Unsupported",
                message: "This device does not support the Bluetooth features required for nearby mesh chat.",
                systemImageName: "exclamationmark.triangle",
                isBlocking: true
            )
        case .resetting:
            return BitchatBluetoothPresentation(
                availability: .resetting,
                title: "Bluetooth Is Resetting",
                message: "Nearby mesh chat will resume automatically when Bluetooth finishes resetting.",
                systemImageName: "arrow.triangle.2.circlepath",
                isBlocking: false
            )
        case .unknown:
            return BitchatBluetoothPresentation(
                availability: .unknown,
                title: "Starting Bluetooth",
                message: "Preparing nearby mesh discovery.",
                systemImageName: "antenna.radiowaves.left.and.right",
                isBlocking: false
            )
        @unknown default:
            return BitchatBluetoothPresentation(
                availability: .unknown,
                title: "Bluetooth Status Unknown",
                message: "Nearby mesh chat is waiting for Bluetooth status.",
                systemImageName: "questionmark.circle",
                isBlocking: false
            )
        }
    }
}
