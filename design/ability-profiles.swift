import Foundation
import CoreGraphics

/// Three firing policies. The question is not "is the ability good" but "does using it WELL
/// beat not using it" — an ability that pays regardless of timing is just a bigger number.
func run(_ cls: PlayerClass, policy: String, style: String) -> Int {
    let sim = DriftSim(seed: 962021266, playerClass: cls)
    var t = 0.0
    while !sim.isOver {
        t += 1.0/60.0
        if style == "hunt" { sim.attractor = CGPoint(x: 800 + cos(t*1.3)*640, y: 450 + sin(t*1.7)*380) }
        else               { sim.attractor = CGPoint(x: 800 + cos(t*0.4)*300, y: 450 + sin(t*0.3)*200) }
        if policy != "never", sim.abilityReady {
            if policy == "blind" { sim.fireAbility() }
            else {
                // Timed: fire only on a dense patch — what a player who is paying
                // attention actually does.
                let near = sim.particles.filter {
                    hypot($0.x - sim.attractor.x, $0.y - sim.attractor.y) < 420 }.count
                if near > 150 { sim.fireAbility() }
            }
        }
        sim.step(dt: 1.0/60.0)
    }
    return sim.score
}

for style in ["hunt", "wander"] {
    print("  — \(style) —")
    print("    class    never   blind   timed    timed vs never")
    for c in PlayerClass.all {
        let n = run(c, policy: "never", style: style)
        let b = run(c, policy: "blind", style: style)
        let m = run(c, policy: "timed", style: style)
        print(String(format: "    %-7s %6d  %6d  %6d    %+5d (%+.0f%%)",
                     (c.name as NSString).utf8String!, n, b, m, m-n, Double(m-n)/Double(n)*100))
    }
}
