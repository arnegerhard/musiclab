import CoreMotion
import Foundation
import Observation

/// Head orientation from spatial-audio-capable AirPods.
///
/// This is the capability that makes the room feel like a room. Without head
/// tracking, sources tend to collapse inside your head and front/back gets
/// confused; with it, turning your head leaves the band where it stands.
///
/// Requires AirPods (Pro / Max / 3rd gen or later) connected to the device.
/// The simulator reports no motion, so the manual fallback below is what runs
/// there — and it is also what a listener on ordinary headphones gets.
@Observable
final class HeadTracker: NSObject, CMHeadphoneMotionManagerDelegate {
    private let manager = CMHeadphoneMotionManager()
    private var reference: CMAttitude?

    /// CoreMotion's head frame and the audio environment's listener frame
    /// agree on handedness: both take yaw as counterclockwise-positive, so the
    /// angle passes through unchanged. Negating it -- which is what this did
    /// before anyone had tried it on AirPods -- drove the room the wrong way,
    /// turning the band with the listener instead of leaving it in the room.
    private static let yawSign: Float = 1

    /// Told about every update, so the listener keeps turning while the
    /// player screen is closed. The view's own timer stops when it does.
    var onUpdate: ((Float, Float, Float) -> Void)?

    private(set) var isTracking = false
    private(set) var yaw: Float = 0     // degrees, 0 = facing the stage
    private(set) var pitch: Float = 0
    private(set) var roll: Float = 0

    /// Used when there is nothing to track: the listener can still turn the
    /// room by hand, which also makes the whole thing testable off-device.
    var manualYaw: Float = 0 {
        didSet { if !isTracking { yaw = manualYaw } }
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !isTracking else { return }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            guard let attitude = motion.attitude.copy() as? CMAttitude else { return }
            if let reference = self.reference {
                attitude.multiply(byInverseOf: reference)
            }
            let toDegrees = Float(180.0 / Double.pi)
            self.yaw = Self.yawSign * Float(attitude.yaw) * toDegrees
            self.pitch = Float(attitude.pitch) * toDegrees
            self.roll = Float(attitude.roll) * toDegrees
            self.isTracking = true
            self.onUpdate?(self.yaw, self.pitch, self.roll)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        isTracking = false
        yaw = manualYaw
        pitch = 0
        roll = 0
    }

    /// Treat wherever the listener is facing now as "straight ahead".
    func recenter() {
        if isTracking, let current = manager.deviceMotion?.attitude.copy() as? CMAttitude {
            reference = current
        } else {
            manualYaw = 0
            yaw = 0
        }
    }

    // MARK: - CMHeadphoneMotionManagerDelegate

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        start()
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        isTracking = false
        yaw = manualYaw
    }
}
