import AVFoundation
import Observation

/// What the audio is coming out of right now.
///
/// iOS gives an app no way to enumerate or switch Bluetooth devices itself —
/// choosing one is the system's job, through `AVRoutePickerView`. What an app
/// can do is observe the result, which is what this is for: the binaural
/// rendering only makes sense on headphones, so the engine needs to know when
/// the route changes under it.
@Observable
final class AudioRoute {
    private(set) var name = "iPhone"
    private(set) var icon = "iphone"
    /// True when the output is something worn on the head, so a spatial mix
    /// lands as intended rather than collapsing into the room.
    private(set) var isHeadphones = false
    private(set) var isWireless = false

    private var observer: NSObjectProtocol?

    init() {
        // Whatever this reads now is provisional: until the session has a
        // category and is active, AVAudioSession answers with the default
        // output rather than the one actually in use.
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Read the route again.
    ///
    /// Must be called once the audio session is active. An inactive session
    /// reports the built-in speaker no matter what is really connected, so a
    /// pair of AirPods that were already in before this screen opened would
    /// otherwise never be noticed -- there is no change for the route-change
    /// notification to report.
    func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else {
            name = "No output"; icon = "speaker.slash"; isHeadphones = false
            isWireless = false
            return
        }

        name = port.portName
        isHeadphones = Self.wornOnHead.contains(port.portType)
        isWireless = Self.wireless.contains(port.portType)
        icon = Self.icon(for: port)
    }

    private static let wornOnHead: Set<AVAudioSession.Port> =
        [.headphones, .bluetoothA2DP, .bluetoothLE, .airPlay]
    private static let wireless: Set<AVAudioSession.Port> =
        [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay]

    private static func icon(for port: AVAudioSessionPortDescription) -> String {
        // AirPods report a user-chosen name ("Arne's AirPods Pro"), so the
        // model has to be read out of it rather than the port type.
        let lowered = port.portName.lowercased()
        if lowered.contains("airpods max") { return "airpods.max" }
        if lowered.contains("airpods pro") { return "airpods.pro" }
        if lowered.contains("airpods") { return "airpods" }
        if lowered.contains("beats") { return "beats.headphones" }

        switch port.portType {
        case .headphones:                   return "headphones"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                                            return "headphones"
        case .airPlay:                      return "airplayaudio"
        case .carAudio:                     return "car.fill"
        case .usbAudio:                     return "cable.connector"
        case .HDMI:                         return "tv"
        case .builtInSpeaker:               return "iphone"
        default:                            return "speaker.wave.2"
        }
    }
}
