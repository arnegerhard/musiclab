import Foundation
import Observation

/// How this build reached the device. Shown in the footer so it is obvious
/// which build is running; it no longer changes where the server is looked for.
enum Distribution {
    case simulator, development, testFlight, appStore

    init?(name: String) {
        switch name.lowercased() {
        case "simulator": self = .simulator
        case "development": self = .development
        case "testflight": self = .testFlight
        case "appstore": self = .appStore
        default: return nil
        }
    }

    static var current: Distribution = {
        // A development build can be told to behave like a shipped one. This is
        // the only way to exercise the TestFlight / App Store routing before
        // actually shipping:
        //
        //   xcrun simctl launch <udid> info.jetsons.musiclab \
        //       --args -distribution appStore
        //
        if let forced = UserDefaults.standard.string(forKey: "distribution"),
           let value = Distribution(name: forced) {
            return value
        }
        #if targetEnvironment(simulator)
        return .simulator
        #else
        // TestFlight installs carry a sandbox receipt; App Store ones do not.
        if Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" {
            return .testFlight
        }
        // Only development and ad-hoc builds embed a provisioning profile.
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil {
            return .development
        }
        return .appStore
        #endif
    }()

    var label: String {
        switch self {
        case .simulator: return "Simulator"
        case .development: return "Xcode build"
        case .testFlight: return "TestFlight"
        case .appStore: return "App Store"
        }
    }
}
