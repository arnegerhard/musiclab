import SwiftUI
import UIKit

/// A two-finger vertical drag, which SwiftUI has no gesture for: DragGesture
/// is single-touch and MagnifyGesture is a pinch, so this comes from UIKit.
///
/// Reports the movement since the last callback rather than since the gesture
/// began, so the caller can accumulate it into an angle without having to
/// remember where the fingers started.
struct TwoFingerPan: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handle(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (CGFloat) -> Void

        init(onChange: @escaping (CGFloat) -> Void) { self.onChange = onChange }

        @objc func handle(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .changed else { return }
            let delta = gesture.translation(in: gesture.view).y
            gesture.setTranslation(.zero, in: gesture.view)
            onChange(delta)
        }
    }
}
