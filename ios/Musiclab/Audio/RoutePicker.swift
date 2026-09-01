import AVKit
import SwiftUI

/// The system output picker, which is the only supported way to let someone
/// choose a Bluetooth device: the list of paired devices is not available to
/// apps, so this hands the choice to iOS and shows the same sheet Control
/// Centre does.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .secondaryLabel
        picker.activeTintColor = .systemGreen
        // This is an audio app; offering to send video somewhere is noise.
        picker.prioritizesVideoDevices = false
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
