// Haptics.swift — CoreHaptics, with a working fallback.
//
// The web build calls a Haptic shim that bottoms out in navigator.vibrate, which iOS
// Safari does not implement at all — so on iPhone the web game has no haptics whatsoever,
// silently. This is one of the concrete things the native build does that the site cannot,
// and it is worth being exact about it rather than listing "haptics" as a bullet.
//
// CoreHaptics needs a device with a Taptic Engine and is unavailable on the simulator and
// on iPads. Rather than branch at every call site, this falls back to UIImpactFeedback,
// and if that is unavailable too it does nothing — a missing buzz must never be an error
// path in a game loop.

import CoreHaptics
import UIKit

final class Haptics {

    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private let impact = UIImpactFeedbackGenerator(style: .rigid)
    private var lastFire: TimeInterval = 0

    /// Below this, taps blur into a continuous buzz that reads as a fault rather than
    /// feedback. 45ms is roughly the shortest gap that still registers as separate events.
    private let minGap: TimeInterval = 0.045

    private init() {
        impact.prepare()
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            // The engine stops when the app backgrounds or on an audio-session interruption,
            // and does NOT restart itself. Without these handlers haptics work until the
            // first phone call and then are silently dead for the rest of the session.
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { _ in }
            try engine?.start()
        } catch {
            NSLog("[drift] haptic engine unavailable: \(error.localizedDescription)")
            engine = nil
        }
    }

    /// A single transient tap. `intensity` 0…1.
    func tap(intensity: Double) {
        let now = CACurrentMediaTime()
        guard now - lastFire > minGap else { return }
        lastFire = now

        guard let engine else {
            impact.impactOccurred(intensity: CGFloat(max(0.1, min(1, intensity))))
            return
        }
        let i = CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: Float(max(0.1, min(1, intensity))))
        let s = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.75)
        let ev = CHHapticEvent(eventType: .hapticTransient, parameters: [i, s], relativeTime: 0)
        do {
            let pattern = try CHHapticPattern(events: [ev], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            impact.impactOccurred(intensity: CGFloat(intensity))
        }
    }

    /// Round end — a heavier, two-beat pattern so finishing feels different from scoring.
    func roundEnd() {
        guard let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }
        let mk = { (t: TimeInterval, i: Float, s: Float) in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: s),
            ], relativeTime: t)
        }
        do {
            let pattern = try CHHapticPattern(events: [mk(0, 0.9, 0.5), mk(0.12, 0.6, 0.3)],
                                              parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
