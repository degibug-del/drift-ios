import Foundation
import CoreGraphics

/// Three play styles against the same field. A scoring model is only sane if the ordering
/// between these is right — a parked player must NOT beat a hunting one.
func play(_ style: String, seed: UInt32 = 962021266) -> (Int, CGFloat) {
    let sim = DriftSim(seed: seed, playerClass: .void)
    var t = 0.0
    var rng = Mulberry(seed: seed &+ 99)
    while !sim.isOver {
        t += 1.0/60.0
        switch style {
        case "parked":
            sim.attractor = CGPoint(x: 800, y: 450)
        case "wander":                       // slow aimless drift
            sim.attractor = CGPoint(x: 800 + cos(t*0.4)*300, y: 450 + sin(t*0.3)*200)
        case "hunt":                          // fast sweeps across the field
            sim.attractor = CGPoint(x: 800 + cos(t*1.3)*640, y: 450 + sin(t*1.7)*380)
        default: break
        }
        sim.step(dt: 1.0/60.0)
    }
    return (sim.score, sim.combo)
}

print("  style     score   final combo")
for s in ["parked", "wander", "hunt"] {
    let (sc, cb) = play(s)
    print(String(format: "  %-9s %6d   x%.1f", (s as NSString).utf8String!, sc, cb))
}
